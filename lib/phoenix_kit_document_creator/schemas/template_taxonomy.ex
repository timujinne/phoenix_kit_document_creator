defmodule PhoenixKitDocumentCreator.Schemas.TemplateTaxonomy do
  @moduledoc """
  Join row: one document Template's membership in one Category, with an
  optional group (`type_uuid`) within that category.

  Replaces the single `category_uuid`/`type_uuid` FKs that used to live
  directly on `phoenix_kit_doc_templates` — a template may now hold
  several of these rows (one per category), each with its own group. The
  legacy columns are kept as a backward-compatibility mirror of the
  primary membership (see `PhoenixKitDocumentCreator.Taxonomy`) and must
  not be dropped until the host-app consumer migrates.

  Uniqueness: at most one row per `(template_uuid, category_uuid)` — a
  template picks one group per category.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_doc_template_taxonomy" do
    field(:template_uuid, UUIDv7)
    field(:category_uuid, UUIDv7)
    field(:type_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @fields [:template_uuid, :category_uuid, :type_uuid]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:template_uuid, :category_uuid])
    |> unique_constraint([:template_uuid, :category_uuid],
      name: :phoenix_kit_doc_template_taxonomy_tmpl_cat_index
    )
    |> foreign_key_constraint(:template_uuid)
    |> foreign_key_constraint(:category_uuid)
    |> foreign_key_constraint(:type_uuid)
  end
end
