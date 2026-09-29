defmodule PhoenixKitDocumentCreator.Web.CategoryFormLive do
  @moduledoc """
  New / edit form for a Document Creator Category.

  - New mode: navigates to `/admin/document-creator/categories/new`
  - Edit mode: navigates to `/admin/document-creator/categories/:uuid/edit`

  Danger zone (edit mode only) allows permanent deletion of the category.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Schemas.Category
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @translatable_fields ["name", "description"]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       category: nil,
       changeset: nil,
       form: nil,
       mode: :new
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
    # Read here (not in `mount/3`) so it runs after the parent app's
    # telemetry hook has synced the process-global Gettext locale.
    locale = Gettext.get_locale(PhoenixKitDocumentCreator.Gettext)

    socket =
      case params do
        %{"uuid" => uuid} ->
          category = Taxonomy.get_category!(uuid)
          changeset = Category.changeset(category, %{})

          socket
          |> assign(
            mode: :edit,
            category: category,
            changeset: changeset,
            form: to_form(changeset, as: :category),
            url_path: url_path
          )
          |> Helpers.assign_trail(gettext("Edit"), [
            Helpers.categories_crumb(),
            Helpers.record_crumb(category, locale)
          ])

        _ ->
          changeset = Category.changeset(%Category{}, %{})

          socket
          |> assign(
            mode: :new,
            category: %Category{},
            changeset: changeset,
            form: to_form(changeset, as: :category),
            url_path: url_path
          )
          |> Helpers.assign_trail(gettext("New category"), [Helpers.categories_crumb()])
      end

    {:noreply, refresh_multilang(socket)}
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    changeset =
      socket.assigns.category
      |> Category.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset, as: :category))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

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
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset, as: :category))}
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

      <.multilang_tabs
        :if={@multilang_enabled}
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
      />

      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body">
          <.form for={@form} id="category-form" phx-change="validate" phx-submit="save">
            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
            >
              <.translatable_field
                field_name="name"
                form_prefix="category"
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
                form_prefix="category"
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
                "Permanently deleting a category also deletes all its types. Templates and documents will lose their category assignment."
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
