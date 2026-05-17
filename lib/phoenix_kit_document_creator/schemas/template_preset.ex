defmodule PhoenixKitDocumentCreator.Schemas.TemplatePreset do
  @moduledoc """
  Schema for named, reusable template compositions.

  A preset captures an ordered list of section descriptors (template uuid,
  position, variable defaults, image params) that can be applied to a new
  document to produce a multi-section composition in one step.

  ## Scope convention (Stage 1, no migration)

  Presets are associated with the document taxonomy by repurposing the
  generic scope pair:

    * `scope_id`   — owning Category uuid (always set for managed presets)
    * `scope_type` — owning Type uuid, or `nil` for category-wide presets

  A future migration will replace this with real `category_uuid` /
  `type_uuid` foreign keys (see the design spec).

  The `sections` field is a JSONB array where each element is a map
  describing one section (keys: `template_uuid`, `position`,
  `variable_values`, `image_params`). Image substitution is restricted to
  PNG, JPEG, and GIF formats; enforcement happens at the context layer.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_doc_template_presets" do
    field(:name, :string)
    field(:description, :string)
    field(:scope_type, :string)
    field(:scope_id, :string)
    field(:sections, {:array, :map}, default: [])
    field(:created_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :created_by_uuid]
  @optional_fields [:description, :scope_type, :scope_id, :sections]

  def changeset(preset, attrs) do
    preset
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
  end
end
