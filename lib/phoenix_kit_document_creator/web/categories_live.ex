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
  alias PhoenixKitDocumentCreator.Paths
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Categories"),
       categories: [],
       selected: nil,
       types: [],
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
    category = Taxonomy.get_category!(uuid)

    {:noreply,
     socket
     |> assign(selected: category, types_trash: false)
     |> reload_types()}
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
    category = Taxonomy.get_category!(uuid)

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
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    category = Taxonomy.get_category!(uuid)

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
  end

  def handle_event("delete_category_forever", %{"uuid" => uuid}, socket) do
    category = Taxonomy.get_category!(uuid)

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
  end

  def handle_event("reorder_categories", %{"uuids" => uuids}, socket) when is_list(uuids) do
    Taxonomy.reorder_categories(uuids, Helpers.actor_opts(socket))
    {:noreply, reload_categories(socket)}
  end

  # ── Type events ────────────────────────────────────────────────────────────

  def handle_event("trash_type", %{"uuid" => uuid}, socket) do
    type = Taxonomy.get_type!(uuid)

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
  end

  def handle_event("restore_type", %{"uuid" => uuid}, socket) do
    type = Taxonomy.get_type!(uuid)

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
  end

  def handle_event("delete_type_forever", %{"uuid" => uuid}, socket) do
    type = Taxonomy.get_type!(uuid)

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
  end

  def handle_event("reorder_types", %{"uuids" => uuids}, socket) when is_list(uuids) do
    if socket.assigns.selected do
      Taxonomy.reorder_types(socket.assigns.selected.uuid, uuids, Helpers.actor_opts(socket))
    end

    {:noreply, reload_types(socket)}
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
            <ul class="flex flex-col gap-1">
              <%= if @categories == [] do %>
                <li class="text-sm text-base-content/50 py-4 text-center">
                  {if @categories_trash, do: gettext("No trashed categories."), else: gettext("No categories yet.")}
                </li>
              <% end %>
              <%= for cat <- @categories do %>
                <li class={"flex items-center justify-between px-2 py-1.5 rounded cursor-pointer hover:bg-base-200 #{if @selected && @selected.uuid == cat.uuid, do: "bg-base-200"}"}>
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

              <ul class="flex flex-col gap-1">
                <%= if @types == [] do %>
                  <li class="text-sm text-base-content/50 py-4 text-center">
                    {if @types_trash, do: gettext("No trashed types."), else: gettext("No types yet.")}
                  </li>
                <% end %>
                <%= for type <- @types do %>
                  <li class="flex items-center justify-between px-2 py-1.5 rounded hover:bg-base-200">
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

  # ── Private helpers ────────────────────────────────────────────────────────

  defp reload_categories(socket) do
    opts = if socket.assigns.categories_trash, do: [status: "deleted"], else: []
    assign(socket, categories: Taxonomy.list_categories(opts))
  end

  defp reload_types(socket) do
    case socket.assigns.selected do
      nil ->
        assign(socket, types: [])

      category ->
        opts = if socket.assigns.types_trash, do: [status: "deleted"], else: []
        assign(socket, types: Taxonomy.list_types_for_category(category.uuid, opts))
    end
  end
end
