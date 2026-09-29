defmodule PhoenixKitDocumentCreator.Web.CategoriesLive do
  @moduledoc """
  Admin list page for the Document Creator Category → Type hierarchy.

  Two-column layout: left column lists Categories, right column lists
  Types for the currently selected category. Each column has Active/Trash
  sub-tabs and row menus for Edit / Trash / Restore / Delete Forever.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    # Taxonomy events move templates between groups; :files_changed is what
    # trashing and restoring a template send when its status changes — both
    # move the template counts next to the types.
    if connected?(socket) do
      Taxonomy.subscribe()
      PhoenixKit.PubSubHelper.subscribe(Documents.pubsub_topic())
    end

    {:ok,
     assign(socket,
       categories: [],
       selected: nil,
       types: [],
       type_template_counts: %{},
       presets: [],
       categories_status_mode: "active",
       types_status_mode: "active",
       trashed_categories_count: 0,
       trashed_types_count: 0
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    url_path = URI.parse(uri).path || "/"

    socket =
      socket
      # Read after `mount/3` (not in it) so it runs after the parent app's
      # telemetry hook has synced the process-global Gettext locale.
      |> assign(url_path: url_path, locale: Gettext.get_locale(PhoenixKitDocumentCreator.Gettext))
      |> Helpers.assign_trail(gettext("Categories"))
      |> reload_categories()

    {:noreply, socket}
  end

  # ── Category events ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_category", %{"uuid" => uuid}, socket) do
    with_category(socket, uuid, fn category ->
      {:noreply,
       socket
       |> assign(selected: category, types_status_mode: "active")
       |> reload_types()}
    end)
  end

  def handle_event(
        "switch_status",
        %{"target" => "categories", "mode" => mode},
        socket
      )
      when mode in ["active", "trashed"] do
    {:noreply,
     socket
     |> assign(categories_status_mode: mode, selected: nil, types: [])
     |> reload_categories()}
  end

  def handle_event(
        "switch_status",
        %{"target" => "types", "mode" => mode},
        socket
      )
      when mode in ["active", "trashed"] do
    {:noreply,
     socket
     |> assign(types_status_mode: mode)
     |> reload_types()}
  end

  def handle_event("switch_status", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("trash_category", %{"uuid" => uuid}, socket) do
    with_category(socket, uuid, fn category ->
      case Taxonomy.trash_category(category, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Category trashed. Its types and templates have also been moved to trash.")
           )
           |> assign(selected: nil, types: [])
           |> reload_categories()}

        {:error, reason} ->
          Logger.error("trash_category failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not trash category."))}
      end
    end)
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with_category(socket, uuid, fn category ->
      case Taxonomy.restore_category(category, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Category restored."))
           |> reload_categories()}

        {:error, reason} ->
          Logger.error("restore_category failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not restore category."))}
      end
    end)
  end

  def handle_event("delete_category_forever", %{"uuid" => uuid}, socket) do
    with_category(socket, uuid, fn category ->
      case Taxonomy.permanently_delete_category(category, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Category permanently deleted."))
           |> assign(selected: nil, types: [])
           |> reload_categories()}

        {:error, reason} ->
          Logger.error("permanently_delete_category failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not delete category."))}
      end
    end)
  end

  def handle_event("reorder_categories", %{"ordered_ids" => uuids}, socket)
      when is_list(uuids) do
    socket =
      case Taxonomy.reorder_categories(uuids, Helpers.actor_opts(socket)) do
        :ok ->
          socket

        {:error, reason} ->
          Logger.error("reorder_categories failed: #{inspect(reason)}")
          put_flash(socket, :error, gettext("Could not reorder categories."))
      end

    {:noreply, reload_categories(socket)}
  end

  # ── Type events ────────────────────────────────────────────────────────────

  def handle_event("trash_type", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      case Taxonomy.trash_type(type, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Type trashed. Its templates have also been moved to trash.")
           )
           |> reload_types()}

        {:error, reason} ->
          Logger.error("trash_type failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not trash type."))}
      end
    end)
  end

  def handle_event("restore_type", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      case Taxonomy.restore_type(type, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Type restored."))
           |> reload_types()}

        {:error, reason} ->
          Logger.error("restore_type failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not restore type."))}
      end
    end)
  end

  def handle_event("delete_type_forever", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      case Taxonomy.permanently_delete_type(type, Helpers.actor_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Type permanently deleted."))
           |> reload_types()}

        {:error, reason} ->
          Logger.error("permanently_delete_type failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not delete type."))}
      end
    end)
  end

  def handle_event("reorder_types", %{"ordered_ids" => uuids}, socket)
      when is_list(uuids) do
    socket =
      if socket.assigns.selected do
        case Taxonomy.reorder_types(
               socket.assigns.selected.uuid,
               uuids,
               Helpers.actor_opts(socket)
             ) do
          :ok ->
            socket

          {:error, reason} ->
            Logger.error("reorder_types failed: #{inspect(reason)}")
            put_flash(socket, :error, gettext("Could not reorder types."))
        end
      else
        Logger.warning("reorder_types fired with no selected category — ignoring")
        socket
      end

    {:noreply, reload_types(socket)}
  end

  # Code seed for part А: create/reposition the 9 canonical ANDI groups under
  # the selected category, in order. Idempotent (see
  # `Taxonomy.ensure_default_group_order/2`).
  def handle_event("seed_default_groups", %{"uuid" => uuid}, socket) do
    socket =
      case Taxonomy.ensure_default_group_order(uuid, Helpers.actor_opts(socket)) do
        :ok ->
          put_flash(socket, :info, gettext("Standard groups added in order."))

        {:error, reason} ->
          Logger.error("seed_default_groups failed: #{inspect(reason)}")
          put_flash(socket, :error, gettext("Could not add the standard groups."))
      end

    {:noreply, reload_types(socket)}
  end

  # ── Preset events ─────────────────────────────────────────────────────────

  def handle_event("delete_preset", %{"uuid" => uuid}, socket) do
    case Documents.get_preset(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That preset no longer exists."))
         |> reload_presets()}

      preset ->
        case Documents.delete_preset(preset) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Preset deleted."))
             |> reload_presets()}

          {:error, reason} ->
            Logger.error("delete_preset failed: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, gettext("Could not delete preset."))}
        end
    end
  end

  # ── Taxonomy broadcasts ────────────────────────────────────────────────────

  @impl true
  def handle_info({:doc_taxonomy_changed, _level, _uuid}, socket) do
    {:noreply, reload_categories(socket)}
  end

  def handle_info({:files_changed, _from}, socket) do
    {:noreply, reload_types(socket)}
  end

  # The files topic is a public contract other code can broadcast on; a
  # message this page does not know must not crash it.
  def handle_info(msg, socket) do
    Logger.debug("DocumentCreator.CategoriesLive: ignoring unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">{gettext("Categories")}</h1>
      </div>

      <div class="grid grid-cols-2 gap-6">
        <%!-- Left: Categories column --%>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="card-title text-base">{gettext("Categories")}</h2>
              <a href={Routes.path("/admin/document-creator/categories/new")} class="btn btn-primary btn-xs">
                <span class="hero-plus w-3 h-3" /> {gettext("New")}
              </a>
            </div>

            <%!-- Active / Trash sub-tabs --%>
            <.status_subtabs
              target="categories"
              status_mode={@categories_status_mode}
              trashed_count={@trashed_categories_count}
            />

            <%!-- Category list --%>
            <ul
              id={"categories-sortable-#{@categories_status_mode}"}
              class="flex flex-col gap-1"
              phx-hook={@categories_status_mode == "active" && "SortableGrid"}
              data-sortable={@categories_status_mode == "active" && "true"}
              data-sortable-event="reorder_categories"
              data-sortable-items=".sortable-item"
              data-sortable-handle=".pk-drag-handle"
              data-sortable-hide-source="false"
            >
              <%= if @categories == [] do %>
                <li class="text-sm text-base-content/50 py-4 text-center">
                  {if @categories_status_mode == "trashed",
                    do: gettext("No trashed categories."),
                    else: gettext("No categories yet.")}
                </li>
              <% end %>
              <%= for cat <- @categories do %>
                <li
                  class={"sortable-item flex items-center gap-1 px-2 py-1.5 rounded cursor-pointer hover:bg-base-200 #{if @selected && @selected.uuid == cat.uuid, do: "bg-base-200"}"}
                  data-id={cat.uuid}
                >
                  <span
                    :if={@categories_status_mode == "active"}
                    class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/60 shrink-0"
                    title={gettext("Drag to reorder")}
                  >
                    <span class="hero-bars-3 w-4 h-4" />
                  </span>
                  <button
                    type="button"
                    phx-click="select_category"
                    phx-value-uuid={cat.uuid}
                    class="flex-1 text-left text-sm font-medium"
                  >
                    {Taxonomy.localized_name(cat, @locale)}
                  </button>
                  <.category_row_menu category={cat} trash_view={@categories_status_mode == "trashed"} />
                </li>
              <% end %>
            </ul>
          </div>
        </div>

        <%!-- Right: Types column --%>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="card-title text-base">
                {if @selected, do: Taxonomy.localized_name(@selected, @locale), else: gettext("Types")}
              </h2>
              <%= if @selected && @categories_status_mode == "active" do %>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="seed_default_groups"
                    phx-value-uuid={@selected.uuid}
                    data-confirm={
                      gettext(
                        "Create the standard ANDI groups (Hinnapakkumine … Hooldusjuhend) in this category, in order? Existing groups with these names are only repositioned."
                      )
                    }
                    class="btn btn-ghost btn-xs"
                    title={gettext("Seed the standard ANDI group order")}
                  >
                    <span class="hero-sparkles w-3 h-3" /> {gettext("Standard groups")}
                  </button>
                  <a
                    href={
                      Routes.path("/admin/document-creator/categories/#{@selected.uuid}/types/new")
                    }
                    class="btn btn-primary btn-xs"
                  >
                    <span class="hero-plus w-3 h-3" /> {gettext("New Type")}
                  </a>
                </div>
              <% end %>
            </div>

            <%= if @selected do %>
              <%!-- Active / Trash sub-tabs for types --%>
              <.status_subtabs
                target="types"
                status_mode={@types_status_mode}
                trashed_count={@trashed_types_count}
              />

              <ul
                id={"types-sortable-#{@types_status_mode}"}
                class="flex flex-col gap-1"
                phx-hook={@types_status_mode == "active" && "SortableGrid"}
                data-sortable={@types_status_mode == "active" && "true"}
                data-sortable-event="reorder_types"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                data-sortable-hide-source="false"
              >
                <%= if @types == [] do %>
                  <li class="text-sm text-base-content/50 py-4 text-center">
                    {if @types_status_mode == "trashed",
                      do: gettext("No trashed types."),
                      else: gettext("No types yet.")}
                  </li>
                <% end %>
                <%= for type <- @types do %>
                  <li
                    class="sortable-item flex items-center gap-1 px-2 py-1.5 rounded hover:bg-base-200"
                    data-id={type.uuid}
                  >
                    <span
                      :if={@types_status_mode == "active"}
                      class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/60 shrink-0"
                      title={gettext("Drag to reorder")}
                    >
                      <span class="hero-bars-3 w-4 h-4" />
                    </span>
                    <span class="flex-1 flex items-center gap-2">
                      <span class="text-sm font-medium">{Taxonomy.localized_name(type, @locale)}</span>
                      <span
                        :if={@types_status_mode == "active"}
                        id={"type-template-count-#{type.uuid}"}
                        class="badge badge-ghost badge-sm shrink-0"
                        title={template_count_label(@type_template_counts, type)}
                        role="img"
                        aria-label={template_count_label(@type_template_counts, type)}
                      >
                        {template_count(@type_template_counts, type)}
                      </span>
                    </span>
                    <.type_row_menu type={type} trash_view={@types_status_mode == "trashed"} />
                  </li>
                <% end %>
              </ul>
            <% else %>
              <p class="text-sm text-base-content/50 py-4 text-center">
                {gettext("Select a category to see its types.")}
              </p>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @selected && @categories_status_mode == "active" do %>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="card-title text-base">{gettext("Presets")}</h2>
              <a
                href={Routes.path("/admin/document-creator/categories/#{@selected.uuid}/presets/new")}
                class="btn btn-primary btn-xs"
              >
                <span class="hero-plus w-3 h-3" /> {gettext("New preset")}
              </a>
            </div>

            <%= if @presets == [] do %>
              <p class="text-sm text-base-content/50 py-4 text-center">
                {gettext("No presets for this category yet.")}
              </p>
            <% else %>
              <%= for {type_label, rows} <- group_presets_by_type(@presets, @types, @locale) do %>
                <h3 class="text-sm font-semibold text-base-content/70 mt-3 mb-1">{type_label}</h3>
                <ul class="flex flex-col gap-1">
                  <%= for %{preset: preset, stale: stale} <- rows do %>
                    <li class="flex items-center gap-2 px-2 py-1.5 rounded hover:bg-base-200">
                      <span class="flex-1 text-sm font-medium">{preset.name}</span>
                      <span
                        :if={stale.broken_count > 0}
                        class="badge badge-warning badge-sm gap-1"
                        title={gettext("Sections reference missing or trashed templates")}
                      >
                        <span class="hero-exclamation-triangle w-3 h-3" />
                        {ngettext(
                          "%{count} broken template",
                          "%{count} broken templates",
                          stale.broken_count,
                          count: stale.broken_count
                        )}
                      </span>
                      <span class="text-xs text-base-content/50">
                        {ngettext(
                          "%{count} section",
                          "%{count} sections",
                          length(preset.sections),
                          count: length(preset.sections)
                        )}
                      </span>
                      <.preset_row_menu preset={preset} />
                    </li>
                  <% end %>
                </ul>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Private components ─────────────────────────────────────────────────────

  attr(:target, :string, required: true)
  attr(:status_mode, :string, required: true)
  attr(:trashed_count, :integer, required: true)

  defp status_subtabs(assigns) do
    ~H"""
    <div :if={@trashed_count > 0 or @status_mode == "trashed"} class="flex mb-3 border-b border-base-200">
      <button
        type="button"
        phx-click="switch_status"
        phx-value-target={@target}
        phx-value-mode="active"
        class={"px-3 py-1 text-xs font-medium border-b-2 transition-colors whitespace-nowrap cursor-pointer #{if @status_mode == "active", do: "border-primary text-primary", else: "border-transparent text-base-content/50 hover:text-base-content"}"}
      >
        {gettext("Active")}
      </button>
      <button
        type="button"
        phx-click="switch_status"
        phx-value-target={@target}
        phx-value-mode="trashed"
        class={"px-3 py-1 text-xs font-medium border-b-2 transition-colors whitespace-nowrap cursor-pointer #{if @status_mode == "trashed", do: "border-error text-error", else: "border-transparent text-base-content/50 hover:text-base-content"}"}
      >
        {gettext("Trash")}
      </button>
    </div>
    """
  end

  defp category_row_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button type="button" tabindex="0" class="btn btn-ghost btn-xs">
        <span class="hero-ellipsis-horizontal w-4 h-4" />
      </button>
      <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-sm border border-base-200">
        <%= if not @trash_view do %>
          <li>
            <a href={Routes.path("/admin/document-creator/categories/#{@category.uuid}/edit")} class="text-xs">
              <span class="hero-pencil w-3 h-3" /> {gettext("Edit")}
            </a>
          </li>
          <li>
            <button type="button" phx-click="trash_category" phx-value-uuid={@category.uuid} class="text-xs text-warning">
              <span class="hero-trash w-3 h-3" /> {gettext("Trash")}
            </button>
          </li>
        <% else %>
          <li>
            <button type="button" phx-click="restore_category" phx-value-uuid={@category.uuid} class="text-xs text-success">
              <span class="hero-arrow-uturn-left w-3 h-3" /> {gettext("Restore")}
            </button>
          </li>
          <li>
            <button type="button" phx-click="delete_category_forever" phx-value-uuid={@category.uuid} class="text-xs text-error">
              <span class="hero-x-circle w-3 h-3" /> {gettext("Delete Forever")}
            </button>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp type_row_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button type="button" tabindex="0" class="btn btn-ghost btn-xs">
        <span class="hero-ellipsis-horizontal w-4 h-4" />
      </button>
      <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-sm border border-base-200">
        <%= if not @trash_view do %>
          <li>
            <a href={Routes.path("/admin/document-creator/types/#{@type.uuid}/edit")} class="text-xs">
              <span class="hero-pencil w-3 h-3" /> {gettext("Edit")}
            </a>
          </li>
          <li>
            <button type="button" phx-click="trash_type" phx-value-uuid={@type.uuid} class="text-xs text-warning">
              <span class="hero-trash w-3 h-3" /> {gettext("Trash")}
            </button>
          </li>
        <% else %>
          <li>
            <button type="button" phx-click="restore_type" phx-value-uuid={@type.uuid} class="text-xs text-success">
              <span class="hero-arrow-uturn-left w-3 h-3" /> {gettext("Restore")}
            </button>
          </li>
          <li>
            <button type="button" phx-click="delete_type_forever" phx-value-uuid={@type.uuid} class="text-xs text-error">
              <span class="hero-x-circle w-3 h-3" /> {gettext("Delete Forever")}
            </button>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp preset_row_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button type="button" tabindex="0" class="btn btn-ghost btn-xs">
        <span class="hero-ellipsis-horizontal w-4 h-4" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-sm border border-base-200"
      >
        <li>
          <a
            href={Routes.path("/admin/document-creator/presets/#{@preset.uuid}/edit")}
            class="text-xs"
          >
            <span class="hero-pencil w-3 h-3" /> {gettext("Edit")}
          </a>
        </li>
        <li>
          <button
            type="button"
            phx-click="delete_preset"
            phx-value-uuid={@preset.uuid}
            data-confirm={gettext("Delete this preset permanently?")}
            class="text-xs text-error"
          >
            <span class="hero-trash w-3 h-3" /> {gettext("Delete")}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Looks the category up by uuid and runs `fun` with it. If the row is gone
  # (e.g. another admin deleted it between render and click), flashes a notice
  # and reloads instead of letting a bang getter crash the LiveView.
  defp with_category(socket, uuid, fun) do
    case Taxonomy.get_category(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That category no longer exists."))
         |> reload_categories()}

      category ->
        fun.(category)
    end
  end

  defp with_type(socket, uuid, fun) do
    case Taxonomy.get_type(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That type no longer exists."))
         |> reload_types()}

      type ->
        fun.(type)
    end
  end

  defp reload_categories(socket) do
    status_mode = socket.assigns.categories_status_mode
    opts = if status_mode == "trashed", do: [status: "deleted"], else: []
    categories = Taxonomy.list_categories(opts)

    trashed_categories_count =
      if status_mode == "trashed",
        do: length(categories),
        else: Taxonomy.count_categories(status: "deleted")

    # Re-sync `selected` against the freshly-loaded list so the right-column
    # header does not drift after reorder, delete, or edit operations.
    selected =
      case socket.assigns.selected do
        nil -> nil
        %{uuid: uuid} -> Enum.find(categories, fn c -> c.uuid == uuid end)
      end

    socket
    |> assign(
      categories: categories,
      selected: selected,
      trashed_categories_count: trashed_categories_count
    )
    |> reload_types()
  end

  defp reload_types(socket) do
    socket =
      case socket.assigns.selected do
        nil ->
          assign(socket, types: [], type_template_counts: %{}, trashed_types_count: 0)

        category ->
          status_mode = socket.assigns.types_status_mode
          opts = if status_mode == "trashed", do: [status: "deleted"], else: []
          types = Taxonomy.list_types_for_category(category.uuid, opts)

          trashed_types_count =
            if status_mode == "trashed",
              do: length(types),
              else: Taxonomy.count_types_for_category(category.uuid, status: "deleted")

          # Only the active list shows counts: the trash lists types to
          # restore or delete, not ones in use.
          type_template_counts =
            if status_mode == "trashed",
              do: %{},
              else: Taxonomy.count_published_templates_by_type(Enum.map(types, & &1.uuid))

          assign(socket,
            types: types,
            type_template_counts: type_template_counts,
            trashed_types_count: trashed_types_count
          )
      end

    reload_presets(socket)
  end

  defp template_count(counts, type), do: Map.get(counts, type.uuid, 0)

  defp template_count_label(counts, type) do
    count = template_count(counts, type)
    ngettext("%{count} template", "%{count} templates", count, count: count)
  end

  defp reload_presets(socket) do
    case socket.assigns.selected do
      nil ->
        assign(socket, presets: [])

      category ->
        presets = Documents.list_presets(%{scope_id: category.uuid})
        stale = Documents.preset_stale_info_map(presets)

        rows =
          Enum.map(presets, fn preset ->
            %{preset: preset, stale: Map.fetch!(stale, preset.uuid)}
          end)

        assign(socket, presets: rows)
    end
  end

  # Groups preset rows by their `scope_type` (a Type uuid). Untyped presets
  # come last under a localized "Untyped" heading.
  defp group_presets_by_type(presets, types, locale) do
    type_name = Map.new(types, fn t -> {t.uuid, Taxonomy.localized_name(t, locale)} end)

    presets
    |> Enum.group_by(fn %{preset: p} -> p.scope_type end)
    |> Enum.map(fn {type_uuid, rows} ->
      label =
        if type_uuid,
          do: Map.get(type_name, type_uuid, gettext("Unknown type")),
          else: gettext("Untyped")

      sort_key = if type_uuid, do: {0, label}, else: {1, ""}
      {sort_key, label, rows}
    end)
    |> Enum.sort_by(fn {sort_key, _, _} -> sort_key end)
    |> Enum.map(fn {_, label, rows} -> {label, rows} end)
  end
end
