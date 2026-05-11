defmodule PhoenixKitDocumentCreator.Variable do
  @moduledoc """
  Variable definitions for document templates.

  Variables are `{{ variable_name }}` placeholders in Google Docs templates that
  get substituted with actual values via the Google Docs `replaceAllText` API.
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
  Builds Variable structs from a list of variable names, guessing types from names.
  """
  @spec build_definitions([String.t()]) :: [t()]
  def build_definitions(names) when is_list(names) do
    Enum.map(names, fn name ->
      %__MODULE__{
        name: name,
        label: humanize(name),
        type: guess_type(name),
        required: false,
        default: nil
      }
    end)
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
end
