defmodule PhoenixKitDocumentCreator.Migrations.SchemaV2Test do
  @moduledoc """
  Pins V2 of the module-owned migration chain: the
  `phoenix_kit_doc_template_taxonomy` join table.

  Full-chain idempotency is proven structurally on every test boot —
  `test_helper.exs` runs `Schema.up/1` (version-keyed) AFTER core's
  `ensure_current/2` built the base tables, so a non-idempotent statement
  would crash the boot before any test runs. These tests pin the version
  contract and the table/index shape on top of that.
  """
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Migrations.Schema
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

  test "current_version/0 is 3" do
    assert Schema.current_version() == 3
  end

  test "runtime version resolves to current after boot (marker stamped)" do
    assert Schema.migrated_version_runtime() == Schema.current_version()
    assert Schema.migrated_version_runtime(prefix: "public") == 3
  end

  test "the template_taxonomy join table exists after boot" do
    assert %{rows: [[true]]} =
             TestRepo.query!(
               "SELECT to_regclass('public.phoenix_kit_doc_template_taxonomy') IS NOT NULL"
             )
  end

  test "the unique (template_uuid, category_uuid) index exists" do
    assert %{rows: [[1]]} =
             TestRepo.query!("""
             SELECT count(*)::int FROM pg_indexes
             WHERE indexname = 'phoenix_kit_doc_template_taxonomy_tmpl_cat_index'
             """)
  end

  # The comment wording is deliberately not pinned (it is host-neutral prose
  # and may be reworded); what must hold is that both legacy mirror columns
  # carry a deprecation warning against dropping them.
  test "the legacy category_uuid / type_uuid columns carry a do-not-drop deprecation comment" do
    for column <- ~w(category_uuid type_uuid) do
      assert %{rows: [[comment]]} =
               TestRepo.query!(
                 """
                 SELECT col_description('public.phoenix_kit_doc_templates'::regclass, a.attnum)
                 FROM pg_attribute a
                 WHERE a.attrelid = 'public.phoenix_kit_doc_templates'::regclass
                   AND a.attname = $1
                 """,
                 [column]
               )

      assert comment =~ "deprecated"
      assert comment =~ "do not drop"
    end
  end
end
