defmodule PhoenixKitDocumentCreator.Web.DocumentsLive do
  @moduledoc """
  Main listing page for the Document Creator.

  Lists templates and documents from the local database for fast rendering.
  Background sync keeps the DB in sync with Google Drive. Files that
  disappear from Drive are shown with a "lost" indicator.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Web.Helpers

  @pubsub_topic PhoenixKitDocumentCreator.Documents.pubsub_topic()
  @refresh_cooldown_ms :timer.seconds(5)
  @max_pdf_push_bytes 5_000_000

  @impl true
  def mount(_params, _session, socket) do
    # Disconnected mount returns an empty shell — no DB / Settings /
    # Integrations calls. The connected mount subscribes to PubSub
    # (BEFORE the DB read, so a `:files_changed` broadcast arriving
    # between the read and the subscribe doesn't get dropped on the
    # floor) then triggers `:load_initial` to do the file-list reads
    # and the initial Drive sync. Without this gate, `mount/3` runs
    # twice per page load and every DB read in it ran twice too.
    if connected?(socket) do
      PhoenixKit.PubSubHelper.subscribe(@pubsub_topic)
      send(self(), :load_initial)
    end

    {:ok,
     assign(socket,
       page_title: gettext("Document Creator"),
       view_mode: "cards",
       loaded: false,
       google_connected: false,
       templates: [],
       documents: [],
       trashed_templates: [],
       trashed_documents: [],
       known_file_ids: MapSet.new(),
       status_mode: "active",
       pending_files: MapSet.new(),
       thumbnails: %{},
       enabled_languages: [],
       loading: true,
       last_loaded_at: nil,
       error: nil,
       # Modal state
       modal_open: false,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_creating: false,
       unfiled_modal_open: false,
       unfiled_file: nil,
       unfiled_working: false
     )}
  end

  defp google_connected? do
    case GoogleDocsClient.connection_status() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp load_initial_state(google_connected) do
    {templates, documents, trashed_templates, trashed_documents} =
      if google_connected do
        {Documents.list_templates_from_db(), Documents.list_documents_from_db(),
         Documents.list_trashed_templates_from_db(), Documents.list_trashed_documents_from_db()}
      else
        {[], [], [], []}
      end

    all_ids =
      Enum.map(templates ++ documents ++ trashed_templates ++ trashed_documents, & &1["id"])

    cached_thumbnails =
      if all_ids != [], do: Documents.load_cached_thumbnails(all_ids), else: %{}

    %{
      templates: templates,
      documents: documents,
      trashed_templates: trashed_templates,
      trashed_documents: trashed_documents,
      cached_thumbnails: cached_thumbnails,
      db_empty: templates == [] and documents == []
    }
  end

  # ── Sync from Drive ──────────────────────────────────────────────

  @impl true
  def handle_info(:load_initial, socket) do
    google_connected = google_connected?()
    initial = load_initial_state(google_connected)

    if google_connected do
      send(self(), :sync_from_drive)
      :timer.send_interval(:timer.minutes(2), self(), :poll_for_changes)
    end

    {:noreply,
     assign(socket,
       loaded: true,
       google_connected: google_connected,
       templates: initial.templates,
       documents: initial.documents,
       trashed_templates: initial.trashed_templates,
       trashed_documents: initial.trashed_documents,
       known_file_ids:
         build_known_file_ids(
           initial.templates,
           initial.documents,
           initial.trashed_templates,
           initial.trashed_documents
         ),
       thumbnails: initial.cached_thumbnails,
       enabled_languages: Documents.list_enabled_languages(),
       loading: google_connected and initial.db_empty
     )}
  end

  def handle_info(:sync_from_drive, socket) do
    pid = self()

    # `Task.start_link/1` (not `Task.start/1`) so the spawned task is
    # linked to the LV process — it dies cleanly when the admin closes
    # the tab. Without this, an unsupervised orphan keeps running with
    # nowhere to send :sync_complete. The sync_from_drive write path is
    # idempotent, so dying mid-sync is safe; next sync restarts.
    Task.start_link(fn ->
      try do
        Documents.sync_from_drive()
        send(pid, :sync_complete)
      rescue
        e ->
          Logger.error("Document Creator sync failed: #{Exception.message(e)}")
          send(pid, :sync_complete)
      end
    end)

    {:noreply, socket}
  end

  def handle_info(:sync_complete, socket) do
    templates = Documents.list_templates_from_db()
    documents = Documents.list_documents_from_db()
    trashed_templates = Documents.list_trashed_templates_from_db()
    trashed_documents = Documents.list_trashed_documents_from_db()

    # Load cached thumbnails from DB
    all_ids =
      Enum.map(templates ++ documents ++ trashed_templates ++ trashed_documents, & &1["id"])

    cached_thumbnails = Documents.load_cached_thumbnails(all_ids)

    # Fetch fresh thumbnails for any files missing them
    missing_thumb_files =
      (templates ++ documents ++ trashed_templates ++ trashed_documents)
      |> Enum.filter(fn f -> is_nil(cached_thumbnails[f["id"]]) end)

    if missing_thumb_files != [], do: load_thumbnails_async(missing_thumb_files)

    {:noreply,
     assign(socket,
       templates: templates,
       documents: documents,
       trashed_templates: trashed_templates,
       trashed_documents: trashed_documents,
       known_file_ids:
         build_known_file_ids(templates, documents, trashed_templates, trashed_documents),
       thumbnails: Map.merge(socket.assigns.thumbnails, cached_thumbnails),
       loading: false,
       last_loaded_at: now_ms()
     )}
  end

  def handle_info(:load_thumbnails, socket) do
    load_thumbnails_async(socket.assigns.templates ++ socket.assigns.documents)
    {:noreply, socket}
  end

  def handle_info({:thumbnail_result, file_id, data_uri}, socket) do
    {:noreply, assign(socket, thumbnails: Map.put(socket.assigns.thumbnails, file_id, data_uri))}
  end

  def handle_info(:poll_for_changes, socket) do
    if not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  def handle_info({:files_changed, from_pid}, socket) do
    if from_pid != self() and not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  def handle_info({:perform_file_action, action, file_id}, socket) do
    is_template = socket.assigns.live_action == :templates
    spec = action_spec(action, is_template)

    socket =
      try do
        case spec.backend.(file_id, actor_opts(socket)) do
          :ok ->
            broadcast_files_changed()

            socket
            |> apply_optimistic_move(file_id, spec)
            |> put_flash(:info, spec.success)

          {:error, reason} ->
            Logger.error("#{action} failed for #{file_id}: #{inspect(reason)}")
            assign(socket, error: spec.failure)
        end
      rescue
        # External Drive/Docs API call can raise — keep the LV alive and
        # show the user a translated failure flash. Without this, the LV
        # crashes and `pending_files` is wedged on remount.
        e ->
          Logger.error(
            "#{action} crashed for #{file_id}: #{Exception.message(e)} | " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          assign(socket, error: spec.failure)
      end

    {:noreply,
     assign(socket, pending_files: MapSet.delete(socket.assigns.pending_files, file_id))}
  end

  # Catch-all to avoid crashing on unexpected messages. Logs at :debug so
  # the noise stays out of prod logs but stray messages are still
  # observable when debugging — silently dropping them was the prior
  # behaviour and made unexpected PubSub or test fixtures hard to trace.
  def handle_info(msg, socket) do
    Logger.debug("DocumentCreator.DocumentsLive: ignoring unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_thumbnails_async(files) do
    Documents.fetch_thumbnails_async(files, self())
  end

  # ── View toggle ──────────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  def handle_event("switch_status", %{"mode" => mode}, socket)
      when mode in ["active", "trashed"] do
    {:noreply, assign(socket, status_mode: mode)}
  end

  # ── Create actions ───────────────────────────────────────────────

  def handle_event("new_template", _params, socket) do
    case Documents.create_template(gettext("Untitled Template"), actor_opts(socket)) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()
        {:noreply, push_event(socket, "open-url", %{url: url})}

      {:error, reason} ->
        Logger.error("Failed to create template: #{inspect(reason)}")
        {:noreply, assign(socket, error: gettext("Failed to create template. Please try again."))}
    end
  end

  def handle_event("set_template_language", %{"id" => file_id} = params, socket) do
    language =
      case Map.get(params, "language", "") do
        "" -> nil
        code -> code
      end

    case verify_known_file(socket, file_id) do
      :ok ->
        case Documents.update_template_language(file_id, language, actor_opts(socket)) do
          {:ok, _template} ->
            templates = Documents.list_templates_from_db()
            {:noreply, assign(socket, templates: templates)}

          {:error, reason} ->
            Logger.error("Failed to set template language for #{file_id}: #{inspect(reason)}")

            {:noreply, assign(socket, error: gettext("Failed to update template language."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("new_blank_document", _params, socket) do
    case Documents.create_document(gettext("Untitled Document"), actor_opts(socket)) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()
        {:noreply, push_event(socket, "open-url", %{url: url})}

      {:error, reason} ->
        Logger.error("Failed to create document: #{inspect(reason)}")
        {:noreply, assign(socket, error: gettext("Failed to create document. Please try again."))}
    end
  end

  # ── Modal events ───────────────────────────────────────────────────

  def handle_event("open_modal", _params, socket) do
    {:noreply,
     assign(socket,
       modal_open: true,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_creating: false
     )}
  end

  def handle_event("modal_close", _params, socket) do
    {:noreply, assign(socket, modal_open: false)}
  end

  def handle_event("modal_back", _params, socket) do
    {:noreply,
     assign(socket, modal_step: "choose", modal_selected_template: nil, modal_variables: [])}
  end

  def handle_event("modal_create_blank", _params, socket) do
    case Documents.create_document(gettext("Untitled Document"), actor_opts(socket)) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()

        {:noreply,
         socket
         |> assign(modal_open: false)
         |> push_event("open-url", %{url: url})}

      {:error, reason} ->
        Logger.error("Failed to create blank document from modal: #{inspect(reason)}")

        {:noreply,
         assign(socket,
           modal_open: false,
           error: gettext("Failed to create document. Please try again.")
         )}
    end
  end

  def handle_event("modal_select_template", %{"id" => file_id, "name" => name}, socket) do
    case verify_known_file(socket, file_id) do
      :ok -> do_modal_select_template(socket, file_id, name)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("modal_create_from_template", params, socket) do
    template = socket.assigns.modal_selected_template
    file_id = template["id"]
    doc_name = Map.get(params, "doc_name", template["name"])
    variable_values = Map.get(params, "var", %{})

    socket = assign(socket, modal_creating: true)

    case Documents.create_document_from_template(
           file_id,
           variable_values,
           [name: doc_name] ++ actor_opts(socket)
         ) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()

        {:noreply,
         socket
         |> assign(modal_open: false, modal_creating: false)
         |> push_event("open-url", %{url: url})}

      {:error, reason} ->
        Logger.error("Failed to create from template: #{inspect(reason)}")

        {:noreply,
         assign(socket,
           modal_creating: false,
           error: gettext("Failed to create document. Please try again.")
         )}
    end
  end

  # ── Unfiled actions ──────────────────────────────────────────────

  def handle_event(
        "open_unfiled_actions",
        %{"id" => file_id, "name" => name, "path" => path_value},
        socket
      ) do
    case verify_known_file(socket, file_id) do
      :ok ->
        {:noreply,
         assign(socket,
           unfiled_modal_open: true,
           unfiled_working: false,
           unfiled_file: %{"id" => file_id, "name" => name, "path" => path_value}
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("unfiled_close", _params, socket) do
    {:noreply,
     assign(socket, unfiled_modal_open: false, unfiled_file: nil, unfiled_working: false)}
  end

  def handle_event("unfiled_action", %{"action" => action}, socket) do
    file = socket.assigns.unfiled_file || %{}
    file_id = file["id"]

    opts = actor_opts(socket)

    result =
      case action do
        "templates" -> Documents.move_to_templates(file_id, opts)
        "documents" -> Documents.move_to_documents(file_id, opts)
        "current" -> Documents.set_correct_location(file_id, opts)
        _ -> {:error, :invalid_action}
      end

    case result do
      :ok ->
        broadcast_files_changed()
        send(self(), :sync_from_drive)

        {:noreply,
         socket
         |> assign(
           unfiled_modal_open: false,
           unfiled_file: nil,
           unfiled_working: false,
           loading: true
         )
         |> put_flash(:info, unfiled_success_message(action))}

      {:error, reason} ->
        Logger.error("Unfiled action failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(unfiled_working: false)
         |> assign(error: gettext("Action failed. Please try again."))}
    end
  end

  # ── PDF export ───────────────────────────────────────────────────

  def handle_event("export_pdf", %{"id" => file_id, "name" => name}, socket) do
    case verify_known_file(socket, file_id) do
      :ok ->
        case Documents.export_pdf(file_id, [name: name] ++ actor_opts(socket)) do
          {:ok, pdf_binary} when byte_size(pdf_binary) <= @max_pdf_push_bytes ->
            base64 = Base.encode64(pdf_binary)
            filename = sanitize_filename(name)
            {:noreply, push_event(socket, "download-pdf", %{base64: base64, filename: filename})}

          {:ok, _large_pdf} ->
            {:noreply,
             assign(socket,
               error:
                 gettext(
                   "PDF is too large to download directly. Please export from Google Docs instead."
                 )
             )}

          {:error, reason} ->
            Logger.error("PDF export failed: #{inspect(reason)}")
            {:noreply, assign(socket, error: gettext("PDF export failed. Please try again."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── Delete (soft) ────────────────────────────────────────────────

  def handle_event("delete", %{"id" => file_id}, socket) do
    case verify_known_file(socket, file_id) do
      :ok -> do_delete(socket, file_id)
      _ -> {:noreply, socket}
    end
  end

  # ── Restore (from trash) ─────────────────────────────────────────

  def handle_event("restore", %{"id" => file_id}, socket) do
    case verify_known_file(socket, file_id) do
      :ok -> do_restore(socket, file_id)
      _ -> {:noreply, socket}
    end
  end

  # ── Refresh ──────────────────────────────────────────────────────

  def handle_event("refresh", _params, socket) do
    Documents.log_manual_action("sync.triggered", actor_opts(socket))
    send(self(), :sync_from_drive)
    {:noreply, assign(socket, loading: true)}
  end

  def handle_event("silent_refresh", _params, socket) do
    if not socket.assigns.loading and not within_cooldown?(socket) do
      send(self(), :sync_from_drive)
    end

    {:noreply, socket}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, error: nil)}
  end

  # ── Event helpers ──────────────────────────────────────────────────

  defp do_modal_select_template(socket, file_id, name) do
    variables =
      case Documents.detect_variables(file_id) do
        {:ok, vars} ->
          PhoenixKitDocumentCreator.Variable.build_definitions(vars)
          |> Enum.map(&Map.from_struct/1)

        _ ->
          []
      end

    template = %{"id" => file_id, "name" => name}

    if variables == [] do
      create_from_template_directly(socket, file_id, name)
    else
      {:noreply,
       assign(socket,
         modal_step: "variables",
         modal_selected_template: template,
         modal_variables: variables
       )}
    end
  end

  defp create_from_template_directly(socket, file_id, name) do
    case Documents.create_document_from_template(
           file_id,
           %{},
           [name: name] ++ actor_opts(socket)
         ) do
      {:ok, %{url: url}} ->
        broadcast_files_changed()
        {:noreply, socket |> assign(modal_open: false) |> push_event("open-url", %{url: url})}

      {:error, reason} ->
        Logger.error("Failed to create from template: #{inspect(reason)}")

        {:noreply, assign(socket, error: gettext("Failed to create document. Please try again."))}
    end
  end

  defp do_delete(socket, file_id), do: schedule_file_action(socket, file_id, :delete)
  defp do_restore(socket, file_id), do: schedule_file_action(socket, file_id, :restore)

  # Optimistically marks the file as pending so the card renders a spinner,
  # then kicks off the backend call asynchronously via `handle_info`.
  defp schedule_file_action(socket, file_id, action) do
    if MapSet.member?(socket.assigns.pending_files, file_id) do
      {:noreply, socket}
    else
      send(self(), {:perform_file_action, action, file_id})

      {:noreply, assign(socket, pending_files: MapSet.put(socket.assigns.pending_files, file_id))}
    end
  end

  defp action_spec(:delete, true) do
    %{
      backend: &Documents.delete_template/2,
      source: :templates,
      dest: :trashed_templates,
      new_status: "trashed",
      success: gettext("Moved to deleted folder"),
      failure: gettext("Delete failed. Please try again.")
    }
  end

  defp action_spec(:delete, false) do
    %{
      backend: &Documents.delete_document/2,
      source: :documents,
      dest: :trashed_documents,
      new_status: "trashed",
      success: gettext("Moved to deleted folder"),
      failure: gettext("Delete failed. Please try again.")
    }
  end

  defp action_spec(:restore, true) do
    %{
      backend: &Documents.restore_template/2,
      source: :trashed_templates,
      dest: :templates,
      new_status: "published",
      success: gettext("Restored"),
      failure: gettext("Restore failed. Please try again.")
    }
  end

  defp action_spec(:restore, false) do
    %{
      backend: &Documents.restore_document/2,
      source: :trashed_documents,
      dest: :documents,
      new_status: "published",
      success: gettext("Restored"),
      failure: gettext("Restore failed. Please try again.")
    }
  end

  defp apply_optimistic_move(socket, file_id, spec) do
    source_list = Map.fetch!(socket.assigns, spec.source)
    dest_list = Map.fetch!(socket.assigns, spec.dest)
    file = Enum.find(source_list, &(&1["id"] == file_id))

    new_source = Enum.reject(source_list, &(&1["id"] == file_id))

    new_dest =
      if file, do: [Map.put(file, "status", spec.new_status) | dest_list], else: dest_list

    socket
    |> assign(spec.source, new_source)
    |> assign(spec.dest, new_dest)
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <%!-- Not connected banner --%>
      <%= if not @google_connected do %>
        <div class="card bg-base-100 shadow-sm border border-warning/30">
          <div class="card-body items-center text-center py-12">
            <span class="hero-exclamation-triangle w-12 h-12 text-warning" />
            <h2 class="card-title mt-2">{gettext("Google Account Not Connected")}</h2>
            <p class="text-sm text-base-content/60 max-w-md">
              {gettext(
                "The Document Creator uses Google Docs for editing and Google Drive for storage. Connect a Google account in Settings to get started."
              )}
            </p>
            <div class="card-actions mt-4">
              <a href={settings_path()} class="btn btn-primary btn-sm">
                <span class="hero-cog-6-tooth w-4 h-4" /> {gettext("Go to Settings")}
              </a>
            </div>
          </div>
        </div>
      <% else %>
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold">
            {if @live_action == :templates, do: gettext("Templates"), else: gettext("Documents")}
          </h1>
          <div class="flex gap-2">
            <button
              class="btn btn-ghost btn-sm"
              phx-click="refresh"
              disabled={@loading}
              phx-disable-with={gettext("Refreshing…")}
            >
              <span :if={@loading} class="loading loading-spinner loading-xs" />
              <span :if={not @loading} class="hero-arrow-path w-4 h-4" />
            </button>
            <%= if @live_action == :templates do %>
              <a
                :if={templates_folder_url()}
                href={templates_folder_url()}
                target="_blank"
                class="btn btn-ghost btn-sm"
              >
                <span class="hero-folder-open w-4 h-4" /> {gettext("Open Folder")}
              </a>
              <button
                class="btn btn-primary btn-sm"
                phx-click="new_template"
                phx-disable-with={gettext("Creating...")}
              >
                <span class="hero-plus w-4 h-4" /> {gettext("New Template")}
              </button>
            <% else %>
              <a
                :if={documents_folder_url()}
                href={documents_folder_url()}
                target="_blank"
                class="btn btn-ghost btn-sm"
              >
                <span class="hero-folder-open w-4 h-4" /> {gettext("Open Folder")}
              </a>
              <button
                class="btn btn-primary btn-sm"
                phx-click="open_modal"
                phx-disable-with={gettext("Opening...")}
              >
                <span class="hero-document-plus w-4 h-4" /> {gettext("New Document")}
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Status Tabs (Active / Trash) — auto-hidden when trash is empty --%>
        <% trashed_count =
          if @live_action == :templates,
            do: length(@trashed_templates),
            else: length(@trashed_documents) %>
        <% active_count =
          if @live_action == :templates,
            do: length(@templates),
            else: length(@documents) %>
        <% all_status_tabs = [
          {"active", gettext("Active"), active_count, nil},
          {"trashed", gettext("Trash"), trashed_count, "error"}
        ] %>
        <% visible_status_tabs =
          Enum.filter(all_status_tabs, fn {mode, _label, count, _color} ->
            count > 0 or @status_mode == mode
          end) %>
        <%!-- Status tabs + view toggle on one row --%>
        <% show_status_tabs = length(visible_status_tabs) > 1 %>
        <div class={"flex items-center justify-between gap-2 #{if show_status_tabs, do: "border-b border-base-200"}"}>
          <div class="flex items-center gap-0.5 min-w-0 overflow-x-auto">
            <%= if show_status_tabs do %>
              <%= for {mode, label, _count, color} <- visible_status_tabs do %>
                <button
                  type="button"
                  phx-click="switch_status"
                  phx-value-mode={mode}
                  class={"px-3 py-1 text-xs font-medium border-b-2 transition-colors whitespace-nowrap cursor-pointer #{cond do
                    @status_mode == mode and color == "error" -> "border-error text-error"
                    @status_mode == mode -> "border-primary text-primary"
                    true -> "border-transparent text-base-content/50 hover:text-base-content"
                  end}"}
                >
                  {label}
                </button>
              <% end %>
            <% end %>
          </div>
          <div class="flex gap-1 flex-shrink-0">
            <button
              class={"btn btn-ghost btn-sm btn-square #{if @view_mode == "cards", do: "btn-active"}"}
              phx-click="switch_view"
              phx-value-mode="cards"
            >
              <span class="hero-squares-2x2 w-4 h-4" />
            </button>
            <button
              class={"btn btn-ghost btn-sm btn-square #{if @view_mode == "list", do: "btn-active"}"}
              phx-click="switch_view"
              phx-value-mode="list"
            >
              <span class="hero-list-bullet w-4 h-4" />
            </button>
          </div>
        </div>

        <%!-- Error --%>
        <div :if={@error} class="alert alert-error" phx-click="dismiss_error">
          <span class="hero-x-circle w-5 h-5" />
          <span>{@error}</span>
        </div>

        <%!-- Loading skeletons --%>
        <%= if @loading do %>
          <%= if @view_mode == "cards" do %>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4">
              <div
                :for={_ <- 1..5}
                class="flex flex-col animate-pulse skeleton"
                style="border: 1.5px solid oklch(var(--color-base-content) / 0.1); border-radius: 8px; overflow: hidden; padding-bottom: 12px;"
              >
                <div style="padding:16px 16px 24px 16px;display:flex;justify-content:center;">
                  <div class="skeleton" style="width:183px;height:258px;border-radius:4px;" />
                </div>
                <div class="p-3 flex-1 flex flex-col gap-2">
                  <div class="skeleton h-4 rounded w-3/4" />
                  <div class="skeleton h-3 rounded w-1/2 mt-auto" />
                </div>
                <div class="flex gap-1 px-2 pb-2 pt-1">
                  <div class="skeleton flex-1 h-6 rounded" />
                  <div class="skeleton flex-1 h-6 rounded" />
                </div>
              </div>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Name")}</th>
                    <th>{gettext("Modified")}</th>
                    <th class="text-right">{gettext("Actions")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={_ <- 1..6}>
                    <td><div class="skeleton h-4 rounded w-48" /></td>
                    <td><div class="skeleton h-4 rounded w-24" /></td>
                    <td class="text-right">
                      <div class="flex gap-1 justify-end">
                        <div class="skeleton h-6 w-6 rounded" />
                        <div class="skeleton h-6 w-6 rounded" />
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        <% end %>

        <%!-- Content --%>
        <%= if not @loading do %>
          <% files_for_mode =
            case {@live_action, @status_mode} do
              {:templates, "trashed"} -> @trashed_templates
              {:templates, _} -> @templates
              {_, "trashed"} -> @trashed_documents
              {_, _} -> @documents
            end %>
          {render_file_grid(assign_files(assigns, files_for_mode))}
        <% end %>
      <% end %>
    </div>

    <button id="silent-refresh-btn" phx-click="silent_refresh" class="hidden" />

    <%!-- Create document modal --%>
    <.modal
      open={@modal_open}
      templates={@templates}
      step={@modal_step}
      selected_template={@modal_selected_template}
      variables={@modal_variables}
      creating={@modal_creating}
      thumbnails={@thumbnails}
    />

    <PhoenixKitWeb.Components.Core.Modal.modal
      id="unfiled-actions-modal"
      show={@unfiled_modal_open and @unfiled_file != nil}
      on_close="unfiled_close"
      max_width="md"
    >
      <:title>{gettext("Resolve Unfiled Item")}</:title>

      <div :if={@unfiled_file} class="space-y-4">
        <p class="text-sm text-base-content/70">
          {gettext("Choose how %{name} should be handled.", name: @unfiled_file["name"])}
        </p>

        <div class="rounded-lg bg-base-200/70 px-3 py-2 text-sm text-base-content/70">
          {gettext("Saved location:")}
          <span class="font-medium text-base-content">{pretty_path(@unfiled_file["path"])}</span>
        </div>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="unfiled_close">
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-outline"
          phx-click="unfiled_action"
          phx-value-action="current"
          disabled={@unfiled_working}
          phx-disable-with={gettext("Working…")}
        >
          {gettext("Set This As Correct Location")}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-outline"
          phx-click="unfiled_action"
          phx-value-action="documents"
          disabled={@unfiled_working}
          phx-disable-with={gettext("Working…")}
        >
          {gettext("Move To Documents")}
        </button>
        <button
          type="button"
          class="btn btn-primary"
          phx-click="unfiled_action"
          phx-value-action="templates"
          disabled={@unfiled_working}
          phx-disable-with={gettext("Working…")}
        >
          {gettext("Move To Templates")}
        </button>
      </:actions>
    </PhoenixKitWeb.Components.Core.Modal.modal>

    <script>
      // Idempotent script — guarded to prevent duplicate listeners on re-render (M3)
      if (!window.__pkDocCreatorInitialized) {
        window.__pkDocCreatorInitialized = true;

        window.addEventListener("phx:open-url", function(e) {
          var a = document.createElement("a");
          a.href = e.detail.url;
          a.target = "_blank";
          a.rel = "noopener";
          document.body.appendChild(a);
          a.click();
          a.remove();
        });
        window.addEventListener("phx:download-pdf", function(e) {
          var a = document.createElement("a");
          a.href = "data:application/pdf;base64," + e.detail.base64;
          a.download = e.detail.filename;
          document.body.appendChild(a);
          a.click();
          a.remove();
        });
        // Silently check for changes when tab regains focus (user returns from Google Docs)
        (function() {
          var lastHidden = 0;
          document.addEventListener("visibilitychange", function() {
            if (document.visibilityState === "hidden") {
              lastHidden = Date.now();
            } else if (document.visibilityState === "visible" && Date.now() - lastHidden > 3000) {
              var btn = document.getElementById("silent-refresh-btn");
              if (btn) btn.click();
            }
          });
        })();
      }
    </script>
    """
  end

  # ── File grid ──────────────────────────────────────────────────

  defp assign_files(assigns, files) do
    %{
      files: files,
      view_mode: assigns.view_mode,
      status_mode: assigns.status_mode,
      pending_files: assigns.pending_files,
      thumbnails: assigns.thumbnails,
      is_template: assigns.live_action == :templates,
      enabled_languages: assigns.enabled_languages
    }
  end

  defp render_file_grid(assigns) do
    ~H"""
    <div :if={@files == []} class="card bg-base-100 shadow-sm">
      <div class="card-body items-center text-center py-12">
        <%= if @status_mode == "trashed" do %>
          <span class="hero-trash w-12 h-12 text-base-content/20" />
          <p class="text-sm text-base-content/50 mt-2">{gettext("Trash is empty")}</p>
        <% else %>
          <span class="hero-document-text w-12 h-12 text-base-content/20" />
          <p class="text-sm text-base-content/50 mt-2">{gettext("No files yet")}</p>
        <% end %>
      </div>
    </div>

    <%= if @view_mode == "cards" do %>
      <div
        :if={@files != []}
        class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-4"
      >
        <div
          :for={file <- @files}
          class={"group flex flex-col card bg-base-100 relative #{if MapSet.member?(@pending_files, file["id"]), do: "opacity-40 pointer-events-none"}"}
          style="border: 1.5px solid currentColor; border-radius: 8px; overflow: hidden; padding-bottom: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.3);"
        >
          <div
            :if={MapSet.member?(@pending_files, file["id"])}
            class="absolute inset-0 z-10 flex items-center justify-center pointer-events-none"
          >
            <span class="loading loading-spinner loading-lg text-base-content opacity-100" />
          </div>
          <%!-- Preview --%>
          <a
            href={GoogleDocsClient.get_edit_url(file["id"])}
            target="_blank"
            style="display:flex;justify-content:center;padding:16px 16px 24px 16px;background:oklch(var(--color-base-200));"
          >
            {render_thumbnail(%{thumbnail: @thumbnails[file["id"]]})}
          </a>

          <%!-- Info --%>
          <div class="p-3 flex-1 flex flex-col">
            <div class="flex items-center gap-1.5">
              <a
                href={GoogleDocsClient.get_edit_url(file["id"])}
                target="_blank"
                class="font-medium text-sm truncate link link-hover"
              >
                {file["name"]}
              </a>
              <span
                :if={file["status"] == "lost"}
                class="badge badge-warning badge-xs"
                title={gettext("File not found in Google Drive")}
              >
                {gettext("lost")}
              </span>
              <button
                :if={file["status"] == "unfiled"}
                type="button"
                class="badge badge-info badge-xs cursor-pointer"
                phx-click="open_unfiled_actions"
                phx-value-id={file["id"]}
                phx-value-name={file["name"]}
                phx-value-path={file["path"] || ""}
                title={
                  gettext(
                    "File exists in Drive but is outside the configured Document Creator folders"
                  )
                }
              >
                {gettext("unfiled")}
              </button>
            </div>
            {render_language_picker(%{
              file: file,
              is_template: @is_template,
              enabled_languages: @enabled_languages,
              status_mode: @status_mode
            })}
            <p :if={file["modifiedTime"]} class="text-xs text-base-content/40 mt-auto pt-2">
              {format_time(file["modifiedTime"])}
            </p>
          </div>

          <%!-- Actions --%>
          <div class="flex gap-1 px-2 pb-2 pt-1">
            <%= if @status_mode == "trashed" do %>
              <a
                href={GoogleDocsClient.get_edit_url(file["id"])}
                target="_blank"
                class="flex-1 btn btn-ghost btn-xs py-2"
              >
                <span class="hero-eye w-3 h-3" /> {gettext("View")}
              </a>
            <% else %>
              <a
                href={GoogleDocsClient.get_edit_url(file["id"])}
                target="_blank"
                class="flex-1 btn btn-ghost btn-xs py-2"
              >
                <span class="hero-pencil-square w-3 h-3" /> {gettext("Edit")}
              </a>
            <% end %>
            <button
              class="flex-1 btn btn-ghost btn-xs py-2"
              phx-click="export_pdf"
              phx-value-id={file["id"]}
              phx-value-name={file["name"]}
              phx-disable-with={gettext("Exporting…")}
            >
              <span class="hero-arrow-down-tray w-3 h-3" /> {gettext("PDF")}
            </button>
            <%= if @status_mode == "trashed" do %>
              <button
                class="btn btn-ghost btn-xs py-2 text-success"
                phx-click="restore"
                phx-value-id={file["id"]}
                title={gettext("Restore")}
                phx-disable-with={gettext("Restoring…")}
              >
                <span class="hero-arrow-uturn-left w-3 h-3" />
              </button>
            <% else %>
              <button
                class="btn btn-ghost btn-xs py-2 text-error"
                phx-click="delete"
                phx-value-id={file["id"]}
                phx-disable-with={gettext("Deleting…")}
              >
                <span class="hero-trash w-3 h-3" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% else %>
      <div :if={@files != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>
              <th>{gettext("Status")}</th>
              <th>{gettext("Modified")}</th>
              <th class="text-right">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={file <- @files} class="hover:bg-base-200/50">
              <%= if MapSet.member?(@pending_files, file["id"]) do %>
                <td colspan="4" class="text-center py-6">
                  <span class="loading loading-spinner loading-sm text-base-content/40" />
                </td>
              <% else %>
              <td>
                <div class="flex items-center gap-2">
                  <a
                    href={GoogleDocsClient.get_edit_url(file["id"])}
                    target="_blank"
                    class="font-medium link link-hover"
                  >
                    {file["name"]}
                  </a>
                  {render_language_picker(%{
                    file: file,
                    is_template: @is_template,
                    enabled_languages: @enabled_languages,
                    status_mode: @status_mode
                  })}
                </div>
              </td>
              <td>
                <span :if={file["status"] == "lost"} class="badge badge-warning badge-xs">
                  {gettext("lost")}
                </span>
                <button
                  :if={file["status"] == "unfiled"}
                  type="button"
                  class="badge badge-info badge-xs cursor-pointer"
                  phx-click="open_unfiled_actions"
                  phx-value-id={file["id"]}
                  phx-value-name={file["name"]}
                  phx-value-path={file["path"] || ""}
                  title={
                    gettext(
                      "File exists in Drive but is outside the configured Document Creator folders"
                    )
                  }
                >
                  {gettext("unfiled")}
                </button>
              </td>
              <td class="text-base-content/60 text-nowrap">{format_time(file["modifiedTime"])}</td>
              <td class="text-right">
                <div class="flex gap-1 justify-end">
                  <%= if @status_mode == "trashed" do %>
                    <a
                      href={GoogleDocsClient.get_edit_url(file["id"])}
                      target="_blank"
                      class="btn btn-ghost btn-xs"
                      title={gettext("View")}
                    >
                      <span class="hero-eye w-3.5 h-3.5" />
                    </a>
                  <% else %>
                    <a
                      href={GoogleDocsClient.get_edit_url(file["id"])}
                      target="_blank"
                      class="btn btn-ghost btn-xs"
                      title={gettext("Edit")}
                    >
                      <span class="hero-pencil-square w-3.5 h-3.5" />
                    </a>
                  <% end %>
                  <button
                    class="btn btn-ghost btn-xs"
                    phx-click="export_pdf"
                    phx-value-id={file["id"]}
                    phx-value-name={file["name"]}
                    title={gettext("Export PDF")}
                    phx-disable-with={gettext("Exporting…")}
                  >
                    <span class="hero-arrow-down-tray w-3.5 h-3.5" />
                  </button>
                  <%= if @status_mode == "trashed" do %>
                    <button
                      class="btn btn-ghost btn-xs text-success gap-1"
                      phx-click="restore"
                      phx-value-id={file["id"]}
                      title={gettext("Restore")}
                      phx-disable-with={gettext("Restoring…")}
                    >
                      <span class="hero-arrow-uturn-left w-3.5 h-3.5" />
                      <span class="text-xs">{gettext("Restore")}</span>
                    </button>
                  <% else %>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="delete"
                      phx-value-id={file["id"]}
                      title={gettext("Delete")}
                      phx-disable-with={gettext("Deleting…")}
                    >
                      <span class="hero-trash w-3.5 h-3.5" />
                    </button>
                  <% end %>
                </div>
              </td>
              <% end %>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp pretty_path(nil), do: gettext("root")
  defp pretty_path(""), do: gettext("root")
  defp pretty_path(path), do: path

  defp unfiled_success_message("templates"), do: gettext("Moved to templates")
  defp unfiled_success_message("documents"), do: gettext("Moved to documents")
  defp unfiled_success_message("current"), do: gettext("Saved current location")
  defp unfiled_success_message(_), do: gettext("Updated")

  # Per-template language picker. Hidden on the documents tab (documents
  # inherit language from their source template), in the trash view, and
  # when the host app's Languages module isn't enabled (`enabled_languages`
  # arrives as `[]`). Shows the current locale code or "Set language" on
  # the trigger; clicking opens a native HTML `popover` listing every
  # enabled language plus a "Clear" entry. Popovers escape the card's
  # `overflow: hidden` clipping container automatically.
  defp render_language_picker(assigns) do
    ~H"""
    <div
      :if={@is_template and @status_mode != "trashed" and @enabled_languages != []}
      class="relative inline-flex"
    >
      <button
        type="button"
        popovertarget={"lang-pop-" <> @file["id"]}
        style={"anchor-name: --lang-trigger-#{@file["id"]}"}
        class={"badge badge-xs cursor-pointer #{if @file["language"], do: "badge-ghost", else: "badge-outline border-dashed"}"}
        title={gettext("Template language")}
      >
        <span :if={@file["language"]} class="font-mono uppercase">
          {@file["language"]}
        </span>
        <span :if={!@file["language"]}>
          {gettext("Set language")}
        </span>
        <span class="hero-chevron-down w-2.5 h-2.5" />
      </button>
      <div
        id={"lang-pop-" <> @file["id"]}
        popover="auto"
        style={
          "position-anchor: --lang-trigger-#{@file["id"]}; " <>
          "position-area: bottom span-right; " <>
          "margin: 4px 0 0 0; inset: auto;"
        }
        class="bg-base-100 rounded-box w-60 p-1 shadow-lg max-h-72 overflow-y-auto border border-base-300 [&:not(:popover-open)]:hidden"
      >
        <%= for lang <- @enabled_languages do %>
          <button
            type="button"
            popovertarget={"lang-pop-" <> @file["id"]}
            popovertargetaction="hide"
            phx-click="set_template_language"
            phx-value-id={@file["id"]}
            phx-value-language={lang.code}
            class={"w-full flex items-center gap-2 px-2 py-1.5 rounded text-left text-sm hover:bg-base-200 #{if @file["language"] == lang.code, do: "bg-primary/10 text-primary", else: ""}"}
          >
            <span class="font-mono uppercase text-xs opacity-60 w-12 shrink-0">{lang.code}</span>
            <span class="truncate flex-1">{lang.name}</span>
          </button>
        <% end %>
        <button
          :if={@file["language"]}
          type="button"
          popovertarget={"lang-pop-" <> @file["id"]}
          popovertargetaction="hide"
          phx-click="set_template_language"
          phx-value-id={@file["id"]}
          phx-value-language=""
          class="w-full flex items-center gap-2 px-2 py-1.5 rounded text-left text-sm text-base-content/50 hover:bg-base-200 mt-1 border-t border-base-200 pt-2"
        >
          <span class="hero-x-mark w-3.5 h-3.5" /> {gettext("Clear language")}
        </button>
      </div>
    </div>
    """
  end

  defp render_thumbnail(assigns) do
    ~H"""
    <div style="width:183px;height:258px;overflow:hidden;border-radius:4px;background:#fff;border:1px solid oklch(var(--color-base-content) / 0.2);box-shadow:0 2px 8px rgba(0,0,0,0.08);">
      <%= if @thumbnail do %>
        <img src={@thumbnail} style="width:100%;height:100%;object-fit:cover;object-position:top;" />
      <% else %>
        <div style="width:100%;height:100%;background:#fff;display:flex;align-items:center;justify-content:center;">
          <span class="loading loading-spinner loading-md text-base-300" />
        </div>
      <% end %>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp settings_path, do: PhoenixKitDocumentCreator.Paths.settings()
  defp templates_folder_url, do: Documents.templates_folder_url()
  defp documents_folder_url, do: Documents.documents_folder_url()

  defp format_time(nil), do: ""

  defp format_time(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y")
      _ -> iso_string
    end
  end

  defp sanitize_filename(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> Kernel.<>(".pdf")
  end

  defp actor_opts(socket), do: Helpers.actor_opts(socket)

  # `known_file_ids` is a `MapSet` of every file ID this LV has loaded
  # across the four lists. Maintained by `assign_file_lists/2` whenever
  # any of those lists change. Lookup is O(1) — replaces the previous
  # 4× `Enum.any?/2` shape that was O(N) per event and noticeable on
  # folders with thousands of files.
  defp verify_known_file(socket, file_id) do
    if MapSet.member?(socket.assigns.known_file_ids, file_id),
      do: :ok,
      else: :unknown
  end

  defp build_known_file_ids(templates, documents, trashed_templates, trashed_documents) do
    [templates, documents, trashed_templates, trashed_documents]
    |> Enum.flat_map(fn list -> Enum.map(list, & &1["id"]) end)
    |> MapSet.new()
  end

  defp broadcast_files_changed do
    PhoenixKit.PubSubHelper.broadcast(@pubsub_topic, {:files_changed, self()})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp within_cooldown?(socket) do
    case socket.assigns.last_loaded_at do
      nil -> false
      last -> now_ms() - last < @refresh_cooldown_ms
    end
  end
end
