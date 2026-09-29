defmodule PhoenixKitDocumentCreator.Web.Components.VariableConfigForm do
  @moduledoc """
  Renders per-variable config fields for `:image` and `:image_list` variables.

  Emits `phx-change` events on the enclosing form so the parent LiveView can
  persist the updated config into the template's `variables` jsonb column.

  Non-image variable types render nothing.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  alias PhoenixKitDocumentCreator.Variable

  attr(:variable, :map, required: true)

  def config_form(%{variable: %{type: :image}} = assigns) do
    assigns =
      assign(assigns,
        current_annotated: Variable.image_config_annotated?(assigns.variable.config)
      )

    ~H"""
    <div class="space-y-2">
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Default width (px)")}</span>
        </label>
        <input
          type="number"
          name={"variables[#{@variable.name}][config][default_width_px]"}
          class="input input-sm w-full"
          value={config_value(@variable.config, :default_width_px)}
          min="1"
          phx-debounce="500"
        />
      </div>
      <.annotated_toggle variable={@variable} current_annotated={@current_annotated} />
    </div>
    """
  end

  def config_form(%{variable: %{type: :image_list}} = assigns) do
    current = config_value(assigns.variable.config, :separator)
    current_separator = if current, do: to_string(current), else: "newline"

    current_columns = to_string(config_value(assigns.variable.config, :columns, 1))
    current_fit = to_string(config_value(assigns.variable.config, :fit, "width"))

    assigns =
      assign(assigns,
        current_separator: current_separator,
        current_columns: current_columns,
        current_fit: current_fit,
        current_annotated: Variable.image_config_annotated?(assigns.variable.config)
      )

    ~H"""
    <div class="space-y-2">
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Default width (px)")}</span>
        </label>
        <input
          type="number"
          name={"variables[#{@variable.name}][config][default_width_px]"}
          class="input input-sm w-full"
          value={config_value(@variable.config, :default_width_px)}
          min="1"
          phx-debounce="500"
        />
      </div>
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Separator")}</span>
        </label>
        <select
          name={"variables[#{@variable.name}][config][separator]"}
          class="select select-sm w-full"
          phx-debounce="500"
        >
          <option value="newline" selected={@current_separator == "newline"}>{gettext("New line")}</option>
          <option value="space" selected={@current_separator == "space"}>{gettext("Space")}</option>
          <option value="none" selected={@current_separator == "none"}>{gettext("None")}</option>
        </select>
      </div>
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Columns")}</span>
        </label>
        <select
          name={"variables[#{@variable.name}][config][columns]"}
          class="select select-sm w-full"
          phx-debounce="500"
        >
          <option value="1" selected={@current_columns == "1"}>1</option>
          <option value="2" selected={@current_columns == "2"}>2</option>
          <option value="3" selected={@current_columns == "3"}>3</option>
          <option value="4" selected={@current_columns == "4"}>4</option>
        </select>
      </div>
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Image size")}</span>
        </label>
        <select
          name={"variables[#{@variable.name}][config][fit]"}
          class="select select-sm w-full"
          phx-debounce="500"
        >
          <option value="width" selected={@current_fit == "width"}>{gettext("Fit width")}</option>
          <option value="page" selected={@current_fit == "page"}>{gettext("Fit page")}</option>
        </select>
      </div>
      <div class="fieldset">
        <label class="label py-1">
          <span class="fieldset-legend text-sm">{gettext("Max images (blank = unlimited)")}</span>
        </label>
        <input
          type="number"
          name={"variables[#{@variable.name}][config][max_count]"}
          class="input input-sm w-full"
          value={config_value(@variable.config, :max_count)}
          min="1"
          phx-debounce="500"
        />
      </div>
      <.annotated_toggle variable={@variable} current_annotated={@current_annotated} />
    </div>
    """
  end

  def config_form(assigns) do
    ~H""
  end

  # Renders the "Include annotations" toggle. The hidden input posts "false" so
  # an unchecked box still submits a value (checkboxes are omitted otherwise).
  attr(:variable, :map, required: true)
  attr(:current_annotated, :boolean, required: true)

  defp annotated_toggle(assigns) do
    ~H"""
    <div class="fieldset">
      <label class="label cursor-pointer py-1 justify-start gap-3">
        <input
          type="hidden"
          name={"variables[#{@variable.name}][config][annotated]"}
          value="false"
        />
        <input
          type="checkbox"
          name={"variables[#{@variable.name}][config][annotated]"}
          class="toggle toggle-sm"
          value="true"
          checked={@current_annotated}
        />
        <span class="fieldset-legend text-sm">{gettext("Include annotations")}</span>
      </label>
    </div>
    """
  end

  # Reads a config value by atom key, falling back to its string key, then the
  # given default. Uses Map.get rather than `||` so legitimately falsy stored
  # values (false, 0) are not mistaken for "missing" — the bug class fixed in
  # commit 2118b0b for the annotated flag. An explicit nil is treated as missing
  # so the default wins.
  defp config_value(config, key, default \\ nil) do
    case Map.get(config, key, :missing) do
      :missing ->
        case Map.get(config, to_string(key), :missing) do
          :missing -> default
          nil -> default
          v -> v
        end

      nil ->
        default

      v ->
        v
    end
  end
end
