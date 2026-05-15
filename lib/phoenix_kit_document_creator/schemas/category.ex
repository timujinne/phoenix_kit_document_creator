defmodule PhoenixKitDocumentCreator.Schemas.Category do
  @moduledoc """
  Top-level taxonomy node for the Document Creator.

  A Category groups Types; Templates and Documents reference a Category
  (and optionally a Type) via nullable FKs. Soft-deleted via
  `status = "deleted"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active deleted)

  schema "phoenix_kit_doc_categories" do
    field(:name, :string)
    field(:description, :string)
    field(:position, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    has_many(:types, PhoenixKitDocumentCreator.Schemas.Type,
      foreign_key: :category_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :position, :status, :data]

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses

  def changeset(category, attrs) do
    category
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
