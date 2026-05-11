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

  @doc """
  Extracts variable names from text by scanning for `{{ variable_name }}` patterns.

  Returns a sorted list of unique variable names (strings).
  """
  @spec extract_variables(term()) :: [String.t()]
  def extract_variables(text) when is_binary(text) do
    ~r/\{\{\s*(\w+)\s*\}\}/
    |> Regex.scan(text)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_variables(_), do: []

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
end
