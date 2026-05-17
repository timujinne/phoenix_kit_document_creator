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
    if connected?(socket), do: Taxonomy.subscribe()

    {:ok,
     assign(socket,
       page_title: gettext("Categories"),
       categories: [],
       selected: nil,
       types: [],
       presets: [],
       categories_trash: false,
       types_trash: false
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    url_path = URI.parse(uri).path || "/"

    socket =
      socket
      |> assign(url_path: url_path)
      |> reload_categories()

    {:noreply, socket}
  end

  # ── Category events ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_category", %{"uuid" => uuid}, socket) do
    with_category(socket, uuid, fn category ->
      {:noreply,
       socket
       |> assign(selected: category, types_trash: false)
       |> reload_types()}
    end)
  end

  def handle_event("toggle_categories_trash", _params, socket) do
    trash = !socket.assigns.categories_trash

    {:noreply,
     socket
     |> assign(categories_trash: trash, selected: nil, types: [])
     |> reload_categories()}
  end

  def handle_event("toggle_types_trash", _params, socket) do
    trash = !socket.assigns.types_trash

    {:noreply,
     socket
     |> assign(types_trash: trash)
     |> reload_types()}
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
            <div class="flex gap-1 mb-3 border-b border-base-200">
              <button
                type="button"
                phx-click="toggle_categories_trash"
                class={"btn btn-ghost btn-xs pb-2 rounded-none border-b-2 #{if not @categories_trash, do: "border-primary text-primary", else: "border-transparent"}"}
              >
                {gettext("Active")}
              </button>
              <button
                type="button"
                phx-click="toggle_categories_trash"
                class={"btn btn-ghost btn-xs pb-2 rounded-none border-b-2 #{if @categories_trash, do: "border-primary text-primary", else: "border-transparent"}"}
              >
                {gettext("Trash")}
              </button>
            </div>

            <%!-- Category list --%>
            <ul
              id={"categories-sortable-#{@categories_trash}"}
              class="flex flex-col gap-1"
              phx-hook={!@categories_trash && "SortableGrid"}
              data-sortable={!@categories_trash && "true"}
              data-sortable-event="reorder_categories"
              data-sortable-items=".sortable-item"
              data-sortable-handle=".pk-drag-handle"
              data-sortable-hide-source="false"
            >
              <%= if @categories == [] do %>
                <li class="text-sm text-base-content/50 py-4 text-center">
                  {if @categories_trash, do: gettext("No trashed categories."), else: gettext("No categories yet.")}
                </li>
              <% end %>
              <%= for cat <- @categories do %>
                <li
                  class={"sortable-item flex items-center gap-1 px-2 py-1.5 rounded cursor-pointer hover:bg-base-200 #{if @selected && @selected.uuid == cat.uuid, do: "bg-base-200"}"}
                  data-id={cat.uuid}
                >
                  <span
                    :if={not @categories_trash}
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
                    {cat.name}
                  </button>
                  <.category_row_menu category={cat} trash_view={@categories_trash} />
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
                {if @selected, do: @selected.name, else: gettext("Types")}
              </h2>
              <%= if @selected && not @categories_trash do %>
                <a
                  href={Routes.path("/admin/document-creator/categories/#{@selected.uuid}/types/new")}
                  class="btn btn-primary btn-xs"
                >
                  <span class="hero-plus w-3 h-3" /> {gettext("New Type")}
                </a>
              <% end %>
            </div>

            <%= if @selected do %>
              <%!-- Active / Trash sub-tabs for types --%>
              <div class="flex gap-1 mb-3 border-b border-base-200">
                <button
                  type="button"
                  phx-click="toggle_types_trash"
                  class={"btn btn-ghost btn-xs pb-2 rounded-none border-b-2 #{if not @types_trash, do: "border-primary text-primary", else: "border-transparent"}"}
                >
                  {gettext("Active")}
                </button>
                <button
                  type="button"
                  phx-click="toggle_types_trash"
                  class={"btn btn-ghost btn-xs pb-2 rounded-none border-b-2 #{if @types_trash, do: "border-primary text-primary", else: "border-transparent"}"}
                >
                  {gettext("Trash")}
                </button>
              </div>

              <ul
                id={"types-sortable-#{@types_trash}"}
                class="flex flex-col gap-1"
                phx-hook={!@types_trash && "SortableGrid"}
                data-sortable={!@types_trash && "true"}
                data-sortable-event="reorder_types"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                data-sortable-hide-source="false"
              >
                <%= if @types == [] do %>
                  <li class="text-sm text-base-content/50 py-4 text-center">
                    {if @types_trash, do: gettext("No trashed types."), else: gettext("No types yet.")}
                  </li>
                <% end %>
                <%= for type <- @types do %>
                  <li
                    class="sortable-item flex items-center gap-1 px-2 py-1.5 rounded hover:bg-base-200"
                    data-id={type.uuid}
                  >
                    <span
                      :if={not @types_trash}
                      class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/60 shrink-0"
                      title={gettext("Drag to reorder")}
                    >
                      <span class="hero-bars-3 w-4 h-4" />
                    </span>
                    <span class="flex-1 text-sm font-medium">{type.name}</span>
                    <.type_row_menu type={type} trash_view={@types_trash} />
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

      <%= if @selected and not @categories_trash do %>
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
              <%= for {type_label, rows} <- group_presets_by_type(@presets, @types) do %>
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
    opts = if socket.assigns.categories_trash, do: [status: "deleted"], else: []
    categories = Taxonomy.list_categories(opts)

    # Re-sync `selected` against the freshly-loaded list so the right-column
    # header does not drift after reorder, delete, or edit operations.
    selected =
      case socket.assigns.selected do
        nil -> nil
        %{uuid: uuid} -> Enum.find(categories, fn c -> c.uuid == uuid end)
      end

    socket
    |> assign(categories: categories, selected: selected)
    |> reload_types()
  end

  defp reload_types(socket) do
    socket =
      case socket.assigns.selected do
        nil ->
          assign(socket, types: [])

        category ->
          opts = if socket.assigns.types_trash, do: [status: "deleted"], else: []
          assign(socket, types: Taxonomy.list_types_for_category(category.uuid, opts))
      end

    reload_presets(socket)
  end

  defp reload_presets(socket) do
    case socket.assigns.selected do
      nil ->
        assign(socket, presets: [])

      category ->
        presets =
          %{scope_id: category.uuid}
          |> Documents.list_presets()
          |> Enum.map(fn preset ->
            %{preset: preset, stale: Documents.preset_stale_info(preset)}
          end)

        assign(socket, presets: presets)
    end
  end

  # Groups preset rows by their `scope_type` (a Type uuid). Untyped presets
  # come last under a localized "Untyped" heading.
  defp group_presets_by_type(presets, types) do
    type_name = Map.new(types, fn t -> {t.uuid, t.name} end)

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
