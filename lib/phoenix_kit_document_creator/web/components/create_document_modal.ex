defmodule PhoenixKitDocumentCreator.Web.Components.CreateDocumentModal do
  @moduledoc """
  Multi-step modal for creating documents.

  Step 1: Choose blank document or pick a template from Google Drive.
  Step 2: If template has variables, fill them in.
  Step 3: Create document and redirect to Google Docs.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  alias PhoenixKitDocumentCreator.Web.Components.VariableConfigForm

  attr(:open, :boolean, required: true)
  attr(:templates, :list, default: [])
  attr(:step, :string, default: "choose")
  attr(:selected_template, :any, default: nil)
  attr(:variables, :list, default: [])
  attr(:image_values, :map, default: %{})
  attr(:creating, :boolean, default: false)
  attr(:thumbnails, :map, default: %{})

  def modal(assigns) do
    ~H"""
    <div :if={@open} class="modal modal-open">
      <div class="modal-box max-w-lg">
        <%= case @step do %>
          <% "choose" -> %>
            {render_choose(assigns)}
          <% "variables" -> %>
            {render_variables(assigns)}
          <% _ -> %>
            {render_choose(assigns)}
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="modal_close"></div>
    </div>
    """
  end

  defp render_choose(assigns) do
    ~H"""
    <h3 class="font-bold text-lg">{gettext("Create New Document")}</h3>
    <p class="text-sm text-base-content/60 mt-1">{gettext("Start blank or choose a template.")}</p>

    <div class="mt-4 space-y-3">
      <%!-- Blank option --%>
      <button
        class="btn btn-outline btn-block justify-start gap-3"
        phx-click="modal_create_blank"
        phx-disable-with={gettext("Creating…")}
      >
        <span class="hero-document-plus w-5 h-5" />
        {gettext("Blank Document")}
      </button>

      <%!-- Templates --%>
      <div :if={@templates != []} class="divider text-xs text-base-content/40">{gettext("or from template")}</div>
      <div :if={@templates != []} class="flex flex-wrap gap-3 justify-center">
        <button
          :for={tpl <- @templates}
          class="card bg-base-100 shadow-sm h-auto flex-col items-center p-2 gap-1.5 cursor-pointer hover:bg-base-200 transition-colors"
          style="border: 1.5px solid currentColor; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.3); width: 130px;"
          phx-click="modal_select_template"
          phx-value-id={tpl["id"]}
          phx-value-name={tpl["name"]}
        >
          <div style="width:100px;height:141px;overflow:hidden;border-radius:4px;background:#fff;border:1px solid oklch(var(--color-base-content) / 0.2);box-shadow:0 2px 8px rgba(0,0,0,0.08);">
            <%= if @thumbnails[tpl["id"]] do %>
              <img src={@thumbnails[tpl["id"]]} style="width:100%;height:100%;object-fit:cover;object-position:top;" />
            <% else %>
              <div style="width:100%;height:100%;background:#fff;display:flex;align-items:center;justify-content:center;">
                <span class="loading loading-spinner loading-sm text-base-300" />
              </div>
            <% end %>
          </div>
          <span class="text-xs truncate max-w-full">{tpl["name"]}</span>
        </button>
      </div>
    </div>

    <div class="modal-action">
      <button class="btn btn-ghost btn-sm" phx-click="modal_close">{gettext("Cancel")}</button>
    </div>
    """
  end

  defp render_variables(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <button class="btn btn-ghost btn-sm btn-square" phx-click="modal_back">
        <span class="hero-arrow-left w-4 h-4" />
      </button>
      <div>
        <h3 class="font-bold text-lg">{gettext("Fill Template Variables")}</h3>
        <p class="text-sm text-base-content/60">{@selected_template["name"]}</p>
      </div>
    </div>

    <form phx-submit="modal_create_from_template" phx-change="update_variable_config" class="mt-4 space-y-3">
      <input type="hidden" name="template_id" value={@selected_template["id"]} />

      <div class="form-control">
        <label class="label py-1"><span class="label-text text-sm font-medium">{gettext("Document Name")}</span></label>
        <input
          type="text"
          name="doc_name"
          class="input input-bordered input-sm w-full"
          value={@selected_template["name"]}
        />
      </div>

      <div :for={var <- @variables} class="form-control">
        <label class="label py-1">
          <span class="label-text text-sm">{var[:label] || var["label"] || var[:name] || var["name"]}</span>
        </label>
        <%= case var[:type] || var["type"] do %>
          <% :multiline -> %>
            <textarea
              name={"var[#{var[:name] || var["name"]}]"}
              class="textarea textarea-bordered textarea-sm w-full"
              rows="3"
              placeholder={var[:name] || var["name"]}
            />
          <% :image -> %>
            {render_image_picker(assign(assigns, :var, var))}
            <VariableConfigForm.config_form variable={var} />
          <% :image_list -> %>
            {render_image_list_picker(assign(assigns, :var, var))}
            <VariableConfigForm.config_form variable={var} />
          <% _ -> %>
            <input
              type="text"
              name={"var[#{var[:name] || var["name"]}]"}
              class="input input-bordered input-sm w-full"
              placeholder={var[:name] || var["name"]}
            />
        <% end %>
      </div>

      <div class="modal-action">
        <button class="btn btn-ghost btn-sm" type="button" phx-click="modal_close">{gettext("Cancel")}</button>
        <button
          class="btn btn-primary btn-sm"
          type="submit"
          disabled={@creating}
          phx-disable-with={gettext("Creating…")}
        >
          <span :if={@creating} class="loading loading-spinner loading-xs" />
          {if @creating, do: gettext("Creating…"), else: gettext("Create Document")}
        </button>
      </div>
    </form>
    """
  end

  defp render_image_picker(assigns) do
    var_name = assigns.var[:name] || assigns.var["name"]

    selected =
      get_in(assigns.image_values, [var_name]) || get_in(assigns.image_values, ["#{var_name}"])

    assigns = assign(assigns, var_name: var_name, selected: selected)

    ~H"""
    <div class="flex items-center gap-2">
      <button
        type="button"
        class="btn btn-outline btn-sm"
        phx-click="open_media_picker"
        phx-value-name={@var_name}
        phx-value-mode="single"
      >
        <span class="hero-photo w-4 h-4" />
        {gettext("Choose image")}
      </button>
      <span :if={@selected} class="badge badge-success badge-sm">{gettext("selected")}</span>
    </div>
    """
  end

  defp render_image_list_picker(assigns) do
    var_name = assigns.var[:name] || assigns.var["name"]

    selected =
      get_in(assigns.image_values, [var_name]) || get_in(assigns.image_values, ["#{var_name}"])

    count = length((selected || %{})["media_ids"] || [])
    assigns = assign(assigns, var_name: var_name, count: count)

    ~H"""
    <div class="flex items-center gap-2">
      <button
        type="button"
        class="btn btn-outline btn-sm"
        phx-click="open_media_picker"
        phx-value-name={@var_name}
        phx-value-mode="multiple"
      >
        <span class="hero-photo w-4 h-4" />
        {gettext("Choose images")}
      </button>
      <span :if={@count > 0} class="badge badge-success badge-sm">{@count}</span>
    </div>
    """
  end
end
