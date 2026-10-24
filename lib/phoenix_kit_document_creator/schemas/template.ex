defmodule PhoenixKitDocumentCreator.Schemas.Template do
  @moduledoc """
  Schema for document templates.

  Templates are now managed as Google Docs in Google Drive. The `google_doc_id`
  field links a template record to its Google Doc. Variables use `{{ placeholder }}`
  syntax and are substituted via the Google Docs API.

  Note: Several fields (`content_html`, `content_css`, `content_native`, header/footer
  associations) are retained for database compatibility but are no longer used in the
  Google Docs workflow. A future migration should remove these columns.

  ## Deprecated taxonomy columns (do not drop)

  As of migration chain **V2**, a template's category/group membership is a
  **many-to-many** relation stored in `phoenix_kit_doc_template_taxonomy`
  (see `PhoenixKitDocumentCreator.Schemas.TemplateTaxonomy`). The two
  single-binding columns below are **deprecated** but deliberately **kept
  and kept populated** as a mirror of the *primary* membership so the host-app
  consumer keeps working until it migrates to the join table:

    * `category_uuid` — mirror of the lowest-`Category.position` **active**
      membership
    * `type_uuid` — that membership's group (nulled when the group is
      soft-deleted)

  The mirror is recomputed whenever memberships are written
  (`Taxonomy.set_template_memberships/3`) **and** on category/type soft-delete
  and restore (`trash_category`/`restore_category`/`trash_type`/`restore_type`
  recompute it from the surviving active memberships). As long as it is kept in
  sync this way — the normal write path, an invariant enforced by tests — it
  does not point at a trashed category/group.

  **Permanent** deletion is the one best-effort gap, driven by the join table's
  own foreign keys rather than a recompute: deleting a category cascades the
  membership row away (`ON DELETE CASCADE`), while deleting a type nulls that
  row's `type_uuid` (`ON DELETE SET NULL`). Either way the mirror is only
  brought back in line lazily, on the template's next membership write; until
  then a multi-category template may keep a stale/nil mirror. The join table
  stays authoritative.

  Both columns are stamped with a deprecation `COMMENT` in the database (V2).
  They must not be dropped without a coordinated host-app migration; a later chain
  version will remove them once the host app reads memberships directly.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Utils.Slug

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

    belongs_to(:category, PhoenixKitDocumentCreator.Schemas.Category,
      foreign_key: :category_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:type, PhoenixKitDocumentCreator.Schemas.Type,
      foreign_key: :type_uuid,
      references: :uuid,
      type: UUIDv7
    )

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
    :category_uuid,
    :type_uuid,
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
    |> validate_length(:language, max: 10)
    |> validate_inclusion(:status, @statuses)
    # Core's changeset glue, replacing a local `maybe_generate_slug/1` that
    # keyed on `get_change(:name)` — so RENAMING a template regenerated its
    # slug and moved the URL, and nothing ever probed for collisions, so two
    # templates named alike simply shared one. `put_slug/3` keeps an existing
    # slug on rename, honours an explicit one, regenerates on an explicit
    # blank, and suffixes -2, -3 … until free (excluding this row itself).
    #
    # `max_length: 255` is load-bearing: `slug` is varchar(255) and `:name`
    # is allowed 255 characters, so an unbounded `-2` suffix would overflow
    # the column — Postgres raises rather than truncating. The
    # `validate_length(:slug)` cap moved below generation so it also sees a
    # generated slug, which at its old position it never did.
    |> Slug.put_slug(:name, max_length: 255)
    |> validate_length(:slug, max: 255)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:category_uuid)
    |> foreign_key_constraint(:type_uuid)
  end

  @doc "Changeset for upserting from Google Drive sync data."
  def sync_changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :google_doc_id, :status, :thumbnail, :variables, :path, :folder_id])
    |> validate_required([:name, :google_doc_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Focused changeset for setting/clearing the locale tag on a template.

  Used by both the create-time language stamp (`Documents.create_template/2`)
  and the post-create updater (`Documents.update_template_language/3`) so
  both write paths honour `validate_length(:language, max: 10)` — the prior
  `update_all` write skipped this and would surface oversized codes as a
  Postgrex `value too long` exception instead of a clean changeset error.
  """
  def language_changeset(template, attrs) do
    template
    |> cast(attrs, [:language])
    |> validate_length(:language, max: 10)
  end
end
