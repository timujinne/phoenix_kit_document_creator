defmodule PhoenixKitDocumentCreator.Web.PresetFormLive do
  @moduledoc """
  New / edit form for a Document Creator template preset.

  - New mode: `/admin/document-creator/categories/:category_uuid/presets/new`
  - Edit mode: `/admin/document-creator/presets/:uuid/edit`

  The category is fixed; the type is chosen from the category's types. The
  section editor edits the `sections` JSONB array with add/remove/reorder and
  per-section variable default inputs.
  """
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.TemplatePreset
  alias PhoenixKitDocumentCreator.Taxonomy
  alias PhoenixKitDocumentCreator.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Preset"), mode: :new)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_path = URI.parse(uri).path || "/"

    socket =
      case params do
        %{"uuid" => uuid} ->
          preset = get_preset!(uuid)
          category = Taxonomy.get_category!(preset.scope_id)
          load(socket, :edit, preset, category, url_path)

        %{"category_uuid" => category_uuid} ->
          category = Taxonomy.get_category!(category_uuid)
          preset = %TemplatePreset{scope_id: category_uuid, sections: []}
          load(socket, :new, preset, category, url_path)
      end

    {:noreply, socket}
  end

  defp load(socket, mode, preset, category, url_path) do
    assign(socket,
      mode: mode,
      preset: preset,
      category: category,
      types: Taxonomy.list_types_for_category(category.uuid),
      templates: category_templates(category.uuid),
      sections: editor_sections(preset.sections),
      form: to_form(TemplatePreset.changeset(preset, %{}), as: :preset),
      page_title: if(mode == :new, do: gettext("New Preset"), else: gettext("Edit Preset")),
      url_path: url_path
    )
  end

  defp get_preset!(uuid) do
    case Documents.get_preset(uuid) do
      nil -> raise Ecto.NoResultsError, queryable: TemplatePreset
      preset -> preset
    end
  end

  @impl true
  def handle_event("validate", %{"preset" => params} = all, socket) do
    sections =
      case all["section"] do
        nil -> socket.assigns.sections
        section_params -> collect_sections(section_params, socket.assigns.sections)
      end

    changeset =
      socket.assigns.preset
      |> TemplatePreset.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :preset), sections: sections)}
  end

  def handle_event("save", %{"preset" => params} = all, socket) do
    params = build_params(Map.merge(params, %{"section" => all["section"]}), socket)

    result =
      case socket.assigns.mode do
        :new -> Documents.save_preset(params)
        :edit -> Documents.update_preset(socket.assigns.preset, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Preset saved."))
         |> push_navigate(to: Routes.path("/admin/document-creator/categories"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save preset."))
         |> assign(form: to_form(changeset, as: :preset))}
    end
  end

  def handle_event("add_section", _params, socket) do
    section = %{"template_uuid" => nil, "variable_values" => %{}, "image_params" => %{}}
    {:noreply, assign(socket, sections: socket.assigns.sections ++ [section])}
  end

  def handle_event("remove_section", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, sections: List.delete_at(socket.assigns.sections, index))}
  end

  def handle_event("reorder_sections", %{"ordered_ids" => ids}, socket) do
    by_index = Enum.with_index(socket.assigns.sections)

    # Match each client-supplied id to a section. Unknown/stale ids (e.g. a
    # drag landing after a remove_section) are skipped rather than crashing.
    matched = Enum.flat_map(ids, &match_section_by_id(by_index, &1))

    # Append any sections the client never referenced so none are dropped.
    used = MapSet.new(matched, fn {_s, i} -> i end)
    leftover = Enum.reject(by_index, fn {_s, i} -> MapSet.member?(used, i) end)

    reordered = Enum.map(matched ++ leftover, fn {section, _i} -> section end)

    {:noreply, assign(socket, sections: reordered)}
  end

  # Match a client-supplied id to a {section, index} pair. Unknown/stale ids
  # (e.g. a drag landing after a remove_section) yield [] rather than crashing.
  defp match_section_by_id(by_index, id) do
    case Enum.find(by_index, fn {_s, i} -> Integer.to_string(i) == id end) do
      {_section, _i} = pair -> [pair]
      nil -> []
    end
  end

  # Forces the scoping + actor fields the form must not control directly.
  defp build_params(params, socket) do
    type_uuid = blank_to_nil(params["scope_type"])
    sections = collect_sections(params["section"], socket.assigns.sections)

    params
    |> Map.drop(["section"])
    |> Map.put("sections", sections)
    |> Map.put("scope_id", socket.assigns.category.uuid)
    |> Map.put("scope_type", type_uuid)
    |> Map.put_new(
      "created_by_uuid",
      socket.assigns.preset.created_by_uuid || Helpers.actor_uuid(socket)
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Merges submitted per-section attrs with socket section state,
  # assigning position by current order.
  defp collect_sections(nil, _state), do: []

  defp collect_sections(section_params, _state) do
    section_params
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.with_index()
    |> Enum.map(fn {{_index, attrs}, position} ->
      %{
        "template_uuid" => blank_to_nil(attrs["template_uuid"]),
        "position" => position,
        "variable_values" => attrs["variable_values"] || %{},
        "image_params" => attrs["image_params"] || %{}
      }
    end)
  end

  # Normalizes stored section maps (string keys) into editor rows.
  defp editor_sections(sections) when is_list(sections) do
    sections
    |> Enum.sort_by(&Map.get(&1, "position", 0))
    |> Enum.map(fn s ->
      %{
        "template_uuid" => Map.get(s, "template_uuid"),
        "variable_values" => Map.get(s, "variable_values", %{}),
        "image_params" => Map.get(s, "image_params", %{})
      }
    end)
  end

  defp editor_sections(_), do: []

  # Templates selectable for this preset's category (full schema structs).
  defp category_templates(category_uuid) do
    Documents.list_templates_for_category(category_uuid)
  end

  defp section_variables(section, templates) do
    case Enum.find(templates, &(&1.uuid == section["template_uuid"])) do
      nil -> []
      template -> template.variables || []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <h1 class="text-2xl font-bold">
        {if @mode == :new, do: gettext("New Preset"), else: gettext("Edit Preset")}
      </h1>
      <p class="text-sm text-base-content/60">
        {gettext("Category")}: <span class="font-medium">{@category.name}</span>
      </p>

      <.form for={@form} phx-change="validate" phx-submit="save" class="flex flex-col gap-4">
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Name")}
          class="input-sm"
          phx-debounce="300"
        />

        <.textarea
          field={@form[:description]}
          label={gettext("Description")}
          class="textarea-sm"
          rows="3"
          phx-debounce="300"
        />

        <.select
          field={@form[:scope_type]}
          label={gettext("Document type")}
          options={Enum.map(@types, &{&1.name, &1.uuid})}
          prompt={gettext("Untyped")}
          class="select-sm"
        />

        <div class="form-control">
          <div class="flex items-center justify-between">
            <span class="label-text font-medium">{gettext("Sections")}</span>
            <button type="button" phx-click="add_section" class="btn btn-xs btn-ghost">
              <span class="hero-plus w-3 h-3" /> {gettext("Add section")}
            </button>
          </div>

          <ul
            id="preset-sections-sortable"
            class="flex flex-col gap-2 mt-2"
            phx-hook="SortableGrid"
            data-sortable="true"
            data-sortable-event="reorder_sections"
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
            data-sortable-hide-source="false"
          >
            <%= for {section, index} <- Enum.with_index(@sections) do %>
              <li
                class="sortable-item flex flex-col gap-2 p-2 border border-base-200 rounded"
                data-id={index}
              >
                <div class="flex items-center gap-2 w-full">
                  <span class="pk-drag-handle cursor-grab text-base-content/30">
                    <span class="hero-bars-3 w-4 h-4" />
                  </span>
                  <select
                    name={"section[#{index}][template_uuid]"}
                    class="select select-bordered select-sm flex-1"
                  >
                    <option value="">{gettext("— pick a template —")}</option>
                    <%= for tmpl <- @templates do %>
                      <option value={tmpl.uuid} selected={section["template_uuid"] == tmpl.uuid}>
                        {tmpl.name}
                      </option>
                    <% end %>
                    <option
                      :if={
                        section["template_uuid"] &&
                          !Enum.any?(@templates, &(&1.uuid == section["template_uuid"]))
                      }
                      value={section["template_uuid"]}
                      selected
                    >
                      {gettext("(missing or trashed template)")}
                    </option>
                  </select>
                  <span
                    :if={
                      section["template_uuid"] &&
                        !Enum.any?(@templates, &(&1.uuid == section["template_uuid"]))
                    }
                    class="text-warning text-xs"
                    title={gettext("Template missing or trashed")}
                  >
                    <span class="hero-exclamation-triangle w-4 h-4" />
                  </span>
                  <button
                    type="button"
                    phx-click="remove_section"
                    phx-value-index={index}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    <span class="hero-x-mark w-4 h-4" />
                  </button>
                </div>
                <div class="flex flex-col gap-1 w-full">
                  <%= for var <- section_variables(section, @templates) do %>
                    <% vname = var["name"] || var[:name] %>
                    <label class="text-xs flex flex-col gap-0.5">
                      <span class="text-base-content/60">{vname}</span>
                      <input
                        type="text"
                        name={"section[#{index}][variable_values][#{vname}]"}
                        value={Map.get(section["variable_values"] || %{}, vname, "")}
                        class="input input-bordered input-xs"
                      />
                    </label>
                  <% end %>
                </div>
              </li>
            <% end %>
          </ul>
        </div>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          <a href={Routes.path("/admin/document-creator/categories")} class="btn btn-ghost">
            {gettext("Cancel")}
          </a>
        </div>
      </.form>
    </div>
    """
  end
end
