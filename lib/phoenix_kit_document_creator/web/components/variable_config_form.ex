defmodule PhoenixKitDocumentCreator.Web.Components.VariableConfigForm do
  @moduledoc """
  Renders per-variable config fields for `:image` and `:image_list` variables.

  Emits `phx-change` events on the enclosing form so the parent LiveView can
  persist the updated config into the template's `variables` jsonb column.

  Non-image variable types render nothing.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  attr(:variable, :map, required: true)

  def config_form(%{variable: %{type: :image}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="form-control">
        <label class="label py-1">
          <span class="label-text text-sm">{gettext("Default width (px)")}</span>
        </label>
        <input
          type="number"
          name={"config[#{@variable.name}][default_width_px]"}
          class="input input-bordered input-sm w-full"
          value={@variable.config[:default_width_px] || @variable.config["default_width_px"]}
          min="1"
          phx-debounce="500"
        />
      </div>
    </div>
    """
  end

  def config_form(%{variable: %{type: :image_list}} = assigns) do
    current = assigns.variable.config[:separator] || assigns.variable.config["separator"]
    current_separator = if current, do: to_string(current), else: "newline"
    assigns = assign(assigns, :current_separator, current_separator)

    ~H"""
    <div class="space-y-2">
      <div class="form-control">
        <label class="label py-1">
          <span class="label-text text-sm">{gettext("Default width (px)")}</span>
        </label>
        <input
          type="number"
          name={"config[#{@variable.name}][default_width_px]"}
          class="input input-bordered input-sm w-full"
          value={@variable.config[:default_width_px] || @variable.config["default_width_px"]}
          min="1"
          phx-debounce="500"
        />
      </div>
      <div class="form-control">
        <label class="label py-1">
          <span class="label-text text-sm">{gettext("Separator")}</span>
        </label>
        <select
          name={"config[#{@variable.name}][separator]"}
          class="select select-bordered select-sm w-full"
        >
          <option value="newline" selected={@current_separator == "newline"}>{gettext("New line")}</option>
          <option value="space" selected={@current_separator == "space"}>{gettext("Space")}</option>
          <option value="none" selected={@current_separator == "none"}>{gettext("None")}</option>
        </select>
      </div>
      <div class="form-control">
        <label class="label py-1">
          <span class="label-text text-sm">{gettext("Max images (blank = unlimited)")}</span>
        </label>
        <input
          type="number"
          name={"config[#{@variable.name}][max_count]"}
          class="input input-bordered input-sm w-full"
          value={@variable.config[:max_count] || @variable.config["max_count"]}
          min="1"
          phx-debounce="500"
        />
      </div>
    </div>
    """
  end

  def config_form(assigns) do
    ~H""
  end
end
