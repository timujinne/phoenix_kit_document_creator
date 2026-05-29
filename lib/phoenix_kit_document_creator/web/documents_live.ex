defmodule PhoenixKitDocumentCreator.Web.DocumentsLive do
  @moduledoc """
  Main listing page for the Document Creator.

  Lists templates and documents from the local database for fast rendering.
  Background sync keeps the DB in sync with Google Drive. Files that
  disappear from Drive are shown with a "lost" indicator.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  require Logger

  import PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKit.Users.Auth
  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Errors
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers
  alias PhoenixKitWeb.Helpers.MediaSelectorHelper

  @pubsub_topic PhoenixKitDocumentCreator.Documents.pubsub_topic()
  @refresh_cooldown_ms :timer.seconds(5)
  @max_pdf_push_bytes 5_000_000
  @per_page 20

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
       # `page_title` is set in `handle_params/3` so the gettext lookup
       # runs AFTER the parent app's telemetry locale-sync hook has set
       # the process-global locale. Setting it here in `mount/3` would
       # capture the raw English msgid.
       view_mode: "cards",
       loaded: false,
       google_connected: false,
       templates: [],
       documents: [],
       trashed_templates: [],
       trashed_documents: [],
       known_file_ids: MapSet.new(),
       status_mode: "active",
       page: 1,
       filters: %{"category" => "", "type" => "", "lang" => "", "sub_status" => "", "q" => ""},
       # %{uuid => display_name} for the user who trashed each file. Resolved
       # when the trashed lists load/change (not in render) — see
       # assign_deleted_by_names/1.
       deleted_by_names: %{},
       pending_files: MapSet.new(),
       thumbnails: %{},
       enabled_languages: [],
       loading: true,
       last_loaded_at: nil,
       error: nil,
       warning: nil,
       # Modal state
       modal_open: false,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_image_values: %{},
       modal_creating: false,
       unfiled_modal_open: false,
       unfiled_file: nil,
       unfiled_working: false,
       # Mobile-only: filters/search are collapsed behind a "Filters" toggle on
       # narrow screens (< sm). Always visible on sm+ regardless of this flag.
       show_filters: false
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    title =
      case socket.assigns.live_action do
        :templates -> gettext("Templates")
        _ -> gettext("Documents")
      end

    url_path = URI.parse(uri).path || "/"

    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {n, ""} when n >= 1 -> n
        _ -> 1
      end

    view_mode = Map.get(params, "view", socket.assigns.view_mode)
    status_mode = Map.get(params, "status", socket.assigns.status_mode)

    filters = %{
      "category" => Map.get(params, "category", ""),
      "type" => Map.get(params, "type", ""),
      "lang" => Map.get(params, "lang", ""),
      "sub_status" => Map.get(params, "sub_status", ""),
      "q" => params |> Map.get("q", "") |> String.trim()
    }

    socket =
      assign(socket,
        page_title: title,
        url_path: url_path,
        page: page,
        view_mode: view_mode,
        status_mode: status_mode,
        filters: filters
      )

    {:noreply, apply_media_selection(params, socket)}
  end

  defp apply_media_selection(params, socket) do
    case MediaSelectorHelper.parse_selected_media(params) do
      {:ok, uuids} ->
        var_name = Map.get(params, "picking_var")
        mode = Map.get(params, "picking_mode", "single")
        template_file_id = Map.get(params, "template_file_id")
        existing_json = Map.get(params, "picking_existing", "{}")

        prior_image_values = prior_image_values_from_json(existing_json)

        socket
        |> restore_template_state(template_file_id)
        |> assign(modal_image_values: prior_image_values)
        |> apply_image_selection(var_name, mode, uuids)

      :none ->
        socket
    end
  end

  defp restore_template_state(socket, nil), do: socket

  defp restore_template_state(socket, template_file_id) do
    case Documents.get_template_from_db(template_file_id) do
      {:ok, template} ->
        variables = Documents.get_template_variables_from_db(template_file_id)

        assign(socket,
          modal_selected_template: template,
          modal_variables: Enum.map(variables, &Map.from_struct/1)
        )

      _ ->
        socket
    end
  end

  defp apply_image_selection(socket, nil, _mode, _uuids), do: socket

  defp apply_image_selection(socket, var_name, "multiple", uuids) do
    image_values = Map.put(socket.assigns.modal_image_values, var_name, %{"media_ids" => uuids})

    assign(socket,
      modal_open: true,
      modal_step: "variables",
      modal_image_values: image_values
    )
  end

  defp apply_image_selection(socket, var_name, _single, [uuid | _]) do
    image_values = Map.put(socket.assigns.modal_image_values, var_name, %{"media_id" => uuid})

    assign(socket,
      modal_open: true,
      modal_step: "variables",
      modal_image_values: image_values
    )
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

    socket =
      socket
      |> assign(
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
      )
      |> assign_deleted_by_names()

    {:noreply, socket}
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

    socket =
      socket
      |> assign(
        templates: templates,
        documents: documents,
        trashed_templates: trashed_templates,
        trashed_documents: trashed_documents,
        known_file_ids:
          build_known_file_ids(templates, documents, trashed_templates, trashed_documents),
        thumbnails: Map.merge(socket.assigns.thumbnails, cached_thumbnails),
        loading: false,
        last_loaded_at: now_ms()
      )
      |> assign_deleted_by_names()

    {:noreply, socket}
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

          {:error, :drive_file_not_found} when action == :restore ->
            Logger.warning("#{action} failed for #{file_id}: drive file not found (404)")
            assign(socket, warning: Errors.message(:drive_file_not_found))

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
    {:noreply, push_patch(socket, to: list_path_with_params(socket, %{"view" => mode}))}
  end

  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, show_filters: not socket.assigns.show_filters)}
  end

  def handle_event("switch_status", %{"mode" => mode}, socket)
      when mode in ["active", "trashed"] do
    {:noreply,
     push_patch(socket, to: list_path_with_params(socket, %{"status" => mode, "page" => "1"}))}
  end

  def handle_event("filter", filter_params, socket) do
    old_category = socket.assigns.filters["category"]
    new_category = Map.get(filter_params, "category", "")

    # Clear type selection when category changes to avoid stale cross-category filter
    new_type =
      if old_category != new_category, do: "", else: Map.get(filter_params, "type", "")

    new_filters =
      socket.assigns.filters
      |> Map.put("category", new_category)
      |> Map.put("type", new_type)
      |> Map.put("lang", Map.get(filter_params, "lang", ""))
      |> Map.put("sub_status", Map.get(filter_params, "sub_status", ""))
      |> Map.put("q", filter_params |> Map.get("q", "") |> String.trim())

    {:noreply,
     push_patch(socket,
       to: list_path_with_params(socket, Map.put(new_filters, "page", "1"))
     )}
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
          {:ok, updated} ->
            # In-place patch on the existing assign — the self-broadcast is
            # filtered out, so without this patch the badge would lag until
            # the next sync. Beats re-reading the whole templates table.
            templates =
              patch_template_language(socket.assigns.templates, file_id, updated.language)

            {:noreply, assign(socket, templates: templates)}

          {:error, reason} ->
            Logger.error("Failed to set template language for #{file_id}: #{inspect(reason)}")

            {:noreply, assign(socket, error: gettext("Failed to update template language."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "set_taxonomy_category",
        %{"google_doc_id" => gid, "kind" => kind} = params,
        socket
      ) do
    category_uuid = blank_to_nil(params["value"])
    taxonomy = %{category_uuid: category_uuid, type_uuid: nil}

    result =
      case kind do
        "template" -> Documents.update_template_taxonomy(gid, taxonomy)
        "document" -> Documents.update_document_taxonomy(gid, taxonomy)
      end

    {:noreply, apply_taxonomy_result(socket, result, :category)}
  end

  def handle_event(
        "set_taxonomy_type",
        %{"google_doc_id" => gid, "kind" => kind} = params,
        socket
      ) do
    type_uuid = blank_to_nil(params["value"])
    taxonomy = %{type_uuid: type_uuid}

    result =
      case kind do
        "template" -> Documents.update_template_taxonomy(gid, taxonomy)
        "document" -> Documents.update_document_taxonomy(gid, taxonomy)
      end

    {:noreply, apply_taxonomy_result(socket, result, :type)}
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
       modal_image_values: %{},
       modal_creating: false
     )}
  end

  def handle_event("modal_close", _params, socket) do
    {:noreply, assign(socket, modal_open: false)}
  end

  def handle_event("modal_back", _params, socket) do
    {:noreply,
     assign(socket,
       modal_step: "choose",
       modal_selected_template: nil,
       modal_variables: [],
       modal_image_values: %{}
     )}
  end

  def handle_event("open_media_picker", %{"name" => var_name, "mode" => mode}, socket) do
    current_path = socket.assigns[:url_path] || "/admin/document-creator"
    template_file_id = get_in(socket.assigns, [:modal_selected_template, "id"]) || ""
    existing_image_values = JSON.encode!(socket.assigns.modal_image_values)

    return_to =
      current_path <>
        "?" <>
        URI.encode_query(%{
          "picking_var" => var_name,
          "picking_mode" => mode,
          "template_file_id" => template_file_id,
          "picking_existing" => existing_image_values
        })

    mode_atom =
      case mode do
        "single" -> :single
        "multiple" -> :multiple
        _ -> :single
      end

    selector_url =
      MediaSelectorHelper.media_selector_url(return_to,
        mode: mode_atom,
        filter: :image
      )

    {:noreply, push_navigate(socket, to: selector_url)}
  end

  def handle_event(
        "update_variable_config",
        %{"variables" => vars_params} = _params,
        %{assigns: %{modal_selected_template: %{"id" => template_file_id}}} = socket
      )
      when is_map(vars_params) do
    result =
      Enum.reduce_while(vars_params, :ok, fn {var_name, %{"config" => config_params}}, :ok ->
        case Documents.update_template_variable_config(template_file_id, var_name, config_params) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        variables =
          template_file_id
          |> Documents.get_template_variables_from_db()
          |> Enum.map(&Map.from_struct/1)

        broadcast_files_changed()

        {:noreply, assign(socket, modal_variables: variables)}

      {:error, reason} ->
        Logger.warning("update_variable_config failed: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to save variable configuration. Please try again.")
         )}
    end
  end

  # Fallback when modal_selected_template isn't a map with "id" (defensive)
  def handle_event("update_variable_config", _params, socket), do: {:noreply, socket}

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
    text_values = Map.get(params, "var", %{})
    variable_values = Map.merge(text_values, socket.assigns.modal_image_values)

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

  def handle_event("dismiss_warning", _params, socket) do
    {:noreply, assign(socket, warning: nil)}
  end

  # ── Event helpers ──────────────────────────────────────────────────

  defp do_modal_select_template(socket, file_id, name) do
    variables =
      case Documents.detect_variables(file_id) do
        {:ok, fork} ->
          PhoenixKitDocumentCreator.Variable.build_definitions(fork)
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
    <div class="flex flex-col w-full px-4 py-6 gap-6">
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
        <%!-- Header action values, shared by the desktop button row and the
             mobile dropdown so the templates/documents branching lives once. --%>
        <% folder_url =
          if @live_action == :templates,
            do: templates_folder_url(),
            else: documents_folder_url() %>
        <% new_event = if @live_action == :templates, do: "new_template", else: "open_modal" %>
        <% new_label =
          if @live_action == :templates, do: gettext("New Template"), else: gettext("New Document") %>
        <% new_icon = if @live_action == :templates, do: "hero-plus", else: "hero-document-plus" %>
        <% new_busy =
          if @live_action == :templates, do: gettext("Creating…"), else: gettext("Opening…") %>
        <%!-- Header. Actions show inline on sm+; below sm they collapse into a
             single dropdown so the row can never force horizontal overflow. --%>
        <div class="flex items-center justify-between gap-2">
          <h1 class="text-2xl font-bold truncate">
            {if @live_action == :templates, do: gettext("Templates"), else: gettext("Documents")}
          </h1>

          <%!-- Desktop (sm+): inline buttons --%>
          <div class="hidden sm:flex items-center gap-2 flex-shrink-0">
            <button
              class="btn btn-ghost btn-sm"
              phx-click="refresh"
              disabled={@loading}
              phx-disable-with={gettext("Refreshing…")}
            >
              <span :if={@loading} class="loading loading-spinner loading-xs" />
              <span :if={not @loading} class="hero-arrow-path w-4 h-4" />
            </button>
            <a
              :if={folder_url}
              href={folder_url}
              target="_blank"
              class="btn btn-ghost btn-sm"
            >
              <span class="hero-folder-open w-4 h-4" /> {gettext("Open Folder")}
            </a>
            <button class="btn btn-primary btn-sm" phx-click={new_event} phx-disable-with={new_busy}>
              <span class={[new_icon, "w-4 h-4"]} /> {new_label}
            </button>
          </div>

          <%!-- Mobile (< sm): one dropdown holding every action --%>
          <div class="dropdown dropdown-end sm:hidden flex-shrink-0">
            <button type="button" tabindex="0" class="btn btn-ghost btn-sm btn-square">
              <span :if={@loading} class="loading loading-spinner loading-xs" />
              <span :if={not @loading} class="hero-ellipsis-vertical w-5 h-5" />
            </button>
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-100 rounded-box z-10 w-52 p-1 shadow-sm border border-base-200"
            >
              <li>
                <button
                  type="button"
                  phx-click="refresh"
                  disabled={@loading}
                  phx-disable-with={gettext("Refreshing…")}
                >
                  <span class="hero-arrow-path w-4 h-4" /> {gettext("Refresh")}
                </button>
              </li>
              <li :if={folder_url}>
                <a href={folder_url} target="_blank">
                  <span class="hero-folder-open w-4 h-4" /> {gettext("Open Folder")}
                </a>
              </li>
              <li>
                <button type="button" phx-click={new_event} phx-disable-with={new_busy}>
                  <span class={[new_icon, "w-4 h-4"]} /> {new_label}
                </button>
              </li>
            </ul>
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
        <% filter_cats = Taxonomy.list_categories() %>
        <% filter_types =
          case @filters["category"] do
            "" ->
              filter_cats
              |> Enum.flat_map(fn cat ->
                cat.uuid
                |> Taxonomy.list_types_for_category()
                |> Enum.map(&{&1.uuid, &1.name})
              end)

            cat_uuid ->
              cat_uuid
              |> Taxonomy.list_types_for_category()
              |> Enum.map(&{&1.uuid, &1.name})
          end %>
        <%!-- Toolbar. Stacks on mobile: status tabs + view toggle share a compact
             top line, filters (search full-width, selects wrapping) sit below.
             On lg+ the filters move up onto the same line as the tabs/toggle. --%>
        <div class={[
          "flex flex-col gap-2 lg:flex-row lg:flex-wrap lg:items-center",
          show_status_tabs && "border-b border-base-200 pb-2 lg:pb-0"
        ]}>
          <%!-- Status tabs (left) + view toggle (right) — always one compact row --%>
          <div class="flex items-center justify-between gap-2 lg:order-last">
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
              <%!-- Mobile-only toggle: reveals/hides the filter block below.
                   Hidden on sm+ where filters are always shown inline. --%>
              <button
                type="button"
                class={["btn btn-ghost btn-sm sm:hidden", @show_filters && "btn-active"]}
                phx-click="toggle_filters"
                aria-expanded={to_string(@show_filters)}
              >
                <span class="hero-funnel w-4 h-4" />
                {if @show_filters, do: gettext("Hide Filters"), else: gettext("Filters")}
              </button>
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
          <%!-- Filters: collapsed behind the "Filters" toggle below sm; always
               visible (search full-width then fixed; selects grow + wrap) on sm+. --%>
          <form
            phx-change="filter"
            class={[
              "flex-wrap items-center gap-2 lg:flex-1",
              if(@show_filters, do: "flex", else: "hidden sm:flex")
            ]}
          >
            <label class="input input-sm input-bordered w-full sm:w-72 md:w-80 shrink-0">
              <span class="hero-magnifying-glass w-4 h-4 opacity-60" />
              <input
                type="search"
                name="q"
                value={@filters["q"] || ""}
                phx-debounce="300"
                class="grow"
                placeholder={gettext("Search by name…")}
              />
            </label>
            <select name="category" class="select select-sm grow min-w-32 sm:grow-0">
              <option value="">{gettext("All Categories")}</option>
              <%= for cat <- filter_cats do %>
                <option value={cat.uuid} selected={@filters["category"] == cat.uuid}>
                  {cat.name}
                </option>
              <% end %>
            </select>
            <select name="type" class="select select-sm grow min-w-32 sm:grow-0">
              <option value="">{gettext("All Types")}</option>
              <%= for {uuid, name} <- filter_types do %>
                <option value={uuid} selected={@filters["type"] == uuid}>{name}</option>
              <% end %>
            </select>
            <%= if @live_action == :templates and @enabled_languages != [] do %>
              <select name="lang" class="select select-sm grow min-w-32 sm:grow-0">
                <option value="">{gettext("All Languages")}</option>
                <%= for lang <- @enabled_languages do %>
                  <option value={lang.code} selected={@filters["lang"] == lang.code}>
                    {lang.name}
                  </option>
                <% end %>
              </select>
            <% end %>
            <select name="sub_status" class="select select-sm grow min-w-32 sm:grow-0">
              <option value="">{gettext("All Statuses")}</option>
              <option value="published" selected={@filters["sub_status"] == "published"}>
                {gettext("Published")}
              </option>
              <option value="lost" selected={@filters["sub_status"] == "lost"}>
                {gettext("Lost")}
              </option>
              <option value="unfiled" selected={@filters["sub_status"] == "unfiled"}>
                {gettext("Unfiled")}
              </option>
            </select>
          </form>
        </div>

        <%!-- Warning --%>
        <div :if={@warning} class="alert alert-warning" phx-click="dismiss_warning">
          <span class="hero-exclamation-triangle w-5 h-5" />
          <span>{@warning}</span>
        </div>

        <%!-- Error --%>
        <div :if={@error} class="alert alert-error" phx-click="dismiss_error">
          <span class="hero-x-circle w-5 h-5" />
          <span>{@error}</span>
        </div>

        <%!-- Loading skeletons --%>
        <%= if @loading do %>
          <%= if @view_mode == "cards" do %>
            <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6 gap-3">
              <div
                :for={_ <- 1..5}
                class="flex flex-col animate-pulse skeleton"
                style="border: 1.5px solid oklch(var(--color-base-content) / 0.1); border-radius: 8px; overflow: hidden; padding-bottom: 12px;"
              >
                <div style="padding:16px 16px 24px 16px;display:flex;justify-content:center;">
                  <div
                    class="skeleton"
                    style="width:100%;max-width:183px;aspect-ratio:183/258;border-radius:4px;"
                  />
                </div>
                <div class="p-3 flex-1 flex flex-col gap-2">
                  <div class="skeleton h-4 rounded w-3/4" />
                  <div class="skeleton h-3 rounded w-1/2 mt-auto" />
                </div>
                <div class="flex gap-1 px-2 pb-2">
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
          <% filtered_files = filter_files(files_for_mode, @filters) %>
          <% total_count = length(filtered_files) %>
          <% total_pages = max(1, ceil(total_count / per_page())) %>
          <% current_page = min(@page, total_pages) %>
          <% paged_files =
            filtered_files
            |> Enum.drop((current_page - 1) * per_page())
            |> Enum.take(per_page()) %>
          <% list_base =
            if @live_action == :templates,
              do: PhoenixKitDocumentCreator.Paths.templates(),
              else: PhoenixKitDocumentCreator.Paths.documents() %>
          <% pagination_params =
            @filters
            |> Map.put("view", @view_mode)
            |> Map.put("status", @status_mode)
            |> Map.filter(fn {_k, v} -> v != "" end) %>
          {render_file_grid(assign_files(assigns, paged_files))}
          <.pagination
            current_page={current_page}
            total_pages={total_pages}
            base_path={list_base}
            params={pagination_params}
          />
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
      image_values={@modal_image_values}
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
    cats = Taxonomy.list_categories()
    cat_names = Map.new(cats, &{&1.uuid, &1.name})

    # category_options/0 includes the leading {nil, "No category"} entry;
    # drop the nil entry here so the template only loops over real options.
    cat_options =
      cats
      |> Enum.map(&{&1.uuid, &1.name})

    # types_by_category: %{category_uuid => [{type_uuid, type_name}, ...]}
    # Built once per grid render; each picker row reads from this map instead
    # of issuing its own query.
    types_by_category =
      Map.new(cats, fn cat ->
        options =
          cat.uuid
          |> Taxonomy.list_types_for_category()
          |> Enum.map(&{&1.uuid, &1.name})

        {cat.uuid, options}
      end)

    type_names =
      types_by_category
      |> Enum.flat_map(fn {_cat_uuid, opts} -> opts end)
      |> Map.new()

    %{
      files: files,
      view_mode: assigns.view_mode,
      status_mode: assigns.status_mode,
      pending_files: assigns.pending_files,
      thumbnails: assigns.thumbnails,
      is_template: assigns.live_action == :templates,
      enabled_languages: assigns.enabled_languages,
      category_names: cat_names,
      cat_options: cat_options,
      types_by_category: types_by_category,
      type_names: type_names,
      # Resolved off the render path when the trashed lists change; read here.
      deleted_by_names: assigns.deleted_by_names
    }
  end

  # Resolves the display names for everyone who trashed a currently-loaded file
  # and stashes them in assigns. Runs only on the two paths that load the
  # trashed lists (`:load_initial` and `:sync_from_drive`) — never per render —
  # so the user lookup is not repeated on every LiveView update. Resolves both
  # trashed lists at once so the map is correct regardless of which trash tab is
  # shown. (Optimistic delete/restore doesn't re-resolve: the optimistic file
  # map has no `data.deleted.by_uuid` yet — that's set server-side — so the name
  # only becomes resolvable after the follow-up sync.)
  defp assign_deleted_by_names(socket) do
    files = socket.assigns.trashed_templates ++ socket.assigns.trashed_documents
    assign(socket, deleted_by_names: build_deleted_by_names(files))
  end

  # Collect distinct by_uuid values from trashed files and resolve them to
  # display names in one query. Returns a %{uuid => display_name} map.
  defp build_deleted_by_names(files) do
    uuids = extract_deleted_by_uuids(files)

    case uuids do
      [] ->
        %{}

      _ ->
        uuids
        |> Auth.get_users_by_uuids()
        |> Map.new(&{&1.uuid, user_display_name(&1)})
    end
  end

  defp extract_deleted_by_uuids(files) do
    files
    |> Enum.flat_map(fn file ->
      case get_in(file, ["data", "deleted", "by_uuid"]) do
        nil -> []
        uuid -> [uuid]
      end
    end)
    |> Enum.uniq()
  end

  defp user_display_name(%{first_name: first, last_name: last})
       when is_binary(first) and first != "" and is_binary(last) and last != "",
       do: "#{first} #{last}"

  defp user_display_name(%{username: username})
       when is_binary(username) and username != "",
       do: username

  defp user_display_name(%{email: email})
       when is_binary(email) and email != "",
       do: email

  defp user_display_name(_), do: "unknown"

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

    <.table_default
      :if={@files != []}
      id="documents-table"
      items={@files}
      view_mode={if @view_mode == "cards", do: "card", else: "table"}
      show_toggle={false}
      variant="default"
      size="sm"
      wrapper_class="overflow-x-auto"
      card_class={
        fn file ->
          [
            # `[&_.card-body]:p-0` zeroes daisyUI's default `.card-body`
            # padding (1.5rem) directly on the nested element so the custom
            # px-3/pt-2/pb-1/pb-2 inside owns spacing — otherwise there's a
            # ~24px gap between the thumbnail and the title, and a matching
            # dead band below the action buttons. We deliberately target
            # `padding` on `.card-body` rather than overriding `--card-p`:
            # any daisyUI size variant (`card-sm`/`card-md`/…) re-sets
            # `--card-p` directly on `.card-body`, which would defeat an
            # `[--card-p:0]` set on the outer `.card`.
            "group flex flex-col card bg-base-100 relative [&_.card-body]:p-0",
            MapSet.member?(@pending_files, file["id"]) && "opacity-40 pointer-events-none"
          ]
          |> Enum.reject(&(&1 in [nil, false, ""]))
          |> Enum.join(" ")
        end
      }
      item_id={& &1["id"]}
      class="table-sm"
      card_grid_class="gap-3 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6"
    >
      <:card_media :let={file}>
        <div
          :if={MapSet.member?(@pending_files, file["id"])}
          class="absolute inset-0 z-10 flex items-center justify-center pointer-events-none"
        >
          <span class="loading loading-spinner loading-lg text-base-content opacity-100" />
        </div>
        <a
          href={GoogleDocsClient.get_edit_url(file["id"])}
          target="_blank"
          style="display:flex;justify-content:center;padding:8px 8px 8px 8px;background:oklch(var(--color-base-200));"
        >
          <.render_thumbnail thumbnail={@thumbnails[file["id"]]} />
        </a>
      </:card_media>
      <:card_body :let={file}>
        <div class="px-3 pt-2 pb-1 flex-1 flex flex-col">
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
                gettext("File exists in Drive but is outside the configured Document Creator folders")
              }
            >
              {gettext("unfiled")}
            </button>
          </div>
          <%!--
            Card view: language badge sits inline with the category picker
            when the column is wide enough (xl/2xl), and the picker wraps to
            its own row only when it can't fit — `basis-full` on the picker
            (via `layout="card"`) forces the wrap when needed. `min-w-0`
            propagates so the picker's inner `flex-1` selects can shrink
            under daisyUI's `.select` floor.
          --%>
          <div class="flex flex-wrap items-center gap-1 min-w-0">
            <.render_language_picker
              file={file}
              is_template={@is_template}
              enabled_languages={@enabled_languages}
              status_mode={@status_mode}
            />
            <.render_category_picker
              file={file}
              is_template={@is_template}
              status_mode={@status_mode}
              category_names={@category_names}
              cat_options={@cat_options}
              types_by_category={@types_by_category}
              type_names={@type_names}
              layout="card"
            />
          </div>
          <p :if={file["modifiedTime"]} class="text-xs text-base-content/40 mt-auto pt-2">
            {gettext("Updated:")} {format_time(file["modifiedTime"])}
          </p>
          <p :if={file["inserted_at"]} class="text-xs text-base-content/40 pt-0.5">
            {gettext("Created:")} {format_time(file["inserted_at"])}
          </p>
          <p :if={@status_mode == "trashed"} class="text-xs text-base-content/40 pt-1">
            <span class="hero-trash w-3 h-3 inline-block align-middle" />
            {format_deleted_info(file["data"]["deleted"], @deleted_by_names)}
          </p>
        </div>
        <div class="flex gap-1 px-2 pb-2">
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
      </:card_body>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
          <.table_default_header_cell :if={@status_mode == "trashed"}>
            {gettext("Deleted")}
          </.table_default_header_cell>
          <.table_default_header_cell>{gettext("Created")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Modified")}</.table_default_header_cell>
          <.table_default_header_cell class="text-right">
            {gettext("Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.table_default_body>
        <.table_default_row :for={file <- @files} hover={false} class="hover:bg-base-200/50">
          <%= if MapSet.member?(@pending_files, file["id"]) do %>
            <.table_default_cell
              colspan={if @status_mode == "trashed", do: 6, else: 5}
              class="text-center py-6"
            >
              <span class="loading loading-spinner loading-sm text-base-content/40" />
            </.table_default_cell>
          <% else %>
            <.table_default_cell>
              <div class="flex items-center gap-2">
                <a
                  href={GoogleDocsClient.get_edit_url(file["id"])}
                  target="_blank"
                  class="font-medium link link-hover"
                >
                  {file["name"]}
                </a>
                <.render_language_picker
                  file={file}
                  is_template={@is_template}
                  enabled_languages={@enabled_languages}
                  status_mode={@status_mode}
                />
                <.render_category_picker
                  file={file}
                  is_template={@is_template}
                  status_mode={@status_mode}
                  category_names={@category_names}
                  cat_options={@cat_options}
                  types_by_category={@types_by_category}
                  type_names={@type_names}
                  layout="inline"
                />
              </div>
            </.table_default_cell>
            <.table_default_cell>
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
            </.table_default_cell>
            <.table_default_cell
              :if={@status_mode == "trashed"}
              class="text-base-content/60 text-nowrap text-xs"
            >
              {format_deleted_info(file["data"]["deleted"], @deleted_by_names)}
            </.table_default_cell>
            <.table_default_cell class="text-base-content/60 text-nowrap text-xs">
              {format_time(file["inserted_at"])}
            </.table_default_cell>
            <.table_default_cell class="text-base-content/60 text-nowrap">
              {format_time(file["modifiedTime"])}
            </.table_default_cell>
            <.table_default_cell class="text-right">
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
            </.table_default_cell>
          <% end %>
        </.table_default_row>
      </.table_default_body>
    </.table_default>
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
  attr(:file, :map, required: true)
  attr(:is_template, :boolean, required: true)
  attr(:enabled_languages, :list, required: true)
  attr(:status_mode, :string, required: true)

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

  attr(:file, :map, required: true)
  attr(:is_template, :boolean, required: true)
  attr(:status_mode, :string, required: true)
  attr(:category_names, :map, required: true)
  attr(:cat_options, :list, required: true)
  attr(:types_by_category, :map, required: true)
  attr(:type_names, :map, required: true)

  attr(:layout, :string,
    default: "inline",
    values: ~w(inline card),
    doc: ~s(Layout variant: "inline" for the table row, "card" for the card grid.)
  )

  defp render_category_picker(assigns) do
    # Resolve display names from the precomputed lookup maps (no DB call per row).
    assigns =
      Map.merge(assigns, %{
        # Resolve the layout variant once; the template branches on `@card?`.
        card?: assigns.layout == "card",
        cat_name: assigns.category_names[assigns.file["category_uuid"]],
        type_name: assigns.type_names[assigns.file["type_uuid"]],
        # Types for the currently selected category (nil → empty list).
        type_options: Map.get(assigns.types_by_category, assigns.file["category_uuid"], [])
      })

    ~H"""
    <%!--
      Two layouts share this helper:
        • `layout="inline"` (default; used by the table-view row): the
          original intrinsic-width inline pair — selects size to content,
          no wrap, no flex-grow, so the file-name link beside them isn't
          pushed narrow.
        • `layout="card"`: the picker takes a full grid row inside the
          card body (`basis-full`), the two selects share that row via
          `flex-1` with `basis-28` (≈7rem), and they wrap onto a second
          row when the card column is too narrow to fit both side-by-side
          — daisyUI's native `.select` min-width otherwise clips the
          trailing option.
    --%>
    <div class={[
      "flex items-center gap-1 min-w-0",
      @card? && "flex-wrap basis-full w-full"
    ]}>
      <%= if @status_mode == "trashed" do %>
        <%!-- In trash view: read-only name badges --%>
        <span
          :if={@cat_name}
          class="badge badge-xs badge-secondary"
          title={gettext("Category")}
        >
          {@cat_name}
        </span>
        <span
          :if={@type_name}
          class="badge badge-xs badge-outline"
          title={gettext("Type")}
        >
          {@type_name}
        </span>
      <% else %>
        <%!--
          Active view: interactive selects sourced from precomputed options.
          Each <select> is wrapped in its own <form> — phx-change is a form
          binding, so a bare <select> outside a form does not serialize its
          value (only the phx-value-* attrs would arrive).
        --%>
        <form
          class={@card? && "min-w-0 flex-1 basis-28"}
          phx-change="set_taxonomy_category"
          phx-value-google_doc_id={@file["id"]}
          phx-value-kind={if @is_template, do: "template", else: "document"}
        >
          <select
            name="value"
            class={[
              "select select-bordered select-xs",
              @card? && "w-full"
            ]}
            title={gettext("Category")}
          >
            <option value="">{gettext("No category")}</option>
            <%= for {uuid, name} <- @cat_options do %>
              <option value={uuid} selected={@file["category_uuid"] == uuid}>{name}</option>
            <% end %>
          </select>
        </form>
        <%!-- Type select — only shown when a category is chosen --%>
        <form
          :if={@file["category_uuid"]}
          class={@card? && "min-w-0 flex-1 basis-28"}
          phx-change="set_taxonomy_type"
          phx-value-google_doc_id={@file["id"]}
          phx-value-kind={if @is_template, do: "template", else: "document"}
        >
          <select
            name="value"
            class={[
              "select select-bordered select-xs",
              @card? && "w-full"
            ]}
            title={gettext("Type")}
          >
            <option value="">{gettext("No type")}</option>
            <%= for {uuid, name} <- @type_options do %>
              <option value={uuid} selected={@file["type_uuid"] == uuid}>{name}</option>
            <% end %>
          </select>
        </form>
      <% end %>
    </div>
    """
  end

  attr(:thumbnail, :any, default: nil, doc: "Thumbnail URL, or nil while loading.")

  defp render_thumbnail(assigns) do
    ~H"""
    <div style="width:100%;max-width:183px;aspect-ratio:183/258;overflow:hidden;border-radius:4px;background:#fff;border:1px solid oklch(var(--color-base-content) / 0.2);box-shadow:0 2px 8px rgba(0,0,0,0.08);">
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

  defp per_page, do: @per_page

  defp list_base_path(%{assigns: %{live_action: :templates}}),
    do: PhoenixKitDocumentCreator.Paths.templates()

  defp list_base_path(_socket),
    do: PhoenixKitDocumentCreator.Paths.documents()

  defp list_path_with_params(socket, extra_params) do
    assigns = socket.assigns

    base_params = %{
      "view" => assigns.view_mode,
      "status" => assigns.status_mode,
      "page" => to_string(assigns.page),
      "q" => assigns.filters["q"],
      "category" => assigns.filters["category"],
      "type" => assigns.filters["type"],
      "lang" => assigns.filters["lang"],
      "sub_status" => assigns.filters["sub_status"]
    }

    params =
      base_params
      |> Map.merge(Map.new(extra_params, fn {k, v} -> {to_string(k), to_string(v)} end))
      |> Map.reject(fn {_k, v} -> v == "" or is_nil(v) end)

    base = list_base_path(socket)

    if params == %{} do
      base
    else
      "#{base}?#{URI.encode_query(params)}"
    end
  end

  defp filter_files(files, filters) do
    files
    |> then(fn f ->
      case filters["category"] do
        v when v in [nil, ""] -> f
        cat_uuid -> Enum.filter(f, &(&1["category_uuid"] == cat_uuid))
      end
    end)
    |> then(fn f ->
      case filters["type"] do
        v when v in [nil, ""] -> f
        type_uuid -> Enum.filter(f, &(&1["type_uuid"] == type_uuid))
      end
    end)
    |> then(fn f ->
      case filters["lang"] do
        v when v in [nil, ""] -> f
        lang -> Enum.filter(f, &(&1["language"] == lang))
      end
    end)
    |> then(fn f ->
      case filters["sub_status"] do
        v when v in [nil, ""] -> f
        status -> Enum.filter(f, &(&1["status"] == status))
      end
    end)
    |> filter_by_name(filters["q"])
  end

  defp filter_by_name(files, q) when q in [nil, ""], do: files

  defp filter_by_name(files, q) do
    q_lower = String.downcase(q)
    Enum.filter(files, &String.contains?(String.downcase(&1["name"] || ""), q_lower))
  end

  defp settings_path, do: PhoenixKitDocumentCreator.Paths.settings()
  defp templates_folder_url, do: Documents.templates_folder_url()
  defp documents_folder_url, do: Documents.documents_folder_url()

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  defp format_time(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y %H:%M")
      _ -> iso_string
    end
  end

  # Formats the "Deleted" display: "<date> · <display_name>" or "—" when
  # no deletion metadata is present.
  defp format_deleted_info(nil, _names), do: "—"

  defp format_deleted_info(%{"at" => at_iso} = deleted, names) do
    by_uuid = Map.get(deleted, "by_uuid")
    name = if by_uuid, do: Map.get(names, by_uuid, gettext("unknown")), else: gettext("unknown")

    formatted_at =
      case DateTime.from_iso8601(at_iso) do
        {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y %H:%M")
        _ -> at_iso
      end

    "#{formatted_at} · #{name}"
  end

  defp format_deleted_info(_deleted, _names), do: "—"

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

  defp patch_template_language(templates, file_id, new_language) do
    Enum.map(templates, fn t ->
      if t["id"] == file_id, do: Map.put(t, "language", new_language), else: t
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp apply_taxonomy_result(socket, {:ok, file_map}, _field) do
    patch_file_in_assigns(socket, file_map)
  end

  defp apply_taxonomy_result(socket, {:error, _reason}, :category) do
    assign(socket, error: gettext("Could not update category"))
  end

  defp apply_taxonomy_result(socket, {:error, _reason}, :type) do
    assign(socket, error: gettext("Could not update type"))
  end

  defp patch_file_in_assigns(socket, %{"id" => file_id} = file_map) do
    assigns = socket.assigns

    templates = patch_file_list(assigns.templates, file_id, file_map)
    documents = patch_file_list(assigns.documents, file_id, file_map)
    trashed_templates = patch_file_list(assigns.trashed_templates, file_id, file_map)
    trashed_documents = patch_file_list(assigns.trashed_documents, file_id, file_map)

    assign(socket,
      templates: templates,
      documents: documents,
      trashed_templates: trashed_templates,
      trashed_documents: trashed_documents
    )
  end

  defp patch_file_list(files, file_id, replacement) do
    Enum.map(files, fn f ->
      if f["id"] == file_id, do: Map.merge(f, replacement), else: f
    end)
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

  defp prior_image_values_from_json(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) ->
        map
        |> Enum.filter(fn {k, v} -> is_binary(k) and valid_image_value?(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp valid_image_value?(%{"media_id" => id}) when is_binary(id), do: true

  defp valid_image_value?(%{"media_ids" => ids}) when is_list(ids) do
    Enum.all?(ids, &is_binary/1)
  end

  defp valid_image_value?(_), do: false
end
