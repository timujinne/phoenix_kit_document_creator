defmodule PhoenixKitDocumentCreator.Schemas.DocumentSection do
  @moduledoc """
  Schema for a template-backed section within a composed document.

  Each section links a document to a specific template at a given position,
  with per-section variable overrides and image configuration. Positions are
  unique per document (enforced by DB unique index).

  Deleting the parent document cascades to its sections. Deleting the
  referenced template nullifies `template_uuid` (the section survives but
  would need re-generation).

  Image substitution downstream is restricted to PNG, JPEG, and GIF formats
  only. `image_params` keys are validated at the context layer (Task 7+).

  Note: the `opacity` key within `image_params` is currently a no-op — stored
  in DB for future activation when a two-pass batchUpdate path is implemented.
  See `GoogleDocsClient.build_single_image_request/2` for details.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_doc_document_sections" do
    belongs_to(:document, PhoenixKitDocumentCreator.Schemas.Document,
      foreign_key: :document_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:template, PhoenixKitDocumentCreator.Schemas.Template,
      foreign_key: :template_uuid,
      references: :uuid,
      type: UUIDv7
    )

    field(:position, :integer)
    field(:variable_values, :map, default: %{})
    field(:image_params, :map, default: %{})
    field(:created_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:document_uuid, :position, :created_by_uuid]
  @optional_fields [:template_uuid, :variable_values, :image_params]

  def changeset(section, attrs) do
    section
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:document_uuid, :position],
      name: :phoenix_kit_doc_document_sections_doc_position_index
    )
    |> foreign_key_constraint(:document_uuid)
    |> foreign_key_constraint(:template_uuid)
  end
end
