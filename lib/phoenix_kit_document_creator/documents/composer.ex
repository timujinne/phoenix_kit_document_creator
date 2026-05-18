defmodule PhoenixKitDocumentCreator.Documents.Composer do
  @moduledoc """
  Composition orchestration for documents built from multiple template sections.

  Public entry point: `compose/2`. This module is the implementation behind
  `PhoenixKitDocumentCreator.Documents.create_composed_document/2`.
  """

  # TODO(orphan-doc-sweeper): see docs/superpowers/specs/2026-05-12-document-composition-design.md "Open Risks"
  # credo:disable-for-previous-line Credo.Check.Design.TagTODO

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Schemas.{Document, DocumentSection, Template}

  @type section_input :: %{
          template_uuid: UUIDv7.t(),
          position: non_neg_integer(),
          variable_values: map(),
          image_params: map()
        }

  @spec validate_sections([section_input()], keyword()) ::
          :ok
          | {:error,
             :empty_sections
             | {:duplicate_positions, [non_neg_integer()]}
             | {:unknown_templates, [UUIDv7.t()]}
             | {:unpublished_templates, [UUIDv7.t()]}}
  def validate_sections([], _opts), do: {:error, :empty_sections}

  def validate_sections(sections, opts) do
    all = Keyword.fetch!(opts, :all_templates)
    by_uuid = Map.new(all, &{&1.uuid, &1})

    dups =
      sections
      |> Enum.map(& &1.position)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, c} -> c > 1 end)
      |> Enum.map(&elem(&1, 0))

    uuids = Enum.map(sections, & &1.template_uuid)
    unknown = Enum.reject(uuids, &Map.has_key?(by_uuid, &1))

    unpublished =
      uuids
      |> Enum.filter(&Map.has_key?(by_uuid, &1))
      |> Enum.reject(&by_uuid[&1].published)

    cond do
      dups != [] -> {:error, {:duplicate_positions, Enum.sort(dups)}}
      unknown != [] -> {:error, {:unknown_templates, unknown}}
      unpublished != [] -> {:error, {:unpublished_templates, unpublished}}
      true -> :ok
    end
  end

  @spec compose([section_input()], keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  # Required opts: `:created_by_uuid :: UUIDv7.t()`, `:name :: String.t()` (caller-supplied
  # document name; ANDI derives from order/sub-order context). Optional: `:separator`.
  def compose(sections, opts) do
    with {:ok, created_by} <- fetch_opt(opts, :created_by_uuid),
         {:ok, name} <- fetch_opt(opts, :name) do
      compose_with_opts(sections, opts, created_by, name)
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, _} = ok -> ok
      :error -> {:error, {:missing_opt, key}}
    end
  end

  defp compose_with_opts(sections, opts, created_by, name) do
    # Section separator is configurable per spec; MVP only honours :page_break.
    # Future values (:none, :blank_line) will be accepted once implemented.
    # Anything else returns {:error, {:unsupported_separator, _}} so callers
    # get one uniform tagged-tuple error surface — raising would crash the
    # LiveView caller, which is typed {:ok, _} | {:error, _}.
    separator = Keyword.get(opts, :separator, :page_break)

    with :ok <- validate_separator(separator) do
      do_compose(sections, opts, created_by, name)
    end
  end

  defp validate_separator(:page_break), do: :ok
  defp validate_separator(other), do: {:error, {:unsupported_separator, other}}

  defp do_compose(sections, opts, created_by, name) do
    repo = PhoenixKit.RepoHelper.repo()

    templates =
      repo.all(from(t in Template, where: t.uuid in ^Enum.map(sections, & &1.template_uuid)))

    # Template uses status: "published" | "trashed" | ... — translate to boolean for validate_sections.
    template_summaries =
      Enum.map(templates, fn t -> %{uuid: t.uuid, published: t.status == "published"} end)

    with :ok <- validate_sections(sections, all_templates: template_summaries) do
      sorted = Enum.sort_by(sections, & &1.position)
      templates_by_uuid = Map.new(templates, &{&1.uuid, &1})

      case run_multi(sorted, templates_by_uuid, created_by, name, opts) do
        {:ok, %{document: doc}} -> {:ok, doc}
        {:error, _} = err -> err
      end
    end
  end

  # Google Docs HTTP work runs OUTSIDE the transaction so we don't hold a
  # Postgres connection open across multiple network round-trips. Only the two
  # inserts (Document row + DocumentSection rows) run inside a short transaction.
  # If the DB inserts fail, we call best_effort_delete on the already-created
  # Google Doc for orphan cleanup.
  # Dialyzer infers a concrete `%MapSet{map: %{}}` from `Multi.new()`'s
  # implementation and rejects it against the opaque `MapSet.internal(_)` in
  # `Multi.run/3`'s typespec — a known Dialyzer + Ecto.Multi opacity friction,
  # not a runtime issue. The pipeline works correctly at runtime.
  @dialyzer {:nowarn_function, run_multi: 5}
  defp run_multi(sorted_sections, by_uuid, created_by, name, opts) do
    [first | rest] = sorted_sections
    first_template = by_uuid[first.template_uuid]
    client = docs_client()
    repo = PhoenixKit.RepoHelper.repo()

    copy_opts =
      case Keyword.get(opts, :destination_folder_id) do
        nil -> []
        folder_id -> [destination_folder_id: folder_id]
      end

    with {:ok, gdoc_id} <- client.copy_document(first_template.google_doc_id, copy_opts),
         # Capture section 0's range before any appends — indices shift after each append.
         {:ok, base_range} <- client.document_content_range(gdoc_id),
         {:ok, appended} <- append_sections(gdoc_id, rest, by_uuid, client),
         ranges = Map.put(appended, first.position, base_range),
         {:ok, _} <- apply_substitutions(gdoc_id, sorted_sections, ranges, client) do
      insert_result =
        insert_document_and_sections(gdoc_id, sorted_sections, created_by, name, opts, repo)

      case insert_result do
        {:ok, doc} ->
          {:ok, %{document: doc}}

        {:error, reason} ->
          best_effort_delete(gdoc_id, client)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_document_and_sections(gdoc_id, sorted_sections, created_by, name, opts, repo) do
    category_uuid = Keyword.get(opts, :category_uuid)

    Multi.new()
    |> Multi.insert(:document, fn _ ->
      Document.changeset(%Document{}, %{
        name: name,
        google_doc_id: gdoc_id,
        # legacy column not used for composed docs; nullable in DB
        template_uuid: nil,
        created_by_uuid: created_by,
        category_uuid: category_uuid
      })
    end)
    |> Multi.run(:sections, fn _, %{document: doc} ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        Enum.map(sorted_sections, fn s ->
          %{
            document_uuid: doc.uuid,
            template_uuid: s.template_uuid,
            position: s.position,
            variable_values: s.variable_values,
            image_params: s.image_params,
            created_by_uuid: created_by,
            inserted_at: now,
            updated_at: now,
            uuid: UUIDv7.generate()
          }
        end)

      {_count, _} = repo.insert_all(DocumentSection, rows)
      {:ok, :inserted}
    end)
    |> repo.transaction()
    |> case do
      {:ok, %{document: doc}} -> {:ok, doc}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp append_sections(_gdoc_id, [], _by_uuid, _client), do: {:ok, %{}}

  defp append_sections(gdoc_id, rest, by_uuid, client) do
    Enum.reduce_while(rest, {:ok, %{}}, fn section, {:ok, acc} ->
      template = by_uuid[section.template_uuid]

      case client.append_template(gdoc_id, template.google_doc_id) do
        {:ok, range} -> {:cont, {:ok, Map.put(acc, section.position, range)}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # All sections are substituted in a single pass: one documents.get fetch,
  # all {{key}} matches resolved against whichever section's range contains them,
  # then one batchUpdate in reverse-index order. This avoids the index-drift bug
  # that would occur if sections were substituted sequentially (each substitution
  # changes doc length, invalidating stored ranges for subsequent sections).
  defp apply_substitutions(gdoc_id, sorted, ranges, client) do
    case client.substitute_all_sections(gdoc_id, sorted, ranges) do
      :ok -> {:ok, :substituted}
      {:error, _} = err -> err
    end
  end

  defp best_effort_delete(gdoc_id, client) do
    case client.delete_document(gdoc_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("orphaned google doc #{gdoc_id} after rollback: #{inspect(reason)}")
        :ok
    end
  end

  defp docs_client do
    Application.get_env(
      :phoenix_kit_document_creator,
      :docs_client,
      GoogleDocsClient
    )
  end
end
