defmodule PhoenixKitDocumentCreator.Documents do
  @moduledoc """
  Context module for managing templates and documents via Google Drive.

  Google Drive is the single source of truth for file content. This module
  mirrors file metadata (name, google_doc_id, status, thumbnails, variables)
  to the local database for fast listing and audit tracking.

  ## API layers

  This module provides **combined** operations (Drive + DB). For direct access:

  - **Drive-only** — Use `PhoenixKitDocumentCreator.GoogleDocsClient` for raw Google
    Drive/Docs API calls (create files, list folders, export PDF, move files) without
    touching the local database.
  - **DB-only** — Use `list_templates_from_db/0`, `list_documents_from_db/0`,
    `load_cached_thumbnails/1`, `persist_thumbnail/2` for local DB queries.
  - **Combined** — Use `create_template/2`, `create_document/2`, `sync_from_drive/0`,
    `delete_template/2`, etc. which coordinate between Drive and DB.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker
  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Schemas.Template

  @module_key "document_creator"
  @pubsub_topic "document_creator:files"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Activity logging
  # ===========================================================================

  @doc "Log a manual user action to the activity feed."
  @spec log_manual_action(String.t(), keyword()) :: :ok
  def log_manual_action(action, opts \\ []) do
    attrs = %{
      action: action,
      mode: "manual",
      actor_uuid: opts[:actor_uuid]
    }

    attrs =
      case opts[:metadata] do
        meta when is_map(meta) -> Map.put(attrs, :metadata, meta)
        _ -> attrs
      end

    log_activity(attrs)
    :ok
  end

  defp log_activity(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
    end
  end

  # Log the user-initiated mutation even when it failed, so the audit
  # feed shows the attempt. `db_pending: true` flags the row as not
  # corresponding to a successful state change — without this, a Drive
  # outage would leave admin-clicked deletes/exports/restores invisible
  # in the activity log. Metadata stays minimal/PII-safe; the technical
  # `reason` lives in the surrounding `Logger.error` already.
  defp log_failed_mutation(action, resource_type, opts, base_metadata) do
    log_activity(%{
      action: action,
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: resource_type,
      metadata: Map.put(base_metadata, "db_pending", true)
    })
  end

  # ===========================================================================
  # DB Listing (fast, no API calls)
  # ===========================================================================

  @doc "List templates from the local DB. Returns maps compatible with the LiveView."
  @spec list_templates_from_db() :: [map()]
  def list_templates_from_db do
    Template
    |> where([t], t.status in ["published", "lost", "unfiled"])
    |> where([t], not is_nil(t.google_doc_id))
    |> order_by([t], desc: t.inserted_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  @doc "List documents from the local DB. Returns maps compatible with the LiveView."
  @spec list_documents_from_db() :: [map()]
  def list_documents_from_db do
    Document
    |> where([d], d.status in ["published", "lost", "unfiled"])
    |> where([d], not is_nil(d.google_doc_id))
    |> order_by([d], desc: d.inserted_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  @doc "List trashed templates from the local DB."
  @spec list_trashed_templates_from_db() :: [map()]
  def list_trashed_templates_from_db do
    Template
    |> where([t], t.status == "trashed")
    |> where([t], not is_nil(t.google_doc_id))
    |> order_by([t], desc: t.inserted_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  @doc "List trashed documents from the local DB."
  @spec list_trashed_documents_from_db() :: [map()]
  def list_trashed_documents_from_db do
    Document
    |> where([d], d.status == "trashed")
    |> where([d], not is_nil(d.google_doc_id))
    |> order_by([d], desc: d.inserted_at)
    |> repo().all()
    |> Enum.map(&schema_to_file_map/1)
  end

  defp schema_to_file_map(record) do
    base = %{
      "id" => record.google_doc_id,
      "uuid" => record.uuid,
      "name" => record.name,
      "modifiedTime" =>
        if(record.updated_at, do: DateTime.to_iso8601(record.updated_at), else: nil),
      "status" => record.status || "published",
      "path" => record.path,
      "folder_id" => record.folder_id
    }

    # Templates have a `language` column (V110); documents inherit
    # language from their template at fill time and don't store one.
    if Map.has_key?(record, :language) do
      Map.put(base, "language", record.language)
    else
      base
    end
  end

  # ===========================================================================
  # Thumbnails (DB cache)
  # ===========================================================================

  @doc "Load cached thumbnails from DB for a list of google_doc_ids."
  @spec load_cached_thumbnails([String.t()] | any()) :: %{String.t() => String.t()}
  def load_cached_thumbnails(google_doc_ids) when is_list(google_doc_ids) do
    template_thumbs =
      Template
      |> where([t], t.google_doc_id in ^google_doc_ids and not is_nil(t.thumbnail))
      |> select([t], {t.google_doc_id, t.thumbnail})
      |> repo().all()

    document_thumbs =
      Document
      |> where([d], d.google_doc_id in ^google_doc_ids and not is_nil(d.thumbnail))
      |> select([d], {d.google_doc_id, d.thumbnail})
      |> repo().all()

    Map.new(template_thumbs ++ document_thumbs)
  end

  def load_cached_thumbnails(_), do: %{}

  @doc "Persist a thumbnail data URI to the DB by google_doc_id."
  @spec persist_thumbnail(String.t(), String.t()) :: :ok
  def persist_thumbnail(google_doc_id, data_uri) when is_binary(google_doc_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Template
      |> where([t], t.google_doc_id == ^google_doc_id)
      |> repo().update_all(set: [thumbnail: data_uri, updated_at: now])

    if count == 0 do
      Document
      |> where([d], d.google_doc_id == ^google_doc_id)
      |> repo().update_all(set: [thumbnail: data_uri, updated_at: now])
    end

    :ok
  end

  # ===========================================================================
  # Sync from Google Drive
  # ===========================================================================

  @doc """
  Sync local DB with Google Drive.

  Recursively walks both managed trees (templates and documents), upserts every
  Google Doc found (including those nested in subfolders) with its actual
  parent `folder_id` and human-readable `path`, then reconciles DB records
  against the walk — records whose `google_doc_id` is missing from the walk
  are re-classified via a per-file Drive API call as `trashed`, `lost`, or
  `unfiled` according to their current Drive parents.

  Files in any descendant of a managed folder are treated as `published`.
  """
  @spec sync_from_drive() :: :ok | {:error, :sync_failed}
  def sync_from_drive do
    with %{templates_folder_id: tid, documents_folder_id: did}
         when is_binary(tid) and is_binary(did) <- get_folder_ids(),
         {:ok, template_tree} <-
           DriveWalker.walk_tree(tid, root_path: managed_location(:template).path),
         {:ok, document_tree} <-
           DriveWalker.walk_tree(did, root_path: managed_location(:document).path) do
      Enum.each(template_tree.files, fn file ->
        upsert_template_from_drive(file, upsert_attrs_from_walked(file, :template))
      end)

      Enum.each(document_tree.files, fn file ->
        upsert_document_from_drive(file, upsert_attrs_from_walked(file, :document))
      end)

      drive_template_ids = MapSet.new(template_tree.files, & &1["id"])
      drive_document_ids = MapSet.new(document_tree.files, & &1["id"])
      template_folder_ids = MapSet.new(Map.keys(template_tree.folders))
      document_folder_ids = MapSet.new(Map.keys(document_tree.folders))

      template_changes = reconcile_status(Template, drive_template_ids, template_folder_ids)
      document_changes = reconcile_status(Document, drive_document_ids, document_folder_ids)

      log_activity(%{
        action: "sync.completed",
        mode: "auto",
        resource_type: "sync",
        metadata: %{
          "templates_synced" => length(template_tree.files),
          "documents_synced" => length(document_tree.files),
          "template_folders_walked" => map_size(template_tree.folders),
          "document_folders_walked" => map_size(document_tree.folders),
          "templates_lost" => length(template_changes[:lost] || []),
          "templates_trashed" => length(template_changes[:trashed] || []),
          "templates_unfiled" => length(template_changes[:unfiled] || []),
          "documents_lost" => length(document_changes[:lost] || []),
          "documents_trashed" => length(document_changes[:trashed] || []),
          "documents_unfiled" => length(document_changes[:unfiled] || [])
        }
      })

      :ok
    else
      reason ->
        # Pull the folder IDs from `get_folder_ids/0` again so the log
        # captures which folder was being walked when the failure
        # surfaced. Without this, "sync_from_drive failed: {:error, _}"
        # gives ops nothing to grep — it's the only signal we have when
        # a sync fails (no per-file activity row is written on failure).
        ids = get_folder_ids()

        Logger.error(
          "Document Creator sync_from_drive failed | " <>
            "templates_folder_id=#{inspect(ids[:templates_folder_id])} | " <>
            "documents_folder_id=#{inspect(ids[:documents_folder_id])} | " <>
            "reason=#{inspect(reason)}"
        )

        {:error, :sync_failed}
    end
  end

  # Extract location attrs for upsert. Prefer the folder_id/path annotated
  # onto the file by the walker; fall back to managed-root so pre-walker
  # records don't regress.
  defp upsert_attrs_from_walked(file, type) do
    default = managed_location(type)

    %{
      folder_id: file["folder_id"] || default.folder_id,
      path: file["path"] || default.path
    }
  end

  # ===========================================================================
  # Upsert from Drive
  # ===========================================================================

  @doc "Upsert a template record from a Google Drive file map."
  @spec upsert_template_from_drive(map(), map()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def upsert_template_from_drive(%{"id" => gid, "name" => name} = _file, extra_attrs \\ %{}) do
    attrs = Map.merge(%{google_doc_id: gid, name: name, status: "published"}, extra_attrs)

    %Template{}
    |> Template.sync_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(google_doc_id) WHERE google_doc_id IS NOT NULL"}
    )
  end

  @doc "Upsert a document record from a Google Drive file map."
  @spec upsert_document_from_drive(map(), map()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def upsert_document_from_drive(%{"id" => gid, "name" => name} = _file, extra_attrs \\ %{}) do
    attrs = Map.merge(%{google_doc_id: gid, name: name, status: "published"}, extra_attrs)

    %Document{}
    |> Document.sync_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(google_doc_id) WHERE google_doc_id IS NOT NULL"}
    )
  end

  # ===========================================================================
  # Status reconciliation
  # ===========================================================================

  # Returns a map of status => [uuids] for logging purposes.
  #
  # `allowed_folder_ids` is the MapSet of folder IDs the walker enumerated
  # (the managed root + all descendants). A tracked record whose parent
  # sits anywhere in that set is `:published` — descendant subfolders are
  # no longer misclassified as `:unfiled`.
  defp reconcile_status(schema, drive_ids, allowed_folder_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    managed_location = managed_location(schema_type(schema))
    deleted_folder_id = deleted_folder_id(schema_type(schema))

    tracked_records =
      schema
      |> where([r], r.status in ["published", "lost", "unfiled"] and not is_nil(r.google_doc_id))
      |> select([r], {r.uuid, r.google_doc_id, r.folder_id})
      |> repo().all()

    grouped =
      Enum.group_by(
        tracked_records,
        fn {_uuid, gid, folder_id} ->
          classify_file(
            gid,
            folder_id,
            drive_ids,
            allowed_folder_ids,
            managed_location,
            deleted_folder_id
          )
        end,
        fn {uuid, _gid, _folder_id} -> uuid end
      )

    update_statuses(schema, Map.get(grouped, :published, []), "published", now)
    update_statuses(schema, Map.get(grouped, :lost, []), "lost", now)
    update_statuses(schema, Map.get(grouped, :trashed, []), "trashed", now)
    update_statuses(schema, Map.get(grouped, :unfiled, []), "unfiled", now)

    grouped
  end

  defp classify_file(
         gid,
         folder_id,
         drive_ids,
         allowed_folder_ids,
         managed_loc,
         deleted_folder_id
       ) do
    if MapSet.member?(drive_ids, gid) do
      :published
    else
      classify_by_api(gid, folder_id, allowed_folder_ids, managed_loc, deleted_folder_id)
    end
  end

  defp classify_by_api(gid, folder_id, allowed_folder_ids, managed_location, deleted_folder_id) do
    case GoogleDocsClient.file_status(gid) do
      {:ok, %{trashed: true}} ->
        :trashed

      {:ok, %{parents: parents}} when is_list(parents) ->
        classify_by_location(
          parents,
          folder_id,
          allowed_folder_ids,
          managed_location,
          deleted_folder_id
        )

      _ ->
        :lost
    end
  end

  @doc false
  # Classify a tracked file into :published / :trashed / :unfiled based on
  # its Drive parents, the record's stored folder_id, the managed-location
  # configuration, the deleted-folder ID, and the MapSet of folder IDs
  # enumerated by the most recent walker run. Exposed for testing.
  def classify_by_location(
        parents,
        folder_id,
        allowed_folder_ids,
        managed_location,
        deleted_folder_id
      )
      when is_list(parents) do
    accepted_folder_id = folder_id || managed_location.folder_id

    cond do
      is_binary(deleted_folder_id) and deleted_folder_id in parents ->
        :trashed

      is_binary(accepted_folder_id) and accepted_folder_id in parents ->
        :published

      Enum.any?(parents, &MapSet.member?(allowed_folder_ids, &1)) ->
        :published

      true ->
        :unfiled
    end
  end

  defp update_file_by_google_doc_id(google_doc_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :updated_at, now)

    Template
    |> where([t], t.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: Map.to_list(attrs))

    Document
    |> where([d], d.google_doc_id == ^google_doc_id)
    |> repo().update_all(set: Map.to_list(attrs))
  end

  defp update_statuses(_schema, [], _status, _now), do: :ok

  defp update_statuses(schema, uuids, status, now) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> repo().update_all(set: [status: status, updated_at: now])
  end

  # ===========================================================================
  # Creating
  # ===========================================================================

  @doc """
  Create a blank template in the templates folder. Returns `{:ok, %{doc_id, name, url}}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  - `:language` — locale code to tag the template with. Defaults to the
    project's primary language from `PhoenixKit.Modules.Languages`.
    Pass `nil` to leave it unset; pass an explicit code (e.g. `"et-EE"`)
    to override.
  """
  @spec create_template(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_template(name \\ "Untitled Template", opts \\ []) do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_template_from_drive(
              %{"id" => doc_id, "name" => name},
              managed_location_attrs(:template)
            )

            language = resolve_create_language(opts)
            apply_template_language(doc_id, language)

            log_activity(%{
              action: "template.created",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "template",
              metadata: %{
                "name" => name,
                "google_doc_id" => doc_id,
                "language" => language
              }
            })

            {:ok, result}

          error ->
            log_failed_mutation("template.created", "template", opts, %{"name" => name})
            error
        end

      _ ->
        log_failed_mutation("template.created", "template", opts, %{"name" => name})
        {:error, :templates_folder_not_found}
    end
  end

  # Resolve the language for a newly-created template:
  #   * caller passed `language: ...` (incl. nil) → use that exact value
  #   * caller omitted → fall back to project's primary language
  defp resolve_create_language(opts) do
    if Keyword.has_key?(opts, :language) do
      Keyword.get(opts, :language)
    else
      default_language_code()
    end
  end

  @doc """
  Lookup the project's enabled languages, sorted by configured position.

  Returns `[%{code: "en-US", name: "English (United States)"}, ...]` or
  `[]` when core's `PhoenixKit.Modules.Languages` is disabled or the
  settings table isn't reachable. Safe to call from LiveView mount —
  failure is swallowed, never crashes the caller.
  """
  @spec list_enabled_languages() :: [%{code: String.t(), name: String.t()}]
  def list_enabled_languages do
    if Code.ensure_loaded?(Languages) do
      try do
        Languages.get_enabled_languages()
        |> Enum.map(fn lang -> %{code: lang.code, name: lang.name} end)
      rescue
        _ in [ArgumentError, KeyError, MatchError, BadMapError] -> []
        _ in [DBConnection.ConnectionError, Postgrex.Error] -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  # Look up the project's primary language code via core's Languages
  # module. Same rescue/catch shape as `default_managed/2` — narrow
  # exception classes (Settings shape errors + DB unavailability).
  # Failing here must not crash template creation; nil is the safe
  # fallback — the form pre-select just renders empty, the user can
  # still pick from the dropdown.
  defp default_language_code do
    if Code.ensure_loaded?(Languages) do
      try do
        case Languages.get_default_language() do
          %{code: code} when is_binary(code) -> code
          _ -> nil
        end
      rescue
        _ in [ArgumentError, KeyError, MatchError, BadMapError] -> nil
        _ in [DBConnection.ConnectionError, Postgrex.Error] -> nil
      catch
        :exit, _ -> nil
      end
    end
  end

  defp apply_template_language(_doc_id, nil), do: :ok

  defp apply_template_language(doc_id, language) when is_binary(language) do
    {count, _} =
      Template
      |> where([t], t.google_doc_id == ^doc_id)
      |> repo().update_all(set: [language: language])

    # `update_all` returns the row count it touched. Zero means the
    # template row vanished between `upsert_template_from_drive/2` and
    # this stamp — the only realistic cause is a concurrent race that
    # shouldn't happen via the admin UI but might via an OTP message
    # or a future async path. Logging it preserves audit visibility
    # without escalating to caller-facing failure (the Drive doc was
    # already created successfully; missing language is recoverable
    # via `update_template_language/3`).
    if count == 0 do
      Logger.warning(
        "[DocumentCreator] apply_template_language no-op | google_doc_id=#{inspect(doc_id)} | language=#{inspect(language)}"
      )
    end

    :ok
  end

  @doc """
  Create a blank document in the documents folder. Returns `{:ok, %{doc_id, name, url}}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec create_document(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_document(name \\ "Untitled Document", opts \\ []) do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) ->
        case GoogleDocsClient.create_document(name, parent: id) do
          {:ok, %{doc_id: doc_id} = result} ->
            upsert_document_from_drive(
              %{"id" => doc_id, "name" => name},
              managed_location_attrs(:document)
            )

            log_activity(%{
              action: "document.created",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "document",
              metadata: %{"name" => name, "google_doc_id" => doc_id}
            })

            {:ok, result}

          error ->
            log_failed_mutation("document.created", "document", opts, %{"name" => name})
            error
        end

      _ ->
        log_failed_mutation("document.created", "document", opts, %{"name" => name})
        {:error, :documents_folder_not_found}
    end
  end

  @doc """
  Create a document from a template by copying and filling variables.

  1. Copies the template Google Doc into the target folder
  2. Replaces all `{{variable}}` placeholders with values
  3. Persists the document record with variable_values and template link
  4. Returns `{:ok, %{doc_id, url}}`

  ## Options

  - `:name` — document name (default `"New Document"`)
  - `:actor_uuid` — UUID of the user performing the action (activity log)
  - `:parent_folder_id` — Drive folder ID to copy into. Defaults to the
    managed documents folder. Supply this to place the new document in a
    subfolder (e.g. `order-123/sub-4/`) you manage yourself.
  - `:path` — human-readable path string to store on the record. Only
    meaningful when `:parent_folder_id` is also supplied. If omitted when
    `:parent_folder_id` is given, the stored `path` is left unset and the
    next `sync_from_drive/0` fills it from the walker.
  """
  @spec create_document_from_template(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_document_from_template(template_file_id, variable_values, opts \\ []) do
    doc_name = Keyword.get(opts, :name, "New Document")

    with {:ok, target} <- resolve_create_target(opts),
         {:ok, new_doc_id} <-
           GoogleDocsClient.copy_file(template_file_id, doc_name, parent: target.folder_id),
         {:ok, _} <- GoogleDocsClient.replace_all_text(new_doc_id, variable_values) do
      persist_created_document(
        new_doc_id,
        template_file_id,
        doc_name,
        variable_values,
        target,
        opts
      )
    end
  end

  defp resolve_create_target(opts) do
    case Keyword.get(opts, :parent_folder_id) do
      nil ->
        case get_folder_ids() do
          %{documents_folder_id: id} when is_binary(id) ->
            loc = managed_location(:document)
            {:ok, %{folder_id: id, path: loc.path}}

          _ ->
            {:error, :documents_folder_not_found}
        end

      folder_id when is_binary(folder_id) and folder_id != "" ->
        {:ok, %{folder_id: folder_id, path: Keyword.get(opts, :path)}}

      _ ->
        {:error, :invalid_parent_folder_id}
    end
  end

  defp persist_created_document(
         new_doc_id,
         template_file_id,
         doc_name,
         variable_values,
         target,
         opts
       ) do
    template_uuid = get_template_uuid_by_google_doc_id(template_file_id)

    result =
      %Document{}
      |> Document.creation_changeset(%{
        name: doc_name,
        google_doc_id: new_doc_id,
        template_uuid: template_uuid,
        variable_values: variable_values,
        status: "published",
        path: target.path,
        folder_id: target.folder_id
      })
      |> repo().insert()

    base_metadata = %{
      "name" => doc_name,
      "google_doc_id" => new_doc_id,
      "template_google_doc_id" => template_file_id,
      "template_uuid" => template_uuid,
      "variables_used" => Map.keys(variable_values),
      "folder_id" => target.folder_id,
      "path" => target.path
    }

    case result do
      {:ok, _record} ->
        log_activity(%{
          action: "document.created_from_template",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: base_metadata
        })

      {:error, changeset} ->
        # Drive succeeded; DB cache write failed. Log the activity row
        # anyway with `db_pending: true` so the audit feed reflects the
        # user-initiated action — without this, an admin could create
        # 100 documents during a DB hiccup and have zero activity log
        # entries (the next sync will upsert the records but with the
        # auto-mode `sync.completed` event, not the manual one).
        Logger.error(
          "Document Creator: persist document from template failed | " <>
            "google_doc_id=#{new_doc_id} | template_uuid=#{template_uuid} | " <>
            "errors=#{inspect(changeset.errors)}"
        )

        log_activity(%{
          action: "document.created_from_template",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: Map.put(base_metadata, "db_pending", true)
        })
    end

    # Return success even if the DB cache write failed — the Drive doc
    # exists and the next sync will reconcile it. The user-facing flow
    # works either way (they get the URL and edit in Google Docs); the
    # `db_pending` activity flag preserves auditability.
    {:ok, %{doc_id: new_doc_id, url: GoogleDocsClient.get_edit_url(new_doc_id)}}
  end

  defp get_template_uuid_by_google_doc_id(google_doc_id) do
    Template
    |> where([t], t.google_doc_id == ^google_doc_id)
    |> select([t], t.uuid)
    |> repo().one()
  end

  # ===========================================================================
  # Registering existing Drive files (consumer-managed create flows)
  # ===========================================================================

  @doc """
  Register a Drive document that the caller has already created (or already
  knows about) into the local DB.

  Use this when your own wrapper code handles the Drive-side work (copy,
  placement in a subfolder, variable substitution) and you just need the
  file to appear in `list_documents_from_db/0` and be classified correctly
  by future `sync_from_drive/0` runs.

  **Makes no Drive API calls.** This is a pure DB upsert — garbage inputs
  do not error, they self-correct on the next sync (the walker rewrites
  `path`/`folder_id`, and files that are not actually in the managed tree
  get classified `:unfiled` or `:lost` per the usual reconciliation rules).

  ## `attrs` — map keyed by atoms or strings

  | Key               | Required | Notes                                                     |
  | ----------------- | -------- | --------------------------------------------------------- |
  | `google_doc_id`   | yes      | Drive file ID                                             |
  | `name`            | yes      | Display name                                              |
  | `template_uuid`   | no       | UUID of the source template, if applicable                |
  | `variable_values` | no       | Map of variables substituted during generation            |
  | `folder_id`       | no       | Actual Drive folder holding the file. Defaults to managed |
  | `path`            | no       | Human-readable path. Defaults to managed root path        |
  | `status`          | no       | Defaults to `"published"`                                 |
  | `thumbnail`       | no       | Optional data URI                                         |

  If `:folder_id` points outside the managed documents tree, the next
  `sync_from_drive/0` will classify the record as `:unfiled` and surface
  the resolution popup in the admin UI.

  ## `opts`

  - `:actor_uuid` — user UUID for the activity log
  - `:emit_pubsub` — default `true`. Broadcasts `:files_changed` on the
    `document_creator:files` topic so connected admin LiveViews re-sync.
    Bulk callers (e.g. a backfill script registering hundreds of rows)
    should pass `false` and trigger **one** broadcast or sync at the end:

        Enum.each(rows, &Documents.register_existing_document(&1, emit_pubsub: false))
        Documents.broadcast_files_changed()
  """
  @spec register_existing_document(map(), keyword()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t() | term()}
  def register_existing_document(attrs, opts \\ []) when is_map(attrs) do
    register_existing(:document, attrs, opts)
  end

  @doc """
  Register a Drive template that the caller has already created or knows about.

  Symmetric to `register_existing_document/2` — see its documentation for the
  `attrs` shape and options. Unlike documents, template registration does not
  accept `template_uuid` or `variable_values`.
  """
  @spec register_existing_template(map(), keyword()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t() | term()}
  def register_existing_template(attrs, opts \\ []) when is_map(attrs) do
    register_existing(:template, attrs, opts)
  end

  @doc """
  Set the locale on a template, looked up by `google_doc_id`.

  Pass `nil` (or an empty string) to clear the language. Otherwise the
  full locale code (e.g. `"en-US"`, `"et-EE"`) — typically sourced from
  `PhoenixKit.Modules.Languages.get_enabled_languages/0`.

  Logs `template.language_updated` with the from/to pair on success and
  broadcasts `:files_changed` so connected admin LiveViews resync.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (activity log)
  """
  @spec update_template_language(String.t(), String.t() | nil, keyword()) ::
          {:ok, Template.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_template_language(google_doc_id, language, opts \\ [])
      when is_binary(google_doc_id) do
    normalized =
      case language do
        nil -> nil
        "" -> nil
        code when is_binary(code) -> code
      end

    case repo().get_by(Template, google_doc_id: google_doc_id) do
      nil ->
        log_failed_mutation("template.language_updated", "template", opts, %{
          "google_doc_id" => google_doc_id,
          "language_to" => normalized
        })

        {:error, :not_found}

      %Template{language: previous} = template ->
        template
        |> Template.changeset(%{language: normalized})
        |> repo().update()
        |> case do
          {:ok, updated} ->
            log_activity(%{
              action: "template.language_updated",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "template",
              resource_uuid: updated.uuid,
              metadata: %{
                "name" => updated.name,
                "google_doc_id" => updated.google_doc_id,
                "language_from" => previous,
                "language_to" => updated.language
              }
            })

            broadcast_files_changed()
            {:ok, updated}

          {:error, changeset} = err ->
            log_failed_mutation("template.language_updated", "template", opts, %{
              "google_doc_id" => google_doc_id,
              "language_to" => normalized
            })

            _ = changeset
            err
        end
    end
  end

  defp register_existing(kind, attrs, opts) do
    with {:ok, a} <- normalize_register_attrs(attrs),
         file = %{"id" => a.google_doc_id, "name" => a.name},
         extra = register_upsert_extras(a, kind),
         {:ok, record} <- do_register_upsert(kind, file, extra, a) do
      log_register(kind, record, a, opts)
      maybe_emit_pubsub(opts)
      {:ok, record}
    end
  end

  defp register_upsert_extras(a, kind) do
    %{
      folder_id: a[:folder_id] || default_managed(kind, :folder_id),
      path: a[:path] || default_managed(kind, :path),
      status: a[:status] || "published",
      thumbnail: a[:thumbnail]
    }
  end

  # Settings lookup can fail (e.g. in tests without the core schema, or
  # when folder discovery hasn't run). A nil default is safe: the next
  # `sync_from_drive/0` will rewrite `folder_id`/`path` from the walker.
  # Rescue only the exception classes this path can plausibly raise —
  # missing Settings/config shapes (KeyError/BadMapError/MatchError),
  # bad args to Map.get inputs (ArgumentError), and DB unavailability
  # (Postgrex/DBConnection). A bare `rescue _` would also swallow
  # RuntimeError and FunctionClauseError from future typos.
  defp default_managed(kind, key) do
    Map.get(managed_location(kind), key)
  rescue
    _ in [ArgumentError, KeyError, MatchError, BadMapError] -> nil
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> nil
  end

  defp maybe_emit_pubsub(opts) do
    if Keyword.get(opts, :emit_pubsub, true), do: broadcast_files_changed()
  end

  defp do_register_upsert(:template, file, extra, _a) do
    upsert_template_from_drive(file, extra)
  end

  defp do_register_upsert(:document, file, extra, a) do
    base_attrs = %{
      name: file["name"],
      google_doc_id: file["id"],
      status: extra[:status] || "published",
      path: extra[:path],
      folder_id: extra[:folder_id]
    }

    # Only include optional fields when the caller actually supplied them;
    # otherwise the nil would clobber a previously-set value on re-register.
    attrs =
      base_attrs
      |> maybe_put(:template_uuid, a[:template_uuid])
      |> maybe_put(:variable_values, a[:variable_values])
      |> maybe_put(:thumbnail, extra[:thumbnail])

    # Replace list intentionally mirrors `upsert_document_from_drive/2` —
    # `template_uuid` / `variable_values` / `thumbnail` are preserved across
    # re-registrations so a second call that omits them does not reset them.
    %Document{}
    |> Document.creation_changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:name, :status, :path, :folder_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(google_doc_id) WHERE google_doc_id IS NOT NULL"}
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_register_attrs(attrs) do
    a = atomize_register_attrs(attrs)

    cond do
      not (is_binary(a[:google_doc_id]) and a[:google_doc_id] != "") ->
        {:error, :missing_google_doc_id}

      match?({:error, _}, GoogleDocsClient.validate_file_id(a[:google_doc_id])) ->
        {:error, :invalid_google_doc_id}

      not (is_binary(a[:name]) and a[:name] != "") ->
        {:error, :missing_name}

      true ->
        {:ok, a}
    end
  end

  @register_keys ~w(google_doc_id name template_uuid variable_values folder_id path status thumbnail)a

  defp atomize_register_attrs(attrs) do
    Enum.reduce(@register_keys, %{}, fn key, acc ->
      value = Map.get(attrs, key) || Map.get(attrs, to_string(key))
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp log_register(:template, record, a, opts) do
    log_activity(%{
      action: "template.registered_existing",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "template",
      metadata: %{
        "name" => a[:name],
        "google_doc_id" => record.google_doc_id,
        "folder_id" => record.folder_id,
        "path" => record.path
      }
    })
  end

  defp log_register(:document, record, a, opts) do
    log_activity(%{
      action: "document.registered_existing",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "document",
      metadata: %{
        "name" => a[:name],
        "google_doc_id" => record.google_doc_id,
        "folder_id" => record.folder_id,
        "path" => record.path,
        "template_uuid" => a[:template_uuid],
        "variables_used" => (a[:variable_values] && Map.keys(a[:variable_values])) || []
      }
    })
  end

  @doc """
  The PubSub topic on which `{:files_changed, self()}` messages are
  broadcast whenever a template or document DB record is mutated.

  Admin LiveViews subscribe to this topic in `mount/3`. Prefer calling
  this helper over hard-coding the topic string so the two stay in sync.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Broadcast `{:files_changed, self()}` on the `document_creator:files` topic.

  Use this after a bulk `register_existing_document/2` / `register_existing_template/2`
  call that passed `emit_pubsub: false`, to trigger a single resync in any
  connected admin LiveViews.

  Silently no-ops if the PubSub system isn't available (e.g. background
  jobs or tests without a running PubSub registry).
  """
  @spec broadcast_files_changed() :: :ok
  def broadcast_files_changed do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      try do
        PhoenixKit.PubSubHelper.broadcast(@pubsub_topic, {:files_changed, self()})
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ===========================================================================
  # Unfiled actions
  # ===========================================================================

  @doc """
  Move a file into the managed templates folder and classify it as a template.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec move_to_templates(String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_templates(file_id, opts \\ []) when is_binary(file_id) do
    case reclassify_file(file_id, :template) do
      :ok ->
        log_activity(%{
          action: "file.reclassified",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "template",
          metadata: %{
            "google_doc_id" => file_id,
            "action" => "move_to_templates"
          }
        })

        :ok

      error ->
        error
    end
  end

  @doc """
  Move a file into the managed documents folder and classify it as a document.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec move_to_documents(String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_documents(file_id, opts \\ []) when is_binary(file_id) do
    case reclassify_file(file_id, :document) do
      :ok ->
        log_activity(%{
          action: "file.reclassified",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{
            "google_doc_id" => file_id,
            "action" => "move_to_documents"
          }
        })

        :ok

      error ->
        error
    end
  end

  @doc """
  Persist the file's current parent folder as its accepted location.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec set_correct_location(String.t(), keyword()) :: :ok | {:error, term()}
  def set_correct_location(file_id, opts \\ []) when is_binary(file_id) do
    with {:ok, %{folder_id: folder_id, path: path, trashed: false}} <-
           GoogleDocsClient.file_location(file_id),
         {type, _record} <- find_file_record(file_id) do
      update_file_by_google_doc_id(file_id, %{
        status: "published",
        folder_id: folder_id,
        path: path
      })

      log_activity(%{
        action: "file.location_accepted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: to_string(type),
        metadata: %{
          "google_doc_id" => file_id,
          "folder_id" => folder_id,
          "path" => path
        }
      })

      :ok
    else
      {:ok, %{trashed: true}} ->
        log_failed_mutation("file.location_accepted", "file", opts, %{
          "google_doc_id" => file_id
        })

        {:error, :file_trashed}

      nil ->
        log_failed_mutation("file.location_accepted", "file", opts, %{
          "google_doc_id" => file_id
        })

        {:error, :not_found}

      {:error, _} = err ->
        log_failed_mutation("file.location_accepted", "file", opts, %{
          "google_doc_id" => file_id
        })

        err
    end
  end

  defp reclassify_file(file_id, target_type) do
    location = managed_location(target_type)

    with %{folder_id: folder_id} when is_binary(folder_id) <- location,
         source_record <- find_file_record(file_id),
         true <- not is_nil(source_record),
         :ok <- GoogleDocsClient.move_file(file_id, folder_id) do
      persist_reclassified_record(source_record, target_type, location)
    else
      %{folder_id: nil} -> {:error, :folder_not_found}
      %{} -> {:error, :folder_not_found}
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp persist_reclassified_record({:template, record}, :template, location) do
    update_file_by_google_doc_id(
      record.google_doc_id,
      Map.merge(%{status: "published"}, Map.take(location, [:path, :folder_id]))
    )

    :ok
  end

  defp persist_reclassified_record({:document, record}, :document, location) do
    update_file_by_google_doc_id(
      record.google_doc_id,
      Map.merge(%{status: "published"}, Map.take(location, [:path, :folder_id]))
    )

    :ok
  end

  defp persist_reclassified_record({:template, record}, :document, location) do
    case repo().transaction(fn ->
           upsert_document_from_drive(
             %{"id" => record.google_doc_id, "name" => record.name},
             location
             |> Map.take([:path, :folder_id])
             |> Map.put(:status, "published")
             |> Map.put(:thumbnail, record.thumbnail)
           )

           repo().delete(record)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:transaction_failed, reason}}
    end
  end

  defp persist_reclassified_record({:document, record}, :template, location) do
    case repo().transaction(fn ->
           upsert_template_from_drive(
             %{"id" => record.google_doc_id, "name" => record.name},
             location
             |> Map.take([:path, :folder_id])
             |> Map.put(:status, "published")
             |> Map.put(:thumbnail, record.thumbnail)
           )

           repo().delete(record)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:transaction_failed, reason}}
    end
  end

  defp find_file_record(file_id) do
    case repo().get_by(Template, google_doc_id: file_id) do
      nil ->
        case repo().get_by(Document, google_doc_id: file_id) do
          nil -> nil
          record -> {:document, record}
        end

      record ->
        {:template, record}
    end
  end

  # ===========================================================================
  # Deleting (soft — moves to deleted folder)
  # ===========================================================================

  @doc """
  Move a document to the deleted/documents folder.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec delete_document(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_document(file_id, opts \\ []) when is_binary(file_id) do
    case move_to_deleted_folder(file_id, :deleted_documents_folder_id) do
      :ok ->
        log_activity(%{
          action: "document.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        log_failed_mutation("document.deleted", "document", opts, %{"google_doc_id" => file_id})
        error
    end
  end

  @doc """
  Move a template to the deleted/templates folder.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  """
  @spec delete_template(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_template(file_id, opts \\ []) when is_binary(file_id) do
    case move_to_deleted_folder(file_id, :deleted_templates_folder_id) do
      :ok ->
        log_activity(%{
          action: "template.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "template",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        log_failed_mutation("template.deleted", "template", opts, %{"google_doc_id" => file_id})
        error
    end
  end

  defp move_to_deleted_folder(file_id, folder_key) do
    with {:ok, folder_id} <- resolve_deleted_folder_id(folder_key),
         :ok <- GoogleDocsClient.move_file(file_id, folder_id) do
      update_file_by_google_doc_id(file_id, %{
        status: "trashed",
        folder_id: folder_id,
        path: deleted_folder_path(folder_key)
      })

      :ok
    end
  end

  defp resolve_deleted_folder_id(folder_key) do
    case get_folder_ids() do
      %{^folder_key => id} when is_binary(id) ->
        {:ok, id}

      _ ->
        case refresh_folders() do
          %{^folder_key => id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :deleted_folder_not_found}
        end
    end
  end

  # ===========================================================================
  # Restoring (from trashed → published)
  # ===========================================================================

  @doc "Restore a trashed document back to the documents folder."
  @spec restore_document(String.t(), keyword()) :: :ok | {:error, term()}
  def restore_document(file_id, opts \\ []) when is_binary(file_id) do
    case move_from_deleted_folder(file_id, :document) do
      :ok ->
        log_activity(%{
          action: "document.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        log_failed_mutation("document.restored", "document", opts, %{"google_doc_id" => file_id})
        error
    end
  end

  @doc "Restore a trashed template back to the templates folder."
  @spec restore_template(String.t(), keyword()) :: :ok | {:error, term()}
  def restore_template(file_id, opts \\ []) when is_binary(file_id) do
    case move_from_deleted_folder(file_id, :template) do
      :ok ->
        log_activity(%{
          action: "template.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "template",
          metadata: %{"google_doc_id" => file_id}
        })

        :ok

      error ->
        log_failed_mutation("template.restored", "template", opts, %{"google_doc_id" => file_id})
        error
    end
  end

  defp move_from_deleted_folder(file_id, type) do
    location = managed_location(type)

    with %{folder_id: folder_id} when is_binary(folder_id) <- location,
         :ok <- GoogleDocsClient.move_file(file_id, folder_id) do
      update_file_by_google_doc_id(file_id, %{
        status: "published",
        folder_id: folder_id,
        path: location.path
      })

      :ok
    else
      %{folder_id: nil} -> {:error, :live_folder_not_found}
      %{} -> {:error, :live_folder_not_found}
      error -> error
    end
  end

  # ===========================================================================
  # Variables
  # ===========================================================================

  @doc "Detect `{{ variables }}` in a Google Doc's text content."
  # No activity log entry: this is a cache update (variables are derived
  # from the Doc's text and re-detected every time the modal selects a
  # template). Treating each detection as a user action would flood the
  # activity feed with one row per template-pick. The mutating writes
  # that *consume* the detected variables — `create_document_from_template`,
  # `register_existing_*` — log activity at the right granularity.
  @spec detect_variables(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def detect_variables(file_id) when is_binary(file_id) do
    case GoogleDocsClient.get_document_text(file_id) do
      {:ok, text} ->
        vars = PhoenixKitDocumentCreator.Variable.extract_variables(text)

        # Persist variable definitions to the template record
        var_defs =
          PhoenixKitDocumentCreator.Variable.build_definitions(vars)
          |> Enum.map(&Map.from_struct/1)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Template
        |> where([t], t.google_doc_id == ^file_id)
        |> repo().update_all(set: [variables: var_defs, updated_at: now])

        {:ok, vars}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # PDF Export
  # ===========================================================================

  @doc """
  Export a Google Doc to PDF. Returns `{:ok, pdf_binary}`.

  ## Options

  - `:actor_uuid` — UUID of the user performing the action (for activity logging)
  - `:name` — document name (for activity metadata)
  """
  @spec export_pdf(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def export_pdf(file_id, opts \\ []) when is_binary(file_id) do
    case GoogleDocsClient.export_pdf(file_id) do
      {:ok, pdf_binary} = result ->
        log_activity(%{
          action: "document.exported_pdf",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "document",
          metadata: %{
            "google_doc_id" => file_id,
            "name" => opts[:name],
            "size_bytes" => byte_size(pdf_binary)
          }
        })

        result

      error ->
        log_failed_mutation("document.exported_pdf", "document", opts, %{
          "google_doc_id" => file_id,
          "name" => opts[:name]
        })

        error
    end
  end

  # ===========================================================================
  # Thumbnails
  # ===========================================================================

  @doc """
  Fetch thumbnails for a list of Drive files asynchronously.

  Spawns a single supervised parent task under `PhoenixKit.TaskSupervisor`
  that fans out via `Task.async_stream/3` with a bounded `max_concurrency`
  so opening a folder with hundreds of files doesn't fire hundreds of
  simultaneous Drive requests. Each completion sends `{:thumbnail_result,
  file_id, data_uri}` back to `caller_pid` and persists the thumbnail to
  the DB. The parent is `restart: :temporary` so it dies cleanly if the
  caller LV closes mid-fetch — but in-flight persists still complete.
  """
  @thumbnail_concurrency 8
  @thumbnail_task_timeout :timer.seconds(30)

  @spec fetch_thumbnails_async([map()], pid()) :: :ok
  def fetch_thumbnails_async(files, caller_pid) when is_list(files) do
    Task.Supervisor.start_child(
      PhoenixKit.TaskSupervisor,
      fn ->
        files
        |> Task.async_stream(
          fn file -> fetch_and_notify_thumbnail(file["id"], caller_pid) end,
          max_concurrency: @thumbnail_concurrency,
          ordered: false,
          on_timeout: :kill_task,
          timeout: @thumbnail_task_timeout
        )
        |> Stream.run()
      end,
      restart: :temporary
    )

    :ok
  end

  defp fetch_and_notify_thumbnail(file_id, caller_pid) do
    case GoogleDocsClient.fetch_thumbnail(file_id) do
      {:ok, data_uri} ->
        persist_thumbnail(file_id, data_uri)
        send(caller_pid, {:thumbnail_result, file_id, data_uri})

      _ ->
        :ok
    end
  end

  defp schema_type(Template), do: :template
  defp schema_type(Document), do: :document

  defp managed_location_attrs(type) do
    managed_location(type)
    |> Map.take([:path, :folder_id])
  end

  defp managed_location(:template) do
    ids = get_folder_ids()
    config = GoogleDocsClient.get_folder_config()

    %{
      path: join_path(config.templates_path, config.templates_name),
      folder_id: ids[:templates_folder_id]
    }
  end

  defp managed_location(:document) do
    ids = get_folder_ids()
    config = GoogleDocsClient.get_folder_config()

    %{
      path: join_path(config.documents_path, config.documents_name),
      folder_id: ids[:documents_folder_id]
    }
  end

  defp deleted_folder_id(:template), do: get_folder_ids()[:deleted_templates_folder_id]
  defp deleted_folder_id(:document), do: get_folder_ids()[:deleted_documents_folder_id]

  defp deleted_folder_path(:deleted_templates_folder_id) do
    config = GoogleDocsClient.get_folder_config()
    join_path(join_path(config.deleted_path, config.deleted_name), config.templates_name)
  end

  defp deleted_folder_path(:deleted_documents_folder_id) do
    config = GoogleDocsClient.get_folder_config()
    join_path(join_path(config.deleted_path, config.deleted_name), config.documents_name)
  end

  defp join_path("", name), do: name
  defp join_path(path, name), do: "#{path}/#{name}"

  # ===========================================================================
  # Folders
  # ===========================================================================

  @doc "Get the folder IDs (auto-discovers if not cached)."
  @spec get_folder_ids() :: map()
  def get_folder_ids do
    GoogleDocsClient.get_folder_ids()
  end

  @doc "Re-discover folder IDs from Drive."
  @spec refresh_folders() :: map()
  def refresh_folders do
    GoogleDocsClient.discover_folders()
  end

  @doc "Get the Google Drive URL for the templates folder."
  @spec templates_folder_url() :: String.t() | nil
  def templates_folder_url do
    case get_folder_ids() do
      %{templates_folder_id: id} when is_binary(id) -> GoogleDocsClient.get_folder_url(id)
      _ -> nil
    end
  end

  @doc "Get the Google Drive URL for the documents folder."
  @spec documents_folder_url() :: String.t() | nil
  def documents_folder_url do
    case get_folder_ids() do
      %{documents_folder_id: id} when is_binary(id) -> GoogleDocsClient.get_folder_url(id)
      _ -> nil
    end
  end
end
