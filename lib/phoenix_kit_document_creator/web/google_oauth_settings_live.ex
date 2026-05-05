defmodule PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLive do
  @moduledoc """
  Settings page for the Document Creator module.

  Google account connection is now managed centrally in
  Settings → Integrations. This page handles folder configuration only.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.IntegrationPicker

  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    # Disconnected mount renders a fast empty shell; the connected mount
    # triggers `:load_settings` which performs the actual DB / Settings
    # reads. Without this gate, the four-call burst (folder_config /
    # active_integration_uuid / list_connections / get_integration /
    # connected?) would run twice per page load.
    if connected?(socket) do
      send(self(), :load_settings)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Document Creator — Folders"),
       loaded: false,
       connected: false,
       connected_email: "",
       active_connection: nil,
       google_connections: [],
       # Folder config — populated by `:load_settings`
       templates_path: nil,
       templates_name: nil,
       documents_path: nil,
       documents_name: nil,
       deleted_path: nil,
       deleted_name: nil,
       # Folder browser modal
       browser_open: false,
       browser_field: nil,
       browser_path: [],
       browser_folders: [],
       browser_loading: false,
       saving: false,
       error: nil,
       success: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    fc = GoogleDocsClient.get_folder_config()
    active_uuid = GoogleDocsClient.active_integration_uuid()
    connected = !!(active_uuid && Integrations.connected?(active_uuid))
    google_connections = Integrations.list_connections("google")

    connection_info =
      case active_uuid && Integrations.get_integration(active_uuid) do
        {:ok, data} ->
          %{
            email:
              get_in(data, ["metadata", "connected_email"]) ||
                data["external_account_id"] || ""
          }

        _ ->
          %{email: ""}
      end

    assign(socket,
      loaded: true,
      connected: connected,
      connected_email: connection_info.email,
      active_connection: active_uuid,
      google_connections: google_connections,
      templates_path: fc.templates_path,
      templates_name: fc.templates_name,
      documents_path: fc.documents_path,
      documents_name: fc.documents_name,
      deleted_path: fc.deleted_path,
      deleted_name: fc.deleted_name
    )
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_connection", %{"uuid" => connection_key}, socket) do
    # Save the selected connection to document_creator settings
    dc_settings = Settings.get_json_setting("document_creator_settings", %{})
    updated = Map.put(dc_settings, "google_connection", connection_key)

    Settings.update_json_setting_with_module(
      "document_creator_settings",
      updated,
      "document_creator"
    )

    # Reload connection status
    connected = Integrations.connected?(connection_key)

    connection_info =
      case Integrations.get_integration(connection_key) do
        {:ok, data} ->
          %{
            email:
              get_in(data, ["metadata", "connected_email"]) ||
                data["external_account_id"] || ""
          }

        _ ->
          %{email: ""}
      end

    Documents.log_manual_action("settings.connection_changed", [
      {:actor_uuid, actor_uuid(socket)},
      {:metadata, %{"connection_key" => connection_key, "email" => connection_info.email}}
    ])

    {:noreply,
     assign(socket,
       active_connection: connection_key,
       connected: connected,
       connected_email: connection_info.email,
       success: gettext("Connection updated")
     )}
  end

  def handle_event("save_folders", params, socket) do
    folder_data = Settings.get_json_setting(GoogleDocsClient.folder_settings_key(), %{})

    new = %{
      "folder_path_templates" => String.trim(params["templates_path"] || ""),
      "folder_name_templates" => String.trim(params["templates_name"] || ""),
      "folder_path_documents" => String.trim(params["documents_path"] || ""),
      "folder_name_documents" => String.trim(params["documents_name"] || ""),
      "folder_path_deleted" => String.trim(params["deleted_path"] || ""),
      "folder_name_deleted" => String.trim(params["deleted_name"] || "")
    }

    old_keys = Map.take(folder_data, Map.keys(new))
    changed = old_keys != new

    updated = Map.merge(folder_data, new)

    # If anything changed, clear cached folder IDs so discovery uses the new config
    updated =
      if changed do
        Map.drop(updated, [
          "templates_folder_id",
          "documents_folder_id",
          "deleted_templates_folder_id",
          "deleted_documents_folder_id"
        ])
      else
        updated
      end

    Settings.update_json_setting_with_module(
      GoogleDocsClient.folder_settings_key(),
      updated,
      "document_creator"
    )

    if changed do
      Documents.log_manual_action("settings.folders_changed", [
        {:actor_uuid, actor_uuid(socket)},
        {:metadata, new}
      ])
    end

    {:noreply,
     assign(socket,
       templates_path: new["folder_path_templates"],
       templates_name: new["folder_name_templates"],
       documents_path: new["folder_path_documents"],
       documents_name: new["folder_name_documents"],
       deleted_path: new["folder_path_deleted"],
       deleted_name: new["folder_name_deleted"],
       success: gettext("Folder settings saved"),
       error: nil
     )}
  end

  @valid_path_fields ~w(templates_path documents_path deleted_path)

  def handle_event("browse_folder", %{"field" => field}, socket)
      when field in @valid_path_fields do
    send(self(), {:load_drive_folders, "root"})

    {:noreply,
     assign(socket,
       browser_open: true,
       browser_field: field,
       browser_path: [%{id: "root", name: gettext("My Drive")}],
       browser_folders: [],
       browser_loading: true
     )}
  end

  def handle_event("browse_folder", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("browser_navigate", %{"id" => folder_id, "name" => name}, socket) do
    send(self(), {:load_drive_folders, folder_id})
    path = socket.assigns.browser_path ++ [%{id: folder_id, name: name}]
    {:noreply, assign(socket, browser_path: path, browser_folders: [], browser_loading: true)}
  end

  def handle_event("browser_back", %{"index" => index}, socket) do
    index =
      case Integer.parse(index) do
        {n, _} -> n
        :error -> 0
      end

    path = Enum.take(socket.assigns.browser_path, max(index + 1, 1))

    case List.last(path) do
      %{id: folder_id} ->
        send(self(), {:load_drive_folders, folder_id})
        {:noreply, assign(socket, browser_path: path, browser_folders: [], browser_loading: true)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("browser_select", _params, socket) do
    path =
      socket.assigns.browser_path
      |> Enum.drop(1)
      |> Enum.map_join("/", & &1.name)

    field = socket.assigns.browser_field

    if field in @valid_path_fields do
      field_atom = String.to_existing_atom(field)
      {:noreply, assign(socket, [{field_atom, path}, browser_open: false])}
    else
      {:noreply, assign(socket, browser_open: false)}
    end
  end

  def handle_event("browser_close", _params, socket) do
    {:noreply, assign(socket, browser_open: false)}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, assign(socket, success: nil, error: nil)}
  end

  @impl true
  def handle_info(:load_settings, socket) do
    {:noreply, load_settings(socket)}
  end

  def handle_info({:load_drive_folders, folder_id}, socket) do
    pid = self()

    # `Task.start_link/1` (not `Task.start/1`) so the spawned task is
    # linked to the LV — closing the tab kills the in-flight Drive
    # fetch instead of leaving an orphan that has nowhere to send
    # :drive_folders_loaded. Pure render-only fetch; nothing writes
    # to the DB.
    Task.start_link(fn ->
      try do
        folders =
          case GoogleDocsClient.list_subfolders(folder_id) do
            {:ok, folders} -> folders
            _ -> []
          end

        send(pid, {:drive_folders_loaded, folders})
      rescue
        _ -> send(pid, {:drive_folders_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:drive_folders_loaded, folders}, socket) do
    {:noreply, assign(socket, browser_folders: folders, browser_loading: false)}
  end

  # Catch-all so unexpected messages (Task supervisor signals, stray
  # PubSub traffic, etc.) don't crash the LiveView. Logs at :debug so
  # stray messages are still observable when debugging without polluting
  # prod logs.
  def handle_info(msg, socket) do
    Logger.debug(
      "DocumentCreator.GoogleOAuthSettingsLive: ignoring unexpected message: #{inspect(msg)}"
    )

    {:noreply, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-6 gap-6">
      <div>
        <h1 class="text-2xl font-bold">{gettext("Document Creator Settings")}</h1>
        <p class="text-sm text-base-content/60 mt-1">
          {gettext("Configure Google Drive folders for templates and documents.")}
        </p>
      </div>

      <%!-- Flash messages --%>
      <div :if={@success} class="alert alert-success" phx-click="dismiss">
        <span class="hero-check-circle w-5 h-5" />
        <span>{@success}</span>
      </div>
      <div :if={@error} class="alert alert-error" phx-click="dismiss">
        <span class="hero-x-circle w-5 h-5" />
        <span>{@error}</span>
      </div>

      <%!-- Google Connection --%>
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Google Account")}</h2>

          <.integration_picker
            id="doc-creator-google-picker"
            connections={@google_connections}
            selected={if @active_connection, do: [@active_connection], else: []}
            provider="google"
            compact={true}
            on_select="select_connection"
            empty_url={Routes.path("/admin/settings/integrations/new")}
          />

          <p class="text-xs text-base-content/50 mt-2">
            {gettext("Manage your Google connections in")}
            <a href={Routes.path("/admin/settings/integrations")} class="link">{gettext("Settings → Integrations")}</a>.
          </p>
        </div>
      </div>

      <%!-- Folder Names --%>
      <div :if={@connected} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Drive Folders")}</h2>
          <p class="text-sm text-base-content/60">
            {gettext("Customize the Google Drive folder names used for storage. Folders are created automatically if they don't exist.")}
          </p>

          <form phx-submit="save_folders" class="space-y-4 mt-4">
            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("Templates")}</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-disable-with={gettext("Loading…")}
                  phx-value-field="templates_path"
                  title={if @templates_path == "", do: gettext("Browse Google Drive — root"), else: gettext("Browse Google Drive — %{path}", path: @templates_path)}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @templates_path == "", do: "/", else: "#{@templates_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="templates_name"
                  value={@templates_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder={gettext("templates")}
                />
                <input type="hidden" name="templates_path" value={@templates_path} />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("Documents")}</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-disable-with={gettext("Loading…")}
                  phx-value-field="documents_path"
                  title={if @documents_path == "", do: gettext("Browse Google Drive — root"), else: gettext("Browse Google Drive — %{path}", path: @documents_path)}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @documents_path == "", do: "/", else: "#{@documents_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="documents_name"
                  value={@documents_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder={gettext("documents")}
                />
                <input type="hidden" name="documents_path" value={@documents_path} />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("Deleted")}</span></label>
              <div class="flex items-center gap-0">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm font-mono text-sm border border-base-300 rounded-r-none px-2 h-12 max-w-[60%] overflow-hidden"
                  phx-click="browse_folder"
                  phx-disable-with={gettext("Loading…")}
                  phx-value-field="deleted_path"
                  title={if @deleted_path == "", do: gettext("Browse Google Drive — root"), else: gettext("Browse Google Drive — %{path}", path: @deleted_path)}
                >
                  <span class="hero-folder-open w-4 h-4 shrink-0" />
                  <span class="truncate">{if @deleted_path == "", do: "/", else: "#{@deleted_path}/"}</span>
                </button>
                <input
                  type="text"
                  name="deleted_name"
                  value={@deleted_name}
                  class="input input-bordered rounded-l-none flex-1 min-w-0 font-mono text-sm" style="min-width: 120px;"
                  placeholder={gettext("deleted")}
                />
                <input type="hidden" name="deleted_path" value={@deleted_path} />
              </div>
            </div>

            <p class="text-xs text-base-content/50">
              {gettext("Click the path button to browse your Google Drive. Deleted items go to subfolders inside the deleted folder. Folders are created automatically if they don't exist.")}
            </p>

            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save Folder Settings")}
            </button>
          </form>
        </div>
      </div>
    </div>

    <%!-- Folder browser modal --%>
    <div :if={@browser_open} class="modal modal-open">
      <div class="modal-box max-w-md">
        <h3 class="font-bold text-lg">{gettext("Select Folder")}</h3>

        <%!-- Breadcrumb --%>
        <div class="flex items-center gap-1 mt-3 text-sm flex-wrap">
          <button
            :for={{crumb, idx} <- Enum.with_index(@browser_path)}
            class={"link link-hover #{if idx == length(@browser_path) - 1, do: "font-semibold", else: "text-base-content/60"}"}
            phx-click="browser_back"
            phx-value-index={idx}
          >
            <span :if={idx > 0} class="text-base-content/30 mr-1">/</span>
            {crumb.name}
          </button>
        </div>

        <%!-- Folder list --%>
        <div class="mt-3 border border-base-300 rounded-lg overflow-hidden" style="min-height: 200px; max-height: 400px; overflow-y: auto;">
          <div :if={@browser_loading} class="flex justify-center py-8">
            <span class="loading loading-spinner loading-md" />
          </div>
          <div :if={not @browser_loading and @browser_folders == []} class="flex justify-center py-8 text-base-content/40 text-sm">
            {gettext("No subfolders")}
          </div>
          <ul :if={not @browser_loading and @browser_folders != []} class="menu menu-sm p-0">
            <li :for={folder <- @browser_folders}>
              <button
                class="flex items-center gap-2 rounded-none"
                phx-click="browser_navigate"
                phx-value-id={folder["id"]}
                phx-value-name={folder["name"]}
              >
                <span class="hero-folder w-4 h-4 text-base-content/50" />
                <span class="truncate">{folder["name"]}</span>
                <span class="hero-chevron-right w-3 h-3 ml-auto text-base-content/30" />
              </button>
            </li>
          </ul>
        </div>

        <%!-- Actions --%>
        <div class="modal-action">
          <button class="btn btn-ghost btn-sm" phx-click="browser_close">{gettext("Cancel")}</button>
          <button class="btn btn-primary btn-sm" phx-click="browser_select">
            {gettext("Select Current Folder")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="browser_close"></div>
    </div>
    """
  end

  defp actor_uuid(socket), do: Helpers.actor_uuid(socket)
end
