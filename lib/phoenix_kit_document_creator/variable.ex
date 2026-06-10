defmodule PhoenixKitDocumentCreator.Variable do
  @moduledoc """
  Variable definitions for document templates.

  Variables are `{{ variable_name }}` placeholders in Google Docs templates that
  get substituted with actual values via the Google Docs `replaceAllText` API.

  `default_image_config/1` returns the default render config for image variables,
  including `opacity` and `z_index` fields introduced in the composition pipeline.
  """

  @type variable_type :: :text | :date | :currency | :multiline | :image | :image_list

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          type: variable_type(),
          default: String.t() | nil,
          required: boolean(),
          config: map()
        }

  @enforce_keys [:name, :label, :type]
  defstruct [:name, :label, :type, default: nil, required: false, config: %{}]

  @string_var_regex ~r/\{\{\s*(?!images?\s*:)(\w+)\s*\}\}/
  @image_var_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

  @doc """
  Extracts text variable names from `{{ name }}` placeholders.

  Deliberately ignores `{{ image: name }}` and `{{ images: name }}` via a negative
  lookahead — those are handled by `extract_image_variables/1`.

  Returns a sorted list of unique names.
  """
  @spec extract_string_variables(term()) :: [String.t()]
  def extract_string_variables(text) when is_binary(text) do
    @string_var_regex
    |> Regex.scan(text)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_string_variables(_), do: []

  @doc """
  Extracts image variable definitions from `{{ image: name }}` /
  `{{ images: name }}` placeholders.

  Returns a list of `%{name: String.t(), kind: :image | :image_list}` maps,
  deduplicated by name, sorted by name.

  Note: if both `{{ image: foo }}` and `{{ images: foo }}` appear with the same name, the first occurrence (by document order) wins.
  """
  @spec extract_image_variables(term()) :: [%{name: String.t(), kind: :image | :image_list}]
  def extract_image_variables(text) when is_binary(text) do
    @image_var_regex
    |> Regex.scan(text)
    |> Enum.map(fn [_full, keyword, name] ->
      %{name: name, kind: keyword_to_kind(keyword)}
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  def extract_image_variables(_), do: []

  @doc """
  Convenience entry point that runs both detectors and returns a forked map.

  Returns `%{text: [String.t()], image: [%{name, kind}]}`.
  """
  @spec extract_variables(term()) :: %{
          text: [String.t()],
          image: [%{name: String.t(), kind: :image | :image_list}]
        }
  def extract_variables(text) do
    %{
      text: extract_string_variables(text),
      image: extract_image_variables(text)
    }
  end

  @doc """
  Builds Variable structs from a forked detection map. Text variables come first
  (sorted), then image variables (sorted by name).
  """
  @spec build_definitions(%{
          text: [String.t()],
          image: [%{name: String.t(), kind: :image | :image_list}]
        }) :: [t()]
  def build_definitions(%{text: text_names, image: image_defs}) do
    text_vars =
      text_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        %__MODULE__{
          name: name,
          label: humanize(name),
          type: guess_type(name),
          required: false,
          default: nil,
          config: %{}
        }
      end)

    image_vars =
      image_defs
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn %{name: name, kind: kind} ->
        %__MODULE__{
          name: name,
          label: humanize(name),
          type: kind,
          required: false,
          default: nil,
          config: default_image_config(kind)
        }
      end)

    text_vars ++ image_vars
  end

  @doc "Converts an underscore_name to a human-readable label."
  @spec humanize(String.t()) :: String.t()
  def humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Guesses the variable type from its name."
  @spec guess_type(String.t()) :: variable_type()
  def guess_type(name) do
    cond do
      String.contains?(name, "date") -> :date
      String.contains?(name, "amount") or String.contains?(name, "price") -> :currency
      String.contains?(name, "description") or String.contains?(name, "notes") -> :multiline
      true -> :text
    end
  end

  defp keyword_to_kind("image"), do: :image
  defp keyword_to_kind("images"), do: :image_list

  @doc """
  Returns the default render config for an image variable.

  For `:image`: `%{default_width_px: 400, opacity: 1.0, z_index: 0, annotated: true}`
  For `:image_list`: adds `separator: :newline, max_count: nil, columns: 1`.

  `:annotated` — when `true` (default), the host app should flatten drawn
  annotations into the image before inserting it into the document. Set to
  `false` per-slot in the template editor to use the raw photo instead.

  Note: `:opacity` is currently a no-op in the inline path; positioned objects
  (`z_index > 0`) also skip it pending a follow-up two-pass batchUpdate.
  Values stored in the DB are preserved for future activation.
  """
  @spec default_image_config(:image | :image_list) :: map()
  def default_image_config(:image),
    do: %{default_width_px: 400, opacity: 1.0, z_index: 0, annotated: true}

  def default_image_config(:image_list),
    do: %{
      default_width_px: 400,
      opacity: 1.0,
      z_index: 0,
      annotated: true,
      separator: :newline,
      max_count: nil,
      columns: 1
    }
end
