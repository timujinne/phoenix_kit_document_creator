defmodule PhoenixKitDocumentCreator.GoogleDocsClient do
  @moduledoc """
  Google Docs and Drive API client for the Document Creator module.

  This module provides **direct Google Drive and Docs API access** without
  touching the local database. Use it when you need raw Drive operations:
  creating files, listing folders, moving files, exporting PDFs, reading
  document content, and substituting template variables.

  For combined Drive + DB operations, use `PhoenixKitDocumentCreator.Documents`.

  ## Capabilities

  - **Folders**: `find_folder_by_name/2`, `create_folder/2`, `find_or_create_folder/2`,
    `ensure_folder_path/2`, `discover_folders/0`, `list_subfolders/1`
  - **Files**: `list_folder_files/1`, `move_file/2`, `copy_file/3`, `create_document/2`
  - **Docs**: `get_document/1`, `get_document_text/1`, `batch_update/2`, `replace_all_text/2`
  - **Export**: `export_pdf/1`, `fetch_thumbnail/1`
  - **Status**: `file_status/1`, `file_location/1`
  - **URLs**: `get_edit_url/1`, `get_folder_url/1`

  OAuth credentials and tokens are managed by `PhoenixKit.Integrations`
  under the `"google"` provider. The module references the active
  connection by uuid via the `"google_connection"` field in the
  `"document_creator_settings"` row — `active_integration_uuid/0` is
  the resolver. Pre-uuid values (`"google"` / `"google:name"` strings)
  are auto-migrated to the matching integration row's uuid on first
  read; the rewritten setting then drives all subsequent dispatches.
  Folder configuration is stored separately under the
  `"document_creator_folders"` settings key.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker

  @folder_settings_key "document_creator_folders"
  @settings_key "document_creator_settings"

  # Matches an RFC 4122-shaped UUID string (the storage row identifier
  # used by PhoenixKit.Integrations — currently UUIDv7, but this guard
  # only needs to discriminate "promoted to uuid" from legacy
  # `"google"` / `"google:name"` references; we don't enforce the
  # version digit). Anything that doesn't match here is legacy and
  # gets auto-migrated on first read.
  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @docs_base "https://docs.googleapis.com/v1"
  @drive_base "https://www.googleapis.com/drive/v3"

  # All access to `PhoenixKit.Integrations` flows through this resolver so
  # tests can route the three call sites (get_credentials/1,
  # get_integration/1, authenticated_request/4) through a stub module
  # without external HTTP traffic. Production reads the default
  # (`PhoenixKit.Integrations`) when the config is absent — net diff is
  # one line per call site.
  defp integrations_backend do
    Application.get_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      PhoenixKit.Integrations
    )
  end

  # ===========================================================================
  # Credentials (delegated to PhoenixKit.Integrations)
  # ===========================================================================

  @doc """
  Returns the uuid of the active Google integration, or `nil` if none
  has been chosen.

  The settings value at `document_creator_settings.google_connection` is
  expected to be a UUIDv7 (the integration row's storage uuid). Older
  installs may have a legacy `"google"` or `"google:name"` string here;
  this function detects that, resolves it to the matching integration's
  uuid, rewrites the setting, and returns the uuid. Subsequent calls
  read the migrated value directly.
  """
  @spec active_integration_uuid() :: String.t() | nil
  def active_integration_uuid do
    case Settings.get_json_setting(@settings_key, %{}) do
      %{"google_connection" => stored} when is_binary(stored) ->
        if uuid?(stored), do: stored, else: migrate_legacy_connection(stored)

      _ ->
        nil
    end
  end

  @doc false
  # Public-but-not-API: shared across the lazy on-read path and the
  # boot-time sweep in `PhoenixKitDocumentCreator.migrate_legacy/0` so
  # the @uuid_pattern regex only lives here.
  @spec uuid?(term()) :: boolean()
  def uuid?(str), do: is_binary(str) and Regex.match?(@uuid_pattern, str)

  # Legacy `"google"` / `"google:name"` values predate the move to uuid-
  # based references. Look up the integration row matching the exact
  # `provider:name` shape, rewrite the setting to its uuid, and return
  # the uuid. If no row matches, null the setting and return nil so
  # callers see a clean "not configured" state.
  #
  # **Symmetric with `PhoenixKitDocumentCreator.migrate_legacy_connection_references/0`**:
  # both paths require an exact `provider:name` match. The previous
  # "any connected row for this provider" fallback was removed
  # because it silently picked between multi-account installs (a user
  # with `google:work` AND `google:personal` who had `"google"` in
  # settings would have one of them chosen arbitrarily). Failing
  # cleanly forces the admin to re-select via the integration picker.
  defp migrate_legacy_connection(legacy_key) do
    {provider_key, name} =
      case String.split(legacy_key, ":", parts: 2) do
        [p, n] when n != "" -> {p, n}
        [p] -> {p, "default"}
      end

    case integrations_backend().get_integration("#{provider_key}:#{name}") do
      {:ok, %{"name" => _} = data} ->
        case find_uuid_for_data(provider_key, data) do
          nil ->
            log_legacy_resolution_failed(legacy_key, :uuid_not_found)
            rewrite_setting(nil)

          uuid ->
            log_legacy_resolution_succeeded(legacy_key, uuid)
            rewrite_setting(uuid)
        end

      _ ->
        log_legacy_resolution_failed(legacy_key, :no_exact_match)
        rewrite_setting(nil)
    end
  end

  defp log_legacy_resolution_succeeded(legacy_key, uuid) do
    Logger.info("[GoogleDocsClient] migrated legacy '#{legacy_key}' → uuid=#{inspect(uuid)}")

    log_lazy_migration_activity(:reference_migrated, %{
      "old_value" => legacy_key,
      "new_uuid" => uuid
    })
  end

  defp log_legacy_resolution_failed(legacy_key, reason) do
    Logger.warning(
      "[GoogleDocsClient] cannot resolve legacy '#{legacy_key}': " <>
        "reason=#{inspect(reason)}; clearing setting"
    )

    log_lazy_migration_activity(:reference_migration_failed, %{
      "old_value" => legacy_key,
      "reason" => inspect(reason)
    })
  end

  defp log_lazy_migration_activity(action_atom, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "integration.legacy_migrated",
        module: "document_creator",
        mode: "auto",
        resource_type: "integration",
        metadata:
          Map.merge(metadata, %{
            "migration_kind" => Atom.to_string(action_atom),
            "actor_role" => "system",
            "trigger" => "lazy_on_read"
          })
      })
    end

    :ok
  rescue
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] activity log failed during lazy legacy migration: " <>
          "kind=#{action_atom}, exception=#{inspect(e.__struct__)}"
      end)

      :ok
  end

  defp find_uuid_for_data(provider_key, data) do
    integrations_backend().list_connections(provider_key)
    |> Enum.find_value(fn %{uuid: uuid, name: name} ->
      if name == data["name"], do: uuid
    end)
  rescue
    # `find_uuid_for_data/2` runs from the lazy-read path
    # (`active_integration_uuid/0`), which fires on every request when
    # legacy data is still in `document_creator_settings`. A
    # transient backend failure (DB hiccup, integrations table
    # missing, sandbox owner exit) MUST NOT crash the request — the
    # downstream caller treats `nil` as "not found" and falls through
    # to the bare-provider list_connections scan or surfaces
    # `:not_configured` cleanly.
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] find_uuid_for_data/2 failed: " <>
          "exception=#{inspect(e.__struct__)}"
      end)

      nil
  end

  defp rewrite_setting(uuid) do
    dc_settings = Settings.get_json_setting(@settings_key, %{})

    updated =
      case uuid do
        nil -> Map.delete(dc_settings, "google_connection")
        _ -> Map.put(dc_settings, "google_connection", uuid)
      end

    Settings.update_json_setting_with_module(@settings_key, updated, "document_creator")
    uuid
  rescue
    # Same crash-vector concern as `find_uuid_for_data/2` — the
    # rewrite is the persistence half of the lazy-read promotion. If
    # Settings can't write (DB down, table missing, write-permission
    # error), a request that just wanted to read credentials gets a
    # 500 instead. Swallow the failure and return the resolved uuid
    # anyway — the in-memory request still works; the next request
    # will retry the rewrite. Returning the original uuid keeps the
    # lazy promotion idempotent across attempts.
    e ->
      Logger.warning(fn ->
        "[GoogleDocsClient] rewrite_setting/1 failed: " <>
          "exception=#{inspect(e.__struct__)}, " <>
          "uuid=#{inspect(uuid)}"
      end)

      uuid
  end

  @doc "Get stored OAuth credentials via PhoenixKit.Integrations."
  @spec get_credentials() :: {:ok, map()} | {:error, atom()}
  def get_credentials do
    case active_integration_uuid() do
      nil -> {:error, :not_configured}
      uuid -> integrations_backend().get_credentials(uuid)
    end
  end

  @doc "Check if connected. Returns `{:ok, %{email: email}}` or `{:error, reason}`."
  @spec connection_status() :: {:ok, %{email: String.t()}} | {:error, atom()}
  def connection_status do
    case active_integration_uuid() do
      nil ->
        {:error, :not_configured}

      uuid ->
        case integrations_backend().get_integration(uuid) do
          {:ok, data} ->
            email =
              get_in(data, ["metadata", "connected_email"]) ||
                data["external_account_id"] ||
                "Unknown"

            {:ok, %{email: email}}

          {:error, _} = err ->
            err
        end
    end
  end

  # ===========================================================================
  # Drive Folders
  # ===========================================================================

  @doc """
  Find a folder by name, optionally within a parent folder.
  Returns `{:ok, folder_id}` or `{:error, :not_found}`.
  """
  @spec find_folder_by_name(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :folder_search_failed | term()}
  def find_folder_by_name(name, opts \\ []) do
    parent = Keyword.get(opts, :parent, "root")

    q =
      "name = '#{escape_query_value(name)}' and mimeType = 'application/vnd.google-apps.folder' and '#{escape_query_value(parent)}' in parents and trashed = false"

    case authenticated_request(:get, "#{@drive_base}/files",
           params: [q: q, fields: "files(id,name)", pageSize: 1]
         ) do
      {:ok, %{status: 200, body: %{"files" => [%{"id" => id} | _]}}} ->
        {:ok, id}

      {:ok, %{status: 200}} ->
        {:error, :not_found}

      {:ok, %{body: body}} ->
        log_drive_error("folder search failed", body)
        {:error, :folder_search_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a folder in Google Drive. Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  @spec create_folder(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :create_folder_failed | term()}
  def create_folder(name, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    body = %{name: name, mimeType: "application/vnd.google-apps.folder"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 ->
        {:ok, id}

      {:ok, %{body: body}} ->
        log_drive_error("create folder failed", body)
        {:error, :create_folder_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Find a folder by name, or create it if it doesn't exist.
  Optionally specify a parent folder.
  Returns `{:ok, folder_id}`.
  """
  @spec find_or_create_folder(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def find_or_create_folder(name, opts \\ []) do
    case find_folder_by_name(name, opts) do
      {:ok, id} -> {:ok, id}
      {:error, :not_found} -> create_folder(name, opts)
      {:error, _} = err -> err
    end
  end

  @doc """
  Walk a path like "clients/active/templates", creating folders as needed.
  Returns `{:ok, leaf_folder_id}`.
  """
  @spec ensure_folder_path(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_folder_path(path, opts \\ []) do
    parent = Keyword.get(opts, :parent, "root")
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(segments, {:ok, parent}, fn segment, {:ok, current_parent} ->
      case find_or_create_folder(segment, parent: current_parent) do
        {:ok, id} -> {:cont, {:ok, id}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Get configured folder paths and names from Settings, with defaults."
  @spec get_folder_config() :: map()
  def get_folder_config do
    creds = Settings.get_json_setting(@folder_settings_key, %{})

    %{
      root_path: creds["folder_path_root"] || "",
      root_name: non_empty(creds["folder_name_root"], ""),
      templates_path: creds["folder_path_templates"] || "",
      templates_name: non_empty(creds["folder_name_templates"], "templates"),
      documents_path: creds["folder_path_documents"] || "",
      documents_name: non_empty(creds["folder_name_documents"], "documents"),
      deleted_path: creds["folder_path_deleted"] || "",
      deleted_name: non_empty(creds["folder_name_deleted"], "deleted")
    }
  end

  defp non_empty(val, _default) when is_binary(val) and val != "", do: val
  defp non_empty(_, default), do: default

  defp parse_cached_folder_ids(%{
         "templates_folder_id" => t,
         "documents_folder_id" => d,
         "deleted_templates_folder_id" => dt,
         "deleted_documents_folder_id" => dd
       })
       when is_binary(t) and t != "" and is_binary(d) and d != "" and is_binary(dt) and
              dt != "" and is_binary(dd) and dd != "" do
    {:ok,
     %{
       templates_folder_id: t,
       documents_folder_id: d,
       deleted_templates_folder_id: dt,
       deleted_documents_folder_id: dd
     }}
  end

  defp parse_cached_folder_ids(_), do: :miss

  defp build_full_path("", name), do: name
  defp build_full_path(path, name), do: "#{path}/#{name}"

  @doc "Compute the three Drive paths (templates, documents, deleted) given a folder config map."
  @spec resolved_folder_paths(map()) :: {String.t(), String.t(), String.t()}
  def resolved_folder_paths(config) do
    root_abs =
      if config.root_name != "" do
        build_full_path(config.root_path, config.root_name)
      else
        nil
      end

    prefix = fn path ->
      if root_abs, do: "#{root_abs}/#{path}", else: path
    end

    templates = prefix.(build_full_path(config.templates_path, config.templates_name))
    documents = prefix.(build_full_path(config.documents_path, config.documents_name))
    deleted = prefix.(build_full_path(config.deleted_path, config.deleted_name))

    {templates, documents, deleted}
  end

  @doc """
  Discover templates, documents, and deleted folder IDs.
  Looks for folders by name in Drive root, creating them if they don't exist.
  Caches results in Settings.
  """
  @spec discover_folders() :: %{
          templates_folder_id: String.t() | nil,
          documents_folder_id: String.t() | nil,
          deleted_templates_folder_id: String.t() | nil,
          deleted_documents_folder_id: String.t() | nil
        }
  def discover_folders do
    config = get_folder_config()

    {templates_path, documents_path, deleted_path} = resolved_folder_paths(config)

    # Resolve all four folder paths in parallel to minimize sequential API calls.
    #
    # `Task.Supervisor.async_stream_nolink/4` under `PhoenixKit.TaskSupervisor`
    # supersedes the previous `Task.async/1` shape. Two reasons:
    #
    # 1. **Caller-exit cleanup**: bare `Task.async/1` links the spawned task
    #    to the calling process. If the LV exits mid-await (admin closes
    #    the tab), `Task.await_many/2`'s timeout path is never reached
    #    and `Task.shutdown` doesn't run — orphans are blocked on the
    #    remote Drive call until the HTTP timeout fires. Under the
    #    supervisor with `:nolink`, the calling process exiting causes
    #    the supervisor to clean the children automatically.
    #
    # 2. **No more `catch :exit, _`**: `async_stream` reports per-task
    #    failure via `{:exit, reason}` tuples in the stream, so the
    #    timeout-vs-success branch is plain pattern matching.
    paths = [
      templates_path,
      documents_path,
      "#{deleted_path}/#{config.templates_name}",
      "#{deleted_path}/#{config.documents_name}"
    ]

    [templates_id, documents_id, deleted_templates_id, deleted_documents_id] =
      Task.Supervisor.async_stream_nolink(
        PhoenixKit.TaskSupervisor,
        paths,
        fn path -> ensure_folder_path(path) end,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: true,
        max_concurrency: 4
      )
      |> Enum.map(fn
        {:ok, {:ok, id}} ->
          id

        {:ok, {:error, reason}} ->
          Logger.warning("Folder discovery failed: #{inspect(reason)}")
          nil

        {:exit, reason} ->
          Logger.error("Document Creator folder discovery failed: #{inspect(reason)}")
          nil
      end)

    # Save to folder settings
    folder_data = Settings.get_json_setting(@folder_settings_key, %{})

    updated =
      Map.merge(folder_data, %{
        "templates_folder_id" => templates_id,
        "documents_folder_id" => documents_id,
        "deleted_templates_folder_id" => deleted_templates_id,
        "deleted_documents_folder_id" => deleted_documents_id
      })

    Settings.update_json_setting_with_module(@folder_settings_key, updated, "document_creator")

    %{
      templates_folder_id: templates_id,
      documents_folder_id: documents_id,
      deleted_templates_folder_id: deleted_templates_id,
      deleted_documents_folder_id: deleted_documents_id
    }
  end

  @doc "Get cached folder IDs from Settings, or discover them."
  @spec get_folder_ids() :: map()
  def get_folder_ids do
    case parse_cached_folder_ids(Settings.get_json_setting(@folder_settings_key, nil)) do
      {:ok, ids} -> ids
      :miss -> discover_folders()
    end
  end

  @doc "The Settings key used for folder configuration."
  @spec folder_settings_key() :: String.t()
  def folder_settings_key, do: @folder_settings_key

  @doc """
  Move the four known Drive folders (templates, documents, deleted_templates,
  deleted_documents) into `root_folder_id`. Only moves folders whose cached ID
  is present. Clears cached IDs on full success so they are re-discovered.

  Returns `{:ok, %{moved: [labels], skipped: [labels]}}` or
  `{:error, [{label, reason}]}` if any move fails.
  """
  @spec migrate_folders_to_root(String.t()) ::
          {:ok, %{moved: [String.t()], skipped: [String.t()]}}
          | {:error, [{String.t(), term()}]}
  def migrate_folders_to_root(root_folder_id) do
    folder_data = Settings.get_json_setting(@folder_settings_key, %{})

    candidates = [
      {"templates", folder_data["templates_folder_id"]},
      {"documents", folder_data["documents_folder_id"]},
      {"deleted_templates", folder_data["deleted_templates_folder_id"]},
      {"deleted_documents", folder_data["deleted_documents_folder_id"]}
    ]

    {to_move, skipped} =
      Enum.split_with(candidates, fn {_label, id} -> is_binary(id) and id != "" end)

    results =
      Enum.map(to_move, fn {label, folder_id} ->
        case move_file(folder_id, root_folder_id) do
          :ok -> {:ok, label}
          {:error, reason} -> {:error, {label, reason}}
        end
      end)

    failures = for {:error, f} <- results, do: f
    moved = for {:ok, label} <- results, do: label
    skipped_labels = for {label, _} <- skipped, do: label

    if failures == [] do
      cache_keys = ~w(
        templates_folder_id documents_folder_id
        deleted_templates_folder_id deleted_documents_folder_id
      )
      updated = Map.drop(folder_data, cache_keys)
      Settings.update_json_setting_with_module(@folder_settings_key, updated, "document_creator")
      {:ok, %{moved: moved, skipped: skipped_labels}}
    else
      Logger.error("Document Creator folder migration failed: #{inspect(failures)}")
      {:error, failures}
    end
  end

  @doc """
  List subfolders within a parent folder (non-recursive, fully paginated).
  Returns `{:ok, [%{"id" => ..., "name" => ...}]}`.
  """
  @spec list_subfolders(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_subfolders(parent_id \\ "root"), do: DriveWalker.list_folders(parent_id)

  @doc """
  List Google Docs directly in a Drive folder (non-recursive, fully paginated).

  Returns `{:ok, [%{"id" => ..., "name" => ..., "modifiedTime" => ..., "thumbnailLink" => ..., "parents" => [...]}]}`.

  For recursive traversal across subfolders, use
  `PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker.walk_tree/2`.
  """
  @spec list_folder_files(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_folder_files(folder_id), do: DriveWalker.list_files(folder_id)

  @doc "Get the Google Drive folder URL."
  @spec get_folder_url(term()) :: String.t() | nil
  def get_folder_url(folder_id) when is_binary(folder_id) and folder_id != "" do
    "https://drive.google.com/drive/folders/#{folder_id}"
  end

  def get_folder_url(_), do: nil

  @doc "Fetch Google Drive file metadata needed for sync classification."
  @spec file_status(term()) ::
          {:ok, %{trashed: boolean(), parents: [String.t()]}}
          | {:ok, :not_found}
          | {:error, :invalid_file_id | term()}
  def file_status(file_id) when is_binary(file_id) and file_id != "" do
    with {:ok, fid} <- validate_file_id(file_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}",
             params: [fields: "id,trashed,parents"]
           ) do
        {:ok, %{status: 200, body: %{"trashed" => trashed} = body}} when is_boolean(trashed) ->
          {:ok,
           %{
             trashed: trashed,
             parents: Map.get(body, "parents", [])
           }}

        {:ok, %{status: 404}} ->
          {:ok, :not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:unexpected_status, status, body}}

        {:error, _} = err ->
          err
      end
    end
  end

  def file_status(_), do: {:error, :invalid_file_id}

  @doc "Resolve the current parent folder and path for a Drive file."
  @spec file_location(term()) ::
          {:ok, %{folder_id: String.t(), path: String.t(), trashed: boolean()}}
          | {:error, :invalid_file_id | :not_found | term()}
  def file_location(file_id) when is_binary(file_id) and file_id != "" do
    case file_status(file_id) do
      {:ok, %{parents: parents} = meta} ->
        folder_id = parents |> List.first() || "root"

        with {:ok, path} <- resolve_folder_path(folder_id) do
          {:ok, %{folder_id: folder_id, path: path, trashed: meta.trashed}}
        end

      {:ok, :not_found} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  def file_location(_), do: {:error, :invalid_file_id}

  @max_folder_depth 20

  defp resolve_folder_path(folder_id), do: resolve_folder_path(folder_id, @max_folder_depth)

  defp resolve_folder_path("root", _depth), do: {:ok, ""}
  defp resolve_folder_path(_folder_id, 0), do: {:error, :max_depth_exceeded}

  defp resolve_folder_path(folder_id, depth) do
    case authenticated_request(:get, "#{@drive_base}/files/#{folder_id}",
           params: [fields: "id,name,parents"]
         ) do
      {:ok, %{status: 200, body: %{"name" => name} = body}} ->
        parent_id = body |> Map.get("parents", []) |> List.first() || "root"

        with {:ok, parent_path} <- resolve_folder_path(parent_id, depth - 1) do
          {:ok, build_full_path(parent_path, name)}
        end

      {:ok, %{status: 404}} ->
        {:error, :folder_not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, _} = err ->
        err
    end
  end

  # ===========================================================================
  # Google Docs API
  # ===========================================================================

  @doc "Create a new blank Google Doc in a specific folder."
  @spec create_document(String.t(), keyword()) ::
          {:ok, %{doc_id: String.t(), name: String.t(), url: String.t() | nil}}
          | {:error, :create_document_failed | term()}
  def create_document(title, opts \\ []) do
    parent = Keyword.get(opts, :parent)

    # Create via Drive API so we can set the parent folder
    body = %{name: title, mimeType: "application/vnd.google-apps.document"}
    body = if parent, do: Map.put(body, :parents, [parent]), else: body

    case authenticated_request(:post, "#{@drive_base}/files", json: body) do
      {:ok, %{status: status, body: %{"id" => doc_id} = file}} when status in 200..299 ->
        {:ok, %{doc_id: doc_id, name: file["name"], url: get_edit_url(doc_id)}}

      {:ok, %{body: body}} ->
        log_drive_error("create document failed", body)
        {:error, :create_document_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc "Read a Google Doc's full content."
  @spec get_document(String.t()) :: {:ok, map()} | {:error, term()}
  def get_document(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      authenticated_request(:get, "#{@docs_base}/documents/#{fid}")
    end
  end

  @doc "Send a batchUpdate request to a Google Doc."
  @spec batch_update(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def batch_update(doc_id, requests) when is_list(requests) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      authenticated_request(:post, "#{@docs_base}/documents/#{fid}:batchUpdate",
        json: %{requests: requests}
      )
    end
  end

  @doc """
  Replace all `{{variable}}` placeholders in a Google Doc.
  Keys are wrapped in `{{ }}` automatically.
  """
  @spec replace_all_text(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replace_all_text(doc_id, variables) when is_map(variables) do
    requests =
      Enum.map(variables, fn {key, value} ->
        %{
          replaceAllText: %{
            containsText: %{text: "{{#{key}}}", matchCase: true},
            replaceText: to_string(value)
          }
        }
      end)

    if requests == [], do: {:ok, %{}}, else: batch_update(doc_id, requests)
  end

  @doc "Extract plain text content from a Google Doc (for variable detection)."
  @spec get_document_text(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_document_text(doc_id) do
    case get_document(doc_id) do
      {:ok, %{body: body}} ->
        text =
          get_in(body, ["body", "content"])
          |> List.wrap()
          |> Enum.flat_map(fn el -> get_in(el, ["paragraph", "elements"]) || [] end)
          |> Enum.map_join(fn el -> get_in(el, ["textRun", "content"]) || "" end)

        {:ok, text}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Scans a `documents.get` response for image tag occurrences.

  Returns a flat list of `%{name, start_index, end_index}` covering every
  occurrence in body content, headers, footers, and table cells, restricted
  to the names supplied.

  **Offset note:** `Regex.scan(..., return: :index)` returns byte offsets;
  Google Docs `startIndex` counts UTF-16 code units. The implementation
  converts byte offsets to UTF-16 code-unit counts via
  `:unicode.characters_to_binary/3` so supplementary-plane codepoints
  (emoji, rare CJK) are counted as the two units a surrogate pair occupies.
  """
  @spec find_image_tag_ranges(map(), [String.t()]) ::
          [%{name: String.t(), start_index: integer(), end_index: integer()}]
  def find_image_tag_ranges(%{} = doc, names) when is_list(names) do
    names_set = MapSet.new(names)

    body_blocks = get_in(doc, ["body", "content"]) || []

    header_blocks =
      doc
      |> Map.get("headers", %{})
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, "content", []))

    footer_blocks =
      doc
      |> Map.get("footers", %{})
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, "content", []))

    (body_blocks ++ header_blocks ++ footer_blocks)
    |> Enum.flat_map(&walk_block/1)
    |> Enum.flat_map(&extract_tag_ranges(&1, names_set))
  end

  defp walk_block(%{"paragraph" => %{"elements" => elements}}), do: elements

  defp walk_block(%{"table" => %{"tableRows" => rows}}) do
    Enum.flat_map(rows, fn %{"tableCells" => cells} ->
      Enum.flat_map(cells, fn %{"content" => content} ->
        Enum.flat_map(content, &walk_block/1)
      end)
    end)
  end

  defp walk_block(_), do: []

  @image_tag_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

  defp extract_tag_ranges(
         %{"textRun" => %{"content" => content}, "startIndex" => base},
         names_set
       ) do
    Regex.scan(@image_tag_regex, content, return: :index)
    |> Enum.flat_map(&match_to_range(&1, content, base, names_set))
  end

  defp extract_tag_ranges(_, _), do: []

  defp match_to_range(
         [{full_byte_start, full_byte_len}, _keyword_pos, {name_byte_start, name_byte_len}],
         content,
         base,
         names_set
       ) do
    # `Regex.scan` with `return: :index` yields byte offsets. Google Docs
    # `startIndex` counts UTF-16 code units (one per BMP codepoint, two per
    # supplementary). Convert the prefix-and-match bytes to UTF-16 length
    # so supplementary-plane codepoints (emoji, rare CJK) contribute the
    # surrogate-pair pair of code units they occupy in the doc index.
    full_u16_start = content |> binary_part(0, full_byte_start) |> utf16_units()
    full_u16_len = content |> binary_part(full_byte_start, full_byte_len) |> utf16_units()
    name = binary_part(content, name_byte_start, name_byte_len)

    if MapSet.member?(names_set, name) do
      [
        %{
          name: name,
          start_index: base + full_u16_start,
          end_index: base + full_u16_start + full_u16_len
        }
      ]
    else
      []
    end
  end

  defp match_to_range(_, _, _, _), do: []

  # Number of UTF-16 code units the given UTF-8 binary occupies — i.e. the
  # `startIndex` arithmetic unit Google Docs uses. Supplementary-plane
  # codepoints (most emoji, rare CJK) contribute two units (a surrogate
  # pair); BMP codepoints contribute one.
  defp utf16_units(binary) do
    binary
    |> :unicode.characters_to_binary(:utf8, :utf16)
    |> byte_size()
    |> div(2)
  end

  # Google Docs `Unit` enum accepts only `PT` or `UNIT_UNSPECIFIED`; 1 px = 0.75 pt
  # (96 dpi web → 72 dpi PostScript). Earlier versions sent `unit: "EMU"`, which
  # Google rejects with `INVALID_ARGUMENT` (`google.apps.docs.v1.Unit`), so every
  # `insertInlineImage` batch failed.
  @px_to_pt 0.75

  @doc """
  Builds the list of `batchUpdate` request maps to substitute image tags.

  `fills` is a map keyed by variable name; each value carries `kind`,
  `default_width_px`, `separator` (atom or nil), and `media` — a list of
  `%{uri, width_px, height_px}`.

  Empty media list = the tag is still deleted (cleared).
  """
  @spec build_image_batch_requests([map()], map()) :: [map()]
  def build_image_batch_requests(ranges, fills) do
    ranges
    |> Enum.sort_by(& &1.start_index, :desc)
    |> Enum.flat_map(fn %{name: name, start_index: s, end_index: e} ->
      fill = Map.fetch!(fills, name)
      delete = %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}}

      inserts =
        case fill.kind do
          :image -> single_image_inserts(fill, s)
          :image_list -> list_image_inserts(fill, s)
        end

      [delete | inserts]
    end)
  end

  @doc """
  Builds a single image insert request map.

  Options:
    - `:insertion_index` — document character index for insertion (required)
    - `:config` — map with `:default_width_px`, `:opacity`, `:z_index` (required)

  When `z_index > 0`, emits a `createPositionedObject` with `layout = "WRAP_TEXT"`.
  When `z_index <= 0`, emits `insertInlineImage` (default inline behaviour).
  Opacity application requires a follow-up `UpdateEmbeddedObjectPropertiesRequest`
  with the object ID returned by the batchUpdate response — not emitted here.
  A Logger warning is written when `opacity != 1.0`. This is a documented
  no-op (open risk) per the spec's "Open Risks" section: applying transparency
  requires a second batchUpdate pass after the initial insert, using the
  embedded object ID from the first response. Not yet implemented.
  """
  @spec build_single_image_request(String.t(), keyword()) :: map()
  def build_single_image_request(uri, opts) do
    index = Keyword.fetch!(opts, :insertion_index)
    config = Keyword.fetch!(opts, :config)
    w = Map.get(config, :default_width_px, 400)
    media = %{uri: uri, width_px: nil, height_px: nil}
    image_request(media, w, index, config, uri)
  end

  defp single_image_inserts(%{media: []}, _index), do: []

  defp single_image_inserts(fill, index) do
    %{media: [media | _], default_width_px: w} = fill
    [image_request(media, w, index, fill, media[:uri])]
  end

  defp list_image_inserts(%{media: []}, _index), do: []

  defp list_image_inserts(fill, index) do
    %{media: media, default_width_px: w, separator: sep} = fill
    reversed = Enum.reverse(media)
    last_idx = length(reversed) - 1

    reversed
    |> Enum.with_index()
    |> Enum.flat_map(fn {m, i} ->
      img = image_request(m, w, index, fill, m[:uri])
      if i < last_idx, do: [img, separator_request(sep, index)], else: [img]
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Build the single batchUpdate request for an image. The Google Docs API
  # exposes only `insertInlineImage` for programmatic image insertion —
  # `createPositionedObject` is not a valid `batchUpdate` request type
  # (positioned objects can only be created interactively in the editor).
  # `opacity` is also unsupported by the API on any image surface. Both
  # options are accepted in `config` for forward-compat and ignored with a
  # warning when set away from the defaults.
  defp image_request(media, width, index, config, log_ctx) do
    z = Map.get(config, :z_index, 0)
    opacity = Map.get(config, :opacity, 1.0)

    if z > 0 do
      Logger.warning(
        "image z_index #{z} is not supported by the Google Docs API " <>
          "(positioned objects can only be created in the editor UI); " <>
          "falling back to inline insert for #{inspect(log_ctx)}"
      )
    end

    if opacity != 1.0 do
      Logger.warning(
        "image opacity #{opacity} is not supported by the Google Docs API; " <>
          "skipped for #{inspect(log_ctx)}"
      )
    end

    insert_inline_image_request(media, width, index)
  end

  defp insert_inline_image_request(
         %{uri: uri, width_px: w_px, height_px: h_px},
         default_width_px,
         index
       ) do
    scaled_height_px = scale_height(default_width_px, w_px, h_px)

    %{
      insertInlineImage: %{
        location: %{index: index},
        uri: uri,
        objectSize: %{
          width: %{magnitude: default_width_px * @px_to_pt, unit: "PT"},
          height: %{magnitude: scaled_height_px * @px_to_pt, unit: "PT"}
        }
      }
    }
  end

  defp scale_height(target_width, src_width, src_height) when src_width in [nil, 0],
    do: src_height || target_width

  defp scale_height(target_width, src_width, src_height) do
    round(target_width * src_height / src_width)
  end

  defp separator_request(:none, _index), do: nil

  defp separator_request(sep, index) do
    text =
      case sep do
        :newline -> "\n"
        :space -> " "
      end

    %{insertText: %{text: text, location: %{index: index}}}
  end

  @doc """
  Two-step image substitution: GET the document, build the batch, send it.

  `fills` is the same shape as `build_image_batch_requests/2`.

  Options (used in tests):
    * `:get_fn` — overrides `get_document/1`
    * `:batch_fn` — overrides `batch_update/2`
  """
  @spec substitute_images(String.t(), map(), keyword()) ::
          {:ok, map() | :noop} | {:error, term()}
  def substitute_images(doc_id, fills, opts \\ []) when is_map(fills) do
    if map_size(fills) == 0 do
      {:ok, :noop}
    else
      get_fn = Keyword.get(opts, :get_fn, &get_document/1)
      batch_fn = Keyword.get(opts, :batch_fn, &batch_update/2)

      with {:ok, %{body: doc}} <- get_fn.(doc_id),
           ranges = find_image_tag_ranges(doc, Map.keys(fills)),
           requests = build_image_batch_requests(ranges, fills),
           {:ok, _} = result <- maybe_batch(batch_fn, doc_id, requests) do
        result
      else
        {:error, _} = err -> err
      end
    end
  end

  defp maybe_batch(_fn, _id, []), do: {:ok, %{}}
  defp maybe_batch(fn_, id, requests), do: fn_.(id, requests)

  # ===========================================================================
  # Google Drive API
  # ===========================================================================

  @doc "Move a file to a different folder in Google Drive."
  @spec move_file(String.t(), String.t()) ::
          :ok | {:error, :invalid_file_id | :move_failed | :get_file_parents_failed | term()}
  def move_file(file_id, to_folder_id) do
    with {:ok, fid} <- validate_file_id(file_id),
         {:ok, _tid} <- validate_file_id(to_folder_id) do
      do_move_file(fid, to_folder_id)
    end
  end

  defp do_move_file(file_id, to_folder_id) do
    case authenticated_request(:get, "#{@drive_base}/files/#{file_id}",
           params: [fields: "parents"]
         ) do
      {:ok, %{status: 200, body: %{"parents" => current_parents}}} ->
        remove = Enum.join(current_parents, ",")

        case authenticated_request(:patch, "#{@drive_base}/files/#{file_id}",
               params: [addParents: to_folder_id, removeParents: remove],
               json: %{}
             ) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{body: body}} ->
            log_drive_error("move failed", body)
            {:error, :move_failed}

          {:error, _} = err ->
            err
        end

      {:ok, %{body: body}} ->
        log_drive_error("get file parents failed", body)
        {:error, :get_file_parents_failed}

      {:error, _} = err ->
        err
    end
  end

  @doc "Copy a file in Google Drive. Returns the new file's ID."
  @spec copy_file(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_file_id | :copy_failed | term()}
  def copy_file(file_id, new_name, opts \\ []) do
    with {:ok, fid} <- validate_file_id(file_id) do
      parent = Keyword.get(opts, :parent)
      body = %{name: new_name}
      body = if parent, do: Map.put(body, :parents, [parent]), else: body

      case authenticated_request(:post, "#{@drive_base}/files/#{fid}/copy", json: body) do
        {:ok, %{status: status, body: %{"id" => new_id}}} when status in 200..299 ->
          {:ok, new_id}

        {:ok, %{body: body}} ->
          log_drive_error("copy failed", body)
          {:error, :copy_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Export a Google Doc as PDF. Returns `{:ok, pdf_binary}`."
  @spec export_pdf(String.t()) ::
          {:ok, binary()} | {:error, :invalid_file_id | :pdf_export_failed | term()}
  def export_pdf(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}/export",
             params: [mimeType: "application/pdf"]
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %{body: body}} ->
          log_drive_error("PDF export failed", body)
          {:error, :pdf_export_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Fetch a document thumbnail as a base64 data URI via the Drive API."
  @spec fetch_thumbnail(term()) ::
          {:ok, String.t()}
          | {:error,
             :no_doc_id
             | :no_thumbnail
             | :thumbnail_link_failed
             | :thumbnail_fetch_failed
             | :invalid_file_id
             | term()}
  def fetch_thumbnail(doc_id) when is_binary(doc_id) and doc_id != "" do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:get, "#{@drive_base}/files/#{fid}",
             params: [fields: "thumbnailLink"]
           ) do
        {:ok, %{status: 200, body: %{"thumbnailLink" => link}}} when is_binary(link) ->
          fetch_thumbnail_image(link)

        {:ok, %{status: 200}} ->
          {:error, :no_thumbnail}

        {:ok, %{body: body}} ->
          log_drive_error("get thumbnail link failed", body)
          {:error, :thumbnail_link_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  def fetch_thumbnail(_), do: {:error, :no_doc_id}

  # SSRF guard. The `thumbnailLink` URL comes from the Drive API response,
  # but a compromised network path or a misconfigured proxy could
  # substitute it with a URL pointing at internal infrastructure
  # (cloud-metadata endpoints at 169.254.169.254, internal admin panels
  # at 10/172/192.x, localhost). Reject anything that isn't on Google's
  # public thumbnail CDN before we pass the URL to `Req.get/1`.
  @thumbnail_host_suffixes [".googleusercontent.com", ".google.com"]

  @doc false
  # Public-but-not-API: exposed so tests can pin the SSRF guard
  # (allowlist + redirect block) without driving a full Drive auth
  # flow. Same shape as `validate_thumbnail_url/1` above.
  @spec fetch_thumbnail_image(String.t()) ::
          {:ok, String.t()} | {:error, :thumbnail_fetch_failed}
  def fetch_thumbnail_image(url) when is_binary(url) do
    case validate_thumbnail_url(url) do
      :ok ->
        do_fetch_thumbnail_image(url)

      {:error, reason} ->
        Logger.warning(
          "[DocumentCreator] thumbnail URL rejected | reason=#{reason} | url=#{inspect(url)}"
        )

        {:error, :thumbnail_fetch_failed}
    end
  end

  @doc false
  # Public-but-not-API: exposed so tests can pin the SSRF guard
  # without driving a full HTTP fetch. The accepted suffixes are an
  # allowlist of Google's public thumbnail CDNs.
  @spec validate_thumbnail_url(String.t()) :: :ok | {:error, :invalid_url | :host_not_allowed}
  def validate_thumbnail_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if Enum.any?(@thumbnail_host_suffixes, &String.ends_with?(host, &1)),
          do: :ok,
          else: {:error, :host_not_allowed}

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_thumbnail_url(_), do: {:error, :invalid_url}

  defp do_fetch_thumbnail_image(url) do
    # `:req_options` is empty in production. Tests opt in via
    # `Application.put_env(:phoenix_kit_document_creator, :req_options,
    # plug: {Req.Test, Stub})` to route through `Req.Test` stubs without
    # external HTTP traffic — same pattern as the AI module's coverage
    # push (e4519a8 + 5bbf273).
    #
    # `redirect: false` is prepended so it wins via Keyword.get/2's
    # first-match semantics — `:req_options` cannot disable it. Req
    # follows redirects by default (~> 0.5), and
    # `validate_thumbnail_url/1` only checks the input URL. Without
    # this, a 302 from a Google CDN host to 169.254.169.254 would be
    # followed silently and bypass the SSRF allowlist. The thumbnail
    # endpoint never legitimately redirects, so closing it off is safe.
    opts =
      [redirect: false] ++ Application.get_env(:phoenix_kit_document_creator, :req_options, [])

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = extract_content_type(headers)

        {:ok, "data:#{content_type};base64,#{Base.encode64(body)}"}

      {:ok, %{status: status}} ->
        Logger.warning("[DocumentCreator] thumbnail fetch returned non-200 | status=#{status}")
        {:error, :thumbnail_fetch_failed}

      {:error, exception} ->
        Logger.warning(
          "[DocumentCreator] thumbnail fetch failed | message=#{Exception.message(exception)}"
        )

        {:error, :thumbnail_fetch_failed}
    end
  end

  # ===========================================================================
  # Composition helpers (used by Documents.Composer)
  # ===========================================================================

  @doc """
  Copy a Google Doc for use as the base of a composed document.

  Returns `{:ok, new_doc_id}`. The copy is named by its source doc ID so it
  can be identified for best-effort cleanup on rollback before a final name
  is applied.
  """
  @spec copy_document(String.t()) :: {:ok, String.t()} | {:error, term()}
  def copy_document(source_doc_id) do
    copy_file(source_doc_id, "composed-doc-#{source_doc_id}")
  end

  @doc """
  Append a template's content to an existing Google Doc via batchUpdate.

  Inserts a page break followed by the full text content of `template_doc_id`
  into `target_doc_id`. Returns `{:ok, {start_index, end_index}}` representing
  the character range of the inserted content — callers use this for
  section-scoped substitution.
  """
  @spec append_template(String.t(), String.t()) ::
          {:ok, {integer(), integer()}} | {:error, term()}
  def append_template(target_doc_id, template_doc_id) do
    with {:ok, text} <- get_document_text(template_doc_id),
         {:ok, %{body: current_doc}} <- get_document(target_doc_id) do
      end_index = document_end_index(current_doc)
      insert_index = max(end_index - 1, 1)

      requests = [
        %{insertPageBreak: %{location: %{index: insert_index}}},
        %{
          insertText: %{
            location: %{index: insert_index + 1},
            text: text
          }
        }
      ]

      case batch_update(target_doc_id, requests) do
        {:ok, _} ->
          content_start = insert_index + 1
          # Use UTF-16 unit count — Google Docs indices count UTF-16 code units,
          # not graphemes. For BMP-only text these are equal; emoji and rare CJK
          # codepoints occupy two UTF-16 units (a surrogate pair).
          content_end = content_start + utf16_units(text)
          {:ok, {content_start, content_end}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Return the range `{1, end_index}` of the current content in a Google Doc.

  Used by the Composer to pin section 0's range before any sections are appended.
  The range starts at index 1 because Google Docs body content always begins at 1.
  """
  @spec document_content_range(String.t()) :: {:ok, {1, integer()}} | {:error, term()}
  def document_content_range(doc_id) do
    with {:ok, %{body: doc}} <- get_document(doc_id) do
      {:ok, {1, document_end_index(doc)}}
    end
  end

  @doc """
  Substitute all sections' variables and image params into a Google Doc in a
  single atomic pass per phase (text then image).

  `sections` is a list of `%{position, variable_values, image_params}` maps.
  `ranges` maps each section position to its `{start_index, end_index}` in the
  document. All positions must have a range entry — section 0's range must be
  provided explicitly (use `document_content_range/1` after copy, before append).

  Each `{{key}}` placeholder in the document is matched against the section whose
  range contains it; that section's `variable_values[key]` supplies the replacement.
  Placeholders outside all section ranges are left untouched.

  Text substitution runs before image substitution (per image-substitution.md) and
  the document is re-fetched between the two phases so image indices are accurate
  after text edits. All operations within a phase are batched in a single
  batchUpdate in reverse-index order so no substitution shifts the indices of
  another.
  """
  @spec substitute_all_sections(String.t(), [map()], %{
          non_neg_integer() => {integer(), integer()}
        }) ::
          :ok | {:error, term()}
  def substitute_all_sections(doc_id, sections, ranges) do
    # Phase 1: text substitution — one fetch, one batchUpdate in reverse-index order.
    with {:ok, %{body: doc}} <- get_document(doc_id),
         {:ok, _} <- substitute_all_text(doc_id, doc, sections, ranges),
         # Phase 2: image substitution — re-fetch so indices are current after text edits.
         {:ok, %{body: doc2}} <- get_document(doc_id) do
      substitute_all_images(doc_id, doc2, sections, ranges)
    end
  end

  defp substitute_all_text(doc_id, doc, sections, ranges) do
    all_keys = sections |> Enum.flat_map(&Map.keys(&1.variable_values)) |> Enum.uniq()

    requests =
      doc
      |> body_text_runs()
      |> Enum.flat_map(&find_text_var_ranges(&1, all_keys))
      |> Enum.flat_map(fn %{key: key, start_index: s, end_index: e} = match ->
        case section_for_match(sections, ranges, match) do
          nil -> []
          section -> [{key, s, e, to_string(section.variable_values[key])}]
        end
      end)
      |> Enum.sort_by(fn {_, s, _, _} -> s end, :desc)
      |> Enum.flat_map(fn {_, s, e, value} ->
        [
          %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}},
          %{insertText: %{location: %{index: s}, text: value}}
        ]
      end)

    maybe_batch(&batch_update/2, doc_id, requests)
  end

  defp substitute_all_images(doc_id, doc2, sections, ranges) do
    all_image_fills =
      sections
      |> Enum.flat_map(fn s ->
        fills = build_image_fills(s.image_params)
        range = Map.get(ranges, s.position)
        Enum.map(fills, fn {name, fill} -> {name, fill, range} end)
      end)

    if all_image_fills == [] do
      :ok
    else
      # Build a flat fills map for find_image_tag_ranges, then filter each result
      # to its section's range before building the batch.
      fills_map = Map.new(all_image_fills, fn {name, fill, _} -> {name, fill} end)
      range_by_name = Map.new(all_image_fills, fn {name, _, range} -> {name, range} end)

      requests =
        doc2
        |> find_image_tag_ranges(Map.keys(fills_map))
        |> Enum.filter(fn %{name: name, start_index: s} ->
          in_section_range?(range_by_name, name, s)
        end)
        |> build_image_batch_requests(fills_map)

      case maybe_batch(&batch_update/2, doc_id, requests) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp in_section_range?(range_by_name, name, s) do
    case Map.get(range_by_name, name) do
      nil -> false
      {rs, re} -> s >= rs and s < re
    end
  end

  # Find which section owns a given text match by checking if the match's
  # start_index falls within that section's range.
  defp section_for_match(sections, ranges, %{key: key, start_index: s}) do
    Enum.find(sections, fn section ->
      case Map.get(ranges, section.position) do
        {range_start, range_end} ->
          s >= range_start and s < range_end and Map.has_key?(section.variable_values, key)

        _ ->
          false
      end
    end)
  end

  # Walk body content and return all textRun elements as %{content, startIndex}.
  defp body_text_runs(doc) do
    (get_in(doc, ["body", "content"]) || [])
    |> Enum.flat_map(&walk_block/1)
    |> Enum.filter(&match?(%{"textRun" => _, "startIndex" => _}, &1))
  end

  @text_var_regex ~r/\{\{\s*(\w+)\s*\}\}/

  # Find {{key}} occurrences in a textRun element for the given key names.
  # Returns %{key, start_index, end_index} with UTF-16 index arithmetic.
  defp find_text_var_ranges(%{"textRun" => %{"content" => content}, "startIndex" => base}, keys) do
    keys_set = MapSet.new(keys)

    Regex.scan(@text_var_regex, content, return: :index)
    |> Enum.flat_map(fn [{full_byte_start, full_byte_len}, {name_byte_start, name_byte_len}] ->
      name = binary_part(content, name_byte_start, name_byte_len)

      if MapSet.member?(keys_set, name) do
        u16_start = content |> binary_part(0, full_byte_start) |> utf16_units()
        u16_len = content |> binary_part(full_byte_start, full_byte_len) |> utf16_units()

        [%{key: name, start_index: base + u16_start, end_index: base + u16_start + u16_len}]
      else
        []
      end
    end)
  end

  defp find_text_var_ranges(_, _), do: []

  @doc """
  Delete (trash) a Google Doc. Used for best-effort cleanup after a failed composition.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete_document(String.t()) :: :ok | {:error, term()}
  def delete_document(doc_id) do
    with {:ok, fid} <- validate_file_id(doc_id) do
      case authenticated_request(:delete, "#{@drive_base}/files/#{fid}") do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{body: body}} ->
          log_drive_error("delete failed", body)
          {:error, :delete_failed}

        {:error, _} = err ->
          err
      end
    end
  end

  defp document_end_index(doc) do
    content = get_in(doc, ["body", "content"]) || []

    content
    |> Enum.flat_map(fn el ->
      case el do
        %{"paragraph" => %{"elements" => elements}} ->
          Enum.map(elements, &Map.get(&1, "endIndex", 0))

        _ ->
          [Map.get(el, "endIndex", 0)]
      end
    end)
    |> Enum.max(fn -> 1 end)
  end

  defp build_image_fills(image_params) when map_size(image_params) == 0, do: %{}

  defp build_image_fills(image_params) do
    Map.new(image_params, fn {name, params} ->
      kind = if Map.get(params, "kind") == "image_list", do: :image_list, else: :image
      media_items = build_media_items(params)

      fill = %{
        kind: kind,
        default_width_px: Map.get(params, "width_px", 400),
        opacity: Map.get(params, "opacity", 1.0),
        z_index: Map.get(params, "z_index", 0),
        separator: normalize_separator_atom(Map.get(params, "separator", "newline")),
        media: media_items
      }

      {name, fill}
    end)
  end

  defp build_media_items(%{"media" => media}) when is_list(media) do
    Enum.map(media, fn m ->
      %{uri: Map.get(m, "uri", ""), width_px: Map.get(m, "width_px"), height_px: nil}
    end)
  end

  defp build_media_items(_), do: []

  defp normalize_separator_atom("newline"), do: :newline
  defp normalize_separator_atom("space"), do: :space
  defp normalize_separator_atom(:newline), do: :newline
  defp normalize_separator_atom(:space), do: :space
  defp normalize_separator_atom(_), do: :none

  @doc "Get the edit URL for a Google Doc."
  @spec get_edit_url(term()) :: String.t() | nil
  def get_edit_url(doc_id) when is_binary(doc_id) and doc_id != "" do
    "https://docs.google.com/document/d/#{doc_id}/edit"
  end

  def get_edit_url(_), do: nil

  # ===========================================================================
  # Internal: Authenticated HTTP requests via PhoenixKit.Integrations
  # ===========================================================================

  @doc false
  # Public so `GoogleDocsClient.DriveWalker` can reuse the same auth +
  # auto-refresh path without duplicating credential plumbing. Not part of
  # the public API — may change without notice.
  @spec authenticated_request(atom(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def authenticated_request(method, url, opts \\ []) do
    case active_integration_uuid() do
      nil ->
        {:error, :not_configured}

      uuid ->
        integrations_backend().authenticated_request(uuid, method, url, opts)
    end
  end

  defp escape_query_value(value) do
    value |> to_string() |> String.replace("'", "\\'")
  end

  # Google Drive IDs are alphanumeric with hyphens and underscores.
  # Reject anything else to prevent URL path injection.
  @valid_file_id_pattern ~r/\A[\w-]+\z/

  @doc "Validate a Google Drive file/folder ID. Returns `{:ok, id}` or `{:error, :invalid_file_id}`."
  @spec validate_file_id(term()) :: {:ok, String.t()} | {:error, :invalid_file_id}
  def validate_file_id(id) when is_binary(id) and id != "" do
    if Regex.match?(@valid_file_id_pattern, id), do: {:ok, id}, else: {:error, :invalid_file_id}
  end

  def validate_file_id(_), do: {:error, :invalid_file_id}

  # Extract content-type from Req response headers.
  # Req >= 0.5 returns headers as %{"content-type" => ["image/png"]}.
  @allowed_thumbnail_types ~w(image/png image/jpeg image/webp image/gif)

  defp extract_content_type(%{"content-type" => [v | _]}) do
    type =
      case String.split(v, ";") do
        [type | _] -> String.trim(type)
        _ -> "image/png"
      end

    if type in @allowed_thumbnail_types do
      type
    else
      Logger.debug(
        "[DocumentCreator] thumbnail content-type downgraded | original=#{inspect(v)} → image/png"
      )

      "image/png"
    end
  end

  defp extract_content_type(_), do: "image/png"

  # Truncated logger for Drive API failure responses. The Drive/Docs API
  # error body can include the full request URL, the file ID, and a
  # multi-line error message — useful for debugging but a security and
  # log-bloat concern when shipped at scale. Truncate to a fixed length
  # so the call site is observable without leaking gigabytes when an
  # endpoint returns a giant payload.
  @drive_log_body_limit 500

  defp log_drive_error(label, body) do
    Logger.warning(
      "[DocumentCreator] #{label} | body=#{truncate_inspect(body, @drive_log_body_limit)}"
    )
  end

  defp truncate_inspect(value, limit) do
    inspected = inspect(value, limit: :infinity, printable_limit: limit)

    if String.length(inspected) > limit do
      String.slice(inspected, 0, limit) <> "…(truncated)"
    else
      inspected
    end
  end
end
