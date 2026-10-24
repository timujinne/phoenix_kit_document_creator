defmodule PhoenixKitDocumentCreator.Migrations.Schema do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_document_creator` —
  the decentralized-migrations protocol core's `mix phoenix_kit.update`
  discovers via `migration_module/0` (`current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`). Adopted per the workspace direction of moving module tables
  out of the core chain (`phoenix_kit_projects` is the reference
  implementation; the doc TABLES themselves remain core-created — V86 +
  V94 — this chain only ITERATES on them).

  Versions:

    * **V1** — `phoenix_kit_doc_documents.project_uuid` (nullable FK →
      `phoenix_kit_projects`, ON DELETE SET NULL): real per-project
      document linkage for the projects hub's Documents tab. The FK
      target is core-created (V101), present on every current install.
    * **V2** — `phoenix_kit_doc_template_taxonomy` join table: a template's
      membership in one category, with an optional group (`type_uuid`).
      Replaces the single `category_uuid`/`type_uuid` FKs on
      `phoenix_kit_doc_templates` with a many-to-many model (a template may
      belong to several categories, each with its own group). Existing
      `(category_uuid, type_uuid)` bindings are backfilled as one row each.
      The legacy template columns are **kept** as a compatibility mirror of
      the primary membership and **stamped with a deprecation COMMENT** —
      they must not be dropped until the host-app consumer migrates.

  The migrated version is tracked as a `dcr_schema:<N>` COMMENT on
  `phoenix_kit_doc_documents` (the marker convention from the projects
  chain, namespaced). A marker-less table reads as version 0 — the core
  baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 2
  @marker_prefix "dcr_schema:"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `dcr_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — unlike the
  projects chain there is no pre-chain content to defend, V1 is purely
  additive).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # classoid anchors the description join to pg_class (the projects
    # chain's ZAI panel find R1-4).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = 'phoenix_kit_doc_documents' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)

    v1_project_link(p)
    v2_template_taxonomy(p)
    v2_deprecate_legacy_template_columns(p)

    execute(
      "COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS '#{@marker_prefix}#{@current_version}'"
    )
  end

  @doc """
  Rolls back to `target` (version-aware; 0 removes everything this chain added).

  Ecto wraps each migration's `down/1` in a DDL transaction (this chain does
  not set `@disable_ddl_transaction`), so the statements below are atomic: a
  failure rolls the whole rollback back and leaves the `dcr_schema` marker
  untouched. The `DROP TABLE` runs first so a failure never strands a
  "marker present, table gone" state.

  ⚠️ **Rolling back past V2 destroys all multi-category data.** `down(target: 1)`
  drops `phoenix_kit_doc_template_taxonomy` — the source of truth for template
  memberships. Only the V1 legacy mirror (`templates.category_uuid`/`type_uuid`,
  a single binding per template) survives; every membership a template held
  beyond its primary one is lost. A subsequent `up` re-backfills only from that
  single mirror column.
  """
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    p = prefix_str(prefix)
    target = Keyword.get(opts, :version, 0)

    if target < 2 do
      # DROP first (see moduledoc): destroys all V2 membership rows.
      execute("DROP TABLE IF EXISTS #{p}phoenix_kit_doc_template_taxonomy")
      # Clear the deprecation notes added by V2's up/1.
      execute("COMMENT ON COLUMN #{p}phoenix_kit_doc_templates.category_uuid IS NULL")
      execute("COMMENT ON COLUMN #{p}phoenix_kit_doc_templates.type_uuid IS NULL")
    end

    if target < 1 do
      execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS project_uuid")
    end

    if target > 0 do
      execute("COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS '#{@marker_prefix}#{target}'")
    else
      execute("COMMENT ON TABLE #{p}phoenix_kit_doc_documents IS NULL")
    end
  end

  defp v1_project_link(p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_doc_documents
    ADD COLUMN IF NOT EXISTS project_uuid UUID
      REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE SET NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_documents_project_index
    ON #{p}phoenix_kit_doc_documents (project_uuid)
    """)
  end

  # V2 — the many-to-many join between a template and its (category, group)
  # memberships. `template_uuid`/`category_uuid` cascade on parent delete;
  # `type_uuid` (the optional group) nulls out so a group's deletion leaves
  # the category membership intact. The unique (template_uuid, category_uuid)
  # index enforces "one group per category per template" and backs the
  # backfill's ON CONFLICT clause (which also keeps this up/1 idempotent).
  defp v2_template_taxonomy(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_doc_template_taxonomy (
      uuid UUID PRIMARY KEY,
      template_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_doc_templates(uuid) ON DELETE CASCADE,
      category_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_doc_categories(uuid) ON DELETE CASCADE,
      type_uuid UUID
        REFERENCES #{p}phoenix_kit_doc_types(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_doc_template_taxonomy_tmpl_cat_index
    ON #{p}phoenix_kit_doc_template_taxonomy (template_uuid, category_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_taxonomy_category_index
    ON #{p}phoenix_kit_doc_template_taxonomy (category_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_taxonomy_type_index
    ON #{p}phoenix_kit_doc_template_taxonomy (type_uuid)
    """)

    # Backfill: one membership per template that currently has a category.
    # `gen_random_uuid()` (UUIDv4) is fine for these internal join-row PKs —
    # they are never surfaced by id. ON CONFLICT DO NOTHING keeps up/1
    # idempotent across re-runs (the projects-chain boot-idempotency rule).
    execute("""
    INSERT INTO #{p}phoenix_kit_doc_template_taxonomy
      (uuid, template_uuid, category_uuid, type_uuid, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.uuid, t.category_uuid, t.type_uuid,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
    FROM #{p}phoenix_kit_doc_templates t
    WHERE t.category_uuid IS NOT NULL
    ON CONFLICT (template_uuid, category_uuid) DO NOTHING
    """)
  end

  # Owner-mandated safeguard: stamp the legacy single-binding columns as
  # deprecated so nobody drops them before the host-app consumer migrates to the
  # join table. They stay populated as a mirror of the primary membership
  # (see `PhoenixKitDocumentCreator.Taxonomy`). Idempotent — COMMENT ON
  # COLUMN simply overwrites.
  defp v2_deprecate_legacy_template_columns(p) do
    note =
      "deprecated: mirror of primary membership for backward compatibility; " <>
        "source of truth is phoenix_kit_doc_template_taxonomy — do not drop " <>
        "without migrating the host app that still reads it"

    execute("COMMENT ON COLUMN #{p}phoenix_kit_doc_templates.category_uuid IS '#{note}'")

    execute("COMMENT ON COLUMN #{p}phoenix_kit_doc_templates.type_uuid IS '#{note}'")
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the projects chain uses.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end

  defp prefix_str(prefix), do: "#{prefix}."
end
