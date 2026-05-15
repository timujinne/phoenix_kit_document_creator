defmodule PhoenixKitDocumentCreator.Web.CategoryFormLive do
  @moduledoc """
  New / edit form for a Document Creator Category.

  - New mode: navigates to `/admin/document-creator/categories/new`
  - Edit mode: navigates to `/admin/document-creator/categories/:uuid/edit`

  Danger zone (edit mode only) allows permanent deletion of the category.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Schemas.Category
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Category"),
       category: nil,
       form: nil,
       mode: :new
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_path = URI.parse(uri).path || "/"

    socket =
      case params do
        %{"uuid" => uuid} ->
          category = Taxonomy.get_category!(uuid)

          socket
          |> assign(
            mode: :edit,
            category: category,
            form: to_form(Category.changeset(category, %{}), as: :category),
            page_title: gettext("Edit Category"),
            url_path: url_path
          )

        _ ->
          socket
          |> assign(
            mode: :new,
            category: %Category{},
            form: to_form(Category.changeset(%Category{}, %{}), as: :category),
            page_title: gettext("New Category"),
            url_path: url_path
          )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    changeset =
      socket.assigns.category
      |> Category.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :category))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    result =
      case socket.assigns.mode do
        :new ->
          Taxonomy.create_category(params, Helpers.actor_opts(socket))

        :edit ->
          Taxonomy.update_category(socket.assigns.category, params, Helpers.actor_opts(socket))
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Category saved."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :category))}
    end
  end

  def handle_event("delete_forever", _params, socket) do
    category = socket.assigns.category

    case Taxonomy.permanently_delete_category(category, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Category permanently deleted."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, reason} ->
        Logger.error("permanently_delete_category failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Could not delete category."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-6">
      <div class="flex items-center gap-3">
        <a href={Routes.path("/admin/document-creator/categories")} class="btn btn-ghost btn-sm">
          <span class="hero-arrow-left w-4 h-4" />
        </a>
        <h1 class="text-2xl font-bold">
          {if @mode == :new, do: gettext("New Category"), else: gettext("Edit Category")}
        </h1>
      </div>

      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body">
          <.form for={@form} phx-change="validate" phx-submit="save">
            <div class="form-control mb-4">
              <label class="label" for="category_name">
                <span class="label-text">{gettext("Name")}</span>
              </label>
              <input
                type="text"
                id="category_name"
                name={@form[:name].name}
                value={@form[:name].value}
                class={"input input-bordered input-sm #{if @form[:name].errors != [], do: "input-error"}"}
                phx-debounce="300"
              />
              <%= for {msg, _} <- @form[:name].errors do %>
                <p class="text-error text-xs mt-1">{msg}</p>
              <% end %>
            </div>

            <div class="form-control mb-6">
              <label class="label" for="category_description">
                <span class="label-text">{gettext("Description")}</span>
                <span class="label-text-alt text-base-content/50">{gettext("Optional")}</span>
              </label>
              <textarea
                id="category_description"
                name={@form[:description].name}
                class="textarea textarea-bordered textarea-sm"
                rows="3"
                phx-debounce="300"
              >{@form[:description].value}</textarea>
            </div>

            <div class="flex gap-2 justify-end">
              <a href={Routes.path("/admin/document-creator/categories")} class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </a>
              <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
                {gettext("Save")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Danger zone (edit mode only) --%>
      <%= if @mode == :edit do %>
        <div class="card bg-base-100 shadow-sm border border-error/30">
          <div class="card-body">
            <h3 class="card-title text-error text-base">{gettext("Danger Zone")}</h3>
            <p class="text-sm text-base-content/70">
              {gettext("Permanently deleting a category also deletes all its types. Templates and documents will lose their category assignment.")}
            </p>
            <div class="card-actions mt-2">
              <button
                type="button"
                phx-click="delete_forever"
                class="btn btn-error btn-sm"
                data-confirm={gettext("Are you sure? This cannot be undone.")}
              >
                <span class="hero-trash w-4 h-4" /> {gettext("Delete Forever")}
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
