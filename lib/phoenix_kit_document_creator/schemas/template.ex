defmodule PhoenixKitDocumentCreator.Schemas.Template do
  @moduledoc """
  Schema for document templates.

  Templates are now managed as Google Docs in Google Drive. The `google_doc_id`
  field links a template record to its Google Doc. Variables use `{{ placeholder }}`
  syntax and are substituted via the Google Docs API.

  Note: Several fields (`content_html`, `content_css`, `content_native`, header/footer
  associations) are retained for database compatibility but are no longer used in the
  Google Docs workflow. A future migration should remove these columns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(published trashed lost unfiled)

  schema "phoenix_kit_doc_templates" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "published")

    field(:google_doc_id, :string)
    field(:path, :string)
    field(:folder_id, :string)
    field(:language, :string)

    field(:content_html, :string, default: "")
    field(:content_css, :string, default: "")
    field(:content_native, :map)

    field(:variables, {:array, :map}, default: [])

    belongs_to(:header, PhoenixKitDocumentCreator.Schemas.HeaderFooter,
      foreign_key: :header_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:footer, PhoenixKitDocumentCreator.Schemas.HeaderFooter,
      foreign_key: :footer_uuid,
      references: :uuid,
      type: UUIDv7
    )

    field(:config, :map, default: %{"paper_size" => "a4", "orientation" => "portrait"})
    field(:data, :map, default: %{})
    field(:thumbnail, :string)
    field(:created_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :slug,
    :description,
    :status,
    :google_doc_id,
    :path,
    :folder_id,
    :language,
    :content_html,
    :content_css,
    :content_native,
    :variables,
    :header_uuid,
    :footer_uuid,
    :config,
    :data,
    :thumbnail,
    :created_by_uuid
  ]

  def changeset(template, attrs) do
    template
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_length(:language, max: 10)
    |> validate_inclusion(:status, @statuses)
    |> maybe_generate_slug()
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  @doc "Changeset for upserting from Google Drive sync data."
  def sync_changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :google_doc_id, :status, :thumbnail, :variables, :path, :folder_id])
    |> validate_required([:name, :google_doc_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
