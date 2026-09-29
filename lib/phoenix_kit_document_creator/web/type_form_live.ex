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

  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Schemas.Type
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @translatable_fields ["name", "description"]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       type: nil,
       changeset: nil,
       form: nil,
       mode: :new,
       categories: []
     )
     |> mount_multilang(open_on: open_on(params))}
  end

  # An edit opens on the language the admin is viewing the page in; a new
  # record starts on the main language, which holds its required fields.
  defp open_on(%{"uuid" => _}), do: :viewing_language
  defp open_on(_params), do: :primary

  @impl true
  def handle_params(params, uri, socket) do
    url_path = URI.parse(uri).path || "/"
    categories = Taxonomy.list_categories()
    # Read here (not in `mount/3`) so it runs after the parent app's
    # telemetry hook has synced the process-global Gettext locale.
    locale = Gettext.get_locale(PhoenixKitDocumentCreator.Gettext)

    socket =
      case params do
        %{"uuid" => uuid} ->
          type = Taxonomy.get_type!(uuid)
          changeset = Type.changeset(type, %{})

          socket
          |> assign(
            mode: :edit,
            type: type,
            changeset: changeset,
            form: to_form(changeset, as: :type),
            url_path: url_path,
            categories: categories
          )
          |> Helpers.assign_trail(
            gettext("Edit"),
            trail_crumbs(categories, type.category_uuid, locale) ++
              [Helpers.record_crumb(type, locale)]
          )

        %{"category_uuid" => category_uuid} ->
          type = %Type{category_uuid: category_uuid}
          changeset = Type.changeset(type, %{})

          socket
          |> assign(
            mode: :new,
            type: type,
            changeset: changeset,
            form: to_form(changeset, as: :type),
            url_path: url_path,
            categories: categories
          )
          |> Helpers.assign_trail(
            gettext("New type"),
            trail_crumbs(categories, category_uuid, locale)
          )

        _ ->
          type = %Type{}
          changeset = Type.changeset(type, %{})

          socket
          |> assign(
            mode: :new,
            type: type,
            changeset: changeset,
            form: to_form(changeset, as: :type),
            url_path: url_path,
            categories: categories
          )
          |> Helpers.assign_trail(gettext("New type"), [Helpers.categories_crumb()])
      end

    {:noreply, refresh_multilang(socket)}
  end

  # `Categories / <category>` — the category is text because the list is
  # its only page; a type whose category is gone shows the list alone.
  defp trail_crumbs(categories, category_uuid, locale) do
    case Enum.find(categories, &(&1.uuid == category_uuid)) do
      nil -> [Helpers.categories_crumb()]
      category -> [Helpers.categories_crumb(), Helpers.record_crumb(category, locale)]
    end
  end

  @impl true
  def handle_event("validate", %{"type" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    changeset =
      socket.assigns.type
      |> Type.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset, as: :type))}
  end

  def handle_event("save", %{"type" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

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
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset, as: :type))}
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

      <.multilang_tabs
        :if={@multilang_enabled}
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
      />

      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body">
          <.form for={@form} id="type-form" phx-change="validate" phx-submit="save">
            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
            >
              <.translatable_field
                field_name="name"
                form_prefix="type"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={get_lang_data(@changeset, @current_lang, @multilang_enabled)}
                label={gettext("Name")}
                class="input-sm"
                required
              />

              <.translatable_field
                field_name="description"
                form_prefix="type"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={get_lang_data(@changeset, @current_lang, @multilang_enabled)}
                label={gettext("Description")}
                type="textarea"
                rows={3}
              />
            </.multilang_fields_wrapper>

            <div class="mb-6">
              <.select
                field={@form[:category_uuid]}
                label={gettext("Category")}
                options={
                  Enum.map(
                    @categories,
                    &{Taxonomy.localized_name(&1, Gettext.get_locale(PhoenixKitDocumentCreator.Gettext)),
                     &1.uuid}
                  )
                }
                prompt={gettext("Select a category")}
                class="select-sm"
              />
            </div>

            <div class="flex gap-2 justify-end">
              <a href={Routes.path("/admin/document-creator/categories")} class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </a>
              <button
                type="submit"
                class="btn btn-primary btn-sm"
                phx-disable-with={gettext("Saving…")}
              >
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
              {gettext(
                "Permanently deleting a type removes it from all templates and documents (FK set to NULL)."
              )}
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
