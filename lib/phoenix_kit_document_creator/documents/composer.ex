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
    created_by = Keyword.fetch!(opts, :created_by_uuid)
    name = Keyword.fetch!(opts, :name)

    # Section separator is configurable per spec; MVP only honours :page_break.
    # Future values (:none, :blank_line) are accepted at the API surface once
    # implemented. Anything else raises ArgumentError so callers can't silently
    # pass an unsupported value.
    separator = Keyword.get(opts, :separator, :page_break)

    unless separator == :page_break do
      raise ArgumentError,
            "unsupported separator #{inspect(separator)}; MVP supports only :page_break"
    end

    repo = PhoenixKit.RepoHelper.repo()

    templates =
      repo.all(from(t in Template, where: t.uuid in ^Enum.map(sections, & &1.template_uuid)))

    template_summaries = Enum.map(templates, &Map.take(&1, [:uuid, :published]))

    with :ok <- validate_sections(sections, all_templates: template_summaries) do
      sorted = Enum.sort_by(sections, & &1.position)
      templates_by_uuid = Map.new(templates, &{&1.uuid, &1})

      case run_multi(sorted, templates_by_uuid, created_by, name) do
        {:ok, %{document: doc}} -> {:ok, doc}
        {:error, _} = err -> err
      end
    end
  end

  defp run_multi(sorted_sections, by_uuid, created_by, name) do
    [first | rest] = sorted_sections
    first_template = by_uuid[first.template_uuid]
    client = docs_client()
    repo = PhoenixKit.RepoHelper.repo()

    Multi.new()
    |> Multi.run(:google_doc, fn _, _ ->
      client.copy_document(first_template.google_doc_id)
    end)
    |> Multi.run(:appended, fn _, %{google_doc: gdoc_id} ->
      append_sections(gdoc_id, rest, by_uuid, client)
    end)
    |> Multi.run(:substituted, fn _, %{google_doc: gdoc_id, appended: ranges} ->
      apply_substitutions(gdoc_id, sorted_sections, ranges, client)
    end)
    |> Multi.insert(:document, fn %{google_doc: gdoc_id} ->
      Document.changeset(%Document{}, %{
        name: name,
        google_doc_id: gdoc_id,
        # legacy column not used for composed docs; nullable in DB
        template_uuid: nil,
        created_by_uuid: created_by
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

      {count, _} = repo.insert_all(DocumentSection, rows)
      {:ok, count}
    end)
    |> repo.transaction()
    |> case do
      {:ok, _} = ok ->
        ok

      # Don't reorder Multi steps without revisiting this cleanup match —
      # :google_doc must remain the first step for the rollback guard to work.
      {:error, _step, reason, %{google_doc: gdoc_id}} ->
        best_effort_delete(gdoc_id, client)
        {:error, reason}

      {:error, _step, reason, _} ->
        {:error, reason}
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

  defp apply_substitutions(gdoc_id, sorted, ranges, client) do
    Enum.reduce_while(sorted, :ok, fn section, _ ->
      range = Map.get(ranges, section.position, :full_document)

      case client.substitute_in_range(
             gdoc_id,
             range,
             section.variable_values,
             section.image_params,
             %{}
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      :ok -> {:ok, :substituted}
      other -> other
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
