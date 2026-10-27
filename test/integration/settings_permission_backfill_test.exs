defmodule PhoenixKitDocumentCreator.Integration.SettingsPermissionBackfillTest do
  @moduledoc """
  `document_creator.settings` narrowed what the base key allows, so
  `migrate_legacy/0` grants it once to every role that already held the
  base key — and never again, so later roles get the narrow meaning.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

  @flag "document_creator_settings_backfilled"
  @sub "document_creator.settings"

  setup do
    {:ok, _} = Settings.update_setting("document_creator_enabled", "true")
    :ok
  end

  defp role_with_base! do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{"name" => "DocCreator-#{n}", "description" => "test"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "document_creator", nil)
    role
  end

  defp holds?(role, key), do: key in Permissions.get_permissions_for_role(role.uuid)

  test "grants the sub-key once to roles holding the base key, then sets the flag" do
    holder = role_with_base!()

    {:ok, bystander} =
      Roles.create_role(%{"name" => "NoDocs-#{System.unique_integer([:positive])}"})

    assert {:ok, %{settings_permission_backfill: :backfilled}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert holds?(holder, @sub)
    refute holds?(bystander, @sub)
    assert Settings.get_setting(@flag) == "true"

    # A role granted the base key after the backfill keeps the narrow meaning.
    late = role_with_base!()

    assert {:ok, %{settings_permission_backfill: :already_backfilled}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    refute holds?(late, @sub)
  end

  test "a revoke after the backfill sticks across boots" do
    holder = role_with_base!()
    PhoenixKitDocumentCreator.migrate_legacy()
    :ok = Permissions.revoke_permission(holder.uuid, @sub)

    PhoenixKitDocumentCreator.migrate_legacy()
    refute holds?(holder, @sub)
  end

  test "a failed grant leaves the flag unset so the next boot retries" do
    holder = role_with_base!()

    # Without the module registered the sub-key is not a known permission,
    # so the grant's changeset rejects it.
    ModuleRegistry.unregister(PhoenixKitDocumentCreator)
    on_exit(fn -> ModuleRegistry.register(PhoenixKitDocumentCreator) end)

    assert {:ok, %{settings_permission_backfill: {:error, _}}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    refute holds?(holder, @sub)
    refute Settings.get_setting(@flag) == "true"

    ModuleRegistry.register(PhoenixKitDocumentCreator)

    assert {:ok, %{settings_permission_backfill: :backfilled}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert holds?(holder, @sub)
    assert Settings.get_setting(@flag) == "true"
  end

  test "the sub-key is declared on the module" do
    %{sub_permissions: subs} = PhoenixKitDocumentCreator.permission_metadata()
    assert Enum.any?(subs, &(&1.key == "settings"))
  end

  # Core's `get_permissions_for_role/1` rescues a query error to `[]`, which
  # would read as "nobody holds the base key" and set the flag for good.
  test "a failed grant lookup is an error, and the flag stays unset" do
    _holder = role_with_base!()

    # DDL inside the test's sandbox transaction, undone with it.
    TestRepo.query!("ALTER TABLE phoenix_kit_role_permissions RENAME TO pk_rp_hidden")

    result = PhoenixKitDocumentCreator.migrate_legacy()

    TestRepo.query!("ALTER TABLE pk_rp_hidden RENAME TO phoenix_kit_role_permissions")

    assert {:ok, %{settings_permission_backfill: {:error, :lookup_failed}}} = result
    refute Settings.get_setting(@flag) == "true"
  end
end
