defmodule PhoenixKitDocumentCreator.Web.TypeFormLive do
  @moduledoc """
  New / edit form for a Document Creator Type.

  - New mode: navigates to `/admin/document-creator/categories/:category_uuid/types/new`
  - Edit mode: navigates to `/admin/document-creator/types/:uuid/edit`

  Includes a category `<select>` so the user can move the type to another
  category in edit mode. Danger zone (edit mode only) allows permanent deletion.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Schemas.Type
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Type"),
       type: nil,
       form: nil,
       mode: :new,
       categories: []
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_path = URI.parse(uri).path || "/"
    categories = Taxonomy.list_categories()

    socket =
      case params do
        %{"uuid" => uuid} ->
          type = Taxonomy.get_type!(uuid)

          socket
          |> assign(
            mode: :edit,
            type: type,
            form: to_form(Type.changeset(type, %{}), as: :type),
            page_title: gettext("Edit Type"),
            url_path: url_path,
            categories: categories
          )

        %{"category_uuid" => category_uuid} ->
          type = %Type{category_uuid: category_uuid}

          socket
          |> assign(
            mode: :new,
            type: type,
            form: to_form(Type.changeset(type, %{}), as: :type),
            page_title: gettext("New Type"),
            url_path: url_path,
            categories: categories
          )

        _ ->
          type = %Type{}

          socket
          |> assign(
            mode: :new,
            type: type,
            form: to_form(Type.changeset(type, %{}), as: :type),
            page_title: gettext("New Type"),
            url_path: url_path,
            categories: categories
          )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"type" => params}, socket) do
    changeset =
      socket.assigns.type
      |> Type.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :type))}
  end

  def handle_event("save", %{"type" => params}, socket) do
    result =
      case socket.assigns.mode do
        :new ->
          Taxonomy.create_type(params, Helpers.actor_opts(socket))

        :edit ->
          Taxonomy.update_type(socket.assigns.type, params, Helpers.actor_opts(socket))
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Type saved."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :type))}
    end
  end

  def handle_event("delete_forever", _params, socket) do
    type = socket.assigns.type

    case Taxonomy.permanently_delete_type(type, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Type permanently deleted."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, reason} ->
        Logger.error("permanently_delete_type failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Could not delete type."))}
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
          {if @mode == :new, do: gettext("New Type"), else: gettext("Edit Type")}
        </h1>
      </div>

      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body">
          <.form for={@form} phx-change="validate" phx-submit="save">
            <div class="form-control mb-4">
              <label class="label" for="type_name">
                <span class="label-text">{gettext("Name")}</span>
              </label>
              <input
                type="text"
                id="type_name"
                name={@form[:name].name}
                value={@form[:name].value}
                class={"input input-bordered input-sm #{if @form[:name].errors != [], do: "input-error"}"}
                phx-debounce="300"
              />
              <%= for {msg, _} <- @form[:name].errors do %>
                <p class="text-error text-xs mt-1">{msg}</p>
              <% end %>
            </div>

            <div class="form-control mb-4">
              <label class="label" for="type_description">
                <span class="label-text">{gettext("Description")}</span>
                <span class="label-text-alt text-base-content/50">{gettext("Optional")}</span>
              </label>
              <textarea
                id="type_description"
                name={@form[:description].name}
                class="textarea textarea-bordered textarea-sm"
                rows="3"
                phx-debounce="300"
              >{@form[:description].value}</textarea>
            </div>

            <div class="form-control mb-6">
              <label class="label" for="type_category_uuid">
                <span class="label-text">{gettext("Category")}</span>
              </label>
              <select
                id="type_category_uuid"
                name={@form[:category_uuid].name}
                class={"select select-bordered select-sm #{if @form[:category_uuid].errors != [], do: "select-error"}"}
              >
                <option value="">{gettext("Select a category")}</option>
                <%= for cat <- @categories do %>
                  <option
                    value={cat.uuid}
                    selected={to_string(@form[:category_uuid].value) == to_string(cat.uuid)}
                  >
                    {cat.name}
                  </option>
                <% end %>
              </select>
              <%= for {msg, _} <- @form[:category_uuid].errors do %>
                <p class="text-error text-xs mt-1">{msg}</p>
              <% end %>
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
              {gettext("Permanently deleting a type removes it from all templates and documents (FK set to NULL).")}
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
