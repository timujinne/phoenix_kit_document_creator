defmodule PhoenixKitDocumentCreator.Integration.LegacyCredentialsMigrationTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings

  @legacy_key "document_creator_google_oauth"
  @legacy_data %{
    "client_id" => "legacy-client",
    "client_secret" => "legacy-secret",
    "access_token" => "legacy-access",
    "refresh_token" => "legacy-refresh",
    "folder_path_documents" => "legacy/documents"
  }

  setup do
    {:ok, _} =
      Settings.update_json_setting_with_module(@legacy_key, @legacy_data, "document_creator")

    :ok
  end

  test "resumes into an empty connection without changing its uuid or creating a duplicate" do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("google", "default")

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "document_creator_settings",
        %{"google_connection" => uuid},
        "document_creator"
      )

    assert {:ok, %{credentials_migration: :migrated}} = PhoenixKitDocumentCreator.migrate_legacy()

    assert [%{uuid: ^uuid}] = Integrations.list_connections("google")
    assert {:ok, data} = Integrations.get_integration(uuid)
    assert data["client_id"] == "legacy-client"
    assert data["refresh_token"] == "legacy-refresh"
    assert data["status"] == "connected"
    assert Settings.get_json_setting(@legacy_key) == %{}

    assert %{"folder_path_documents" => "legacy/documents"} =
             Settings.get_json_setting("document_creator_folders")

    assert {:ok, %{credentials_migration: :no_legacy_data}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert [%{uuid: ^uuid}] = Integrations.list_connections("google")

    assert_activity_logged("integration.legacy_migrated",
      metadata_has: %{"migration_kind" => "credentials_migrated", "integration_uuid" => uuid}
    )
  end

  for field <- ~w(client_id client_secret access_token refresh_token) do
    test "preserves an existing connection with only #{field} configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("google", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{unquote(field) => "manual-value"})
      original = Settings.get_json_setting_by_uuid(uuid)

      assert {:ok, %{credentials_migration: :already_migrated}} =
               PhoenixKitDocumentCreator.migrate_legacy()

      assert Settings.get_json_setting_by_uuid(uuid) == original
      assert Settings.get_json_setting(@legacy_key) == @legacy_data
      refute_activity_logged("integration.legacy_migrated")
    end
  end

  @tag :capture_log
  test "preserves a stored secret even when it cannot currently be decrypted" do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("google", "default")

    {:ok, _} =
      Integrations.save_setup(uuid, %{"client_secret" => "enc:v1:unreadable-test-ciphertext"})

    original = Settings.get_json_setting_by_uuid(uuid)

    assert {:ok, %{credentials_migration: :already_migrated}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert Settings.get_json_setting_by_uuid(uuid) == original
    assert Settings.get_json_setting(@legacy_key) == @legacy_data
    refute_activity_logged("integration.legacy_migrated")
  end

  @tag :capture_log
  test "rolls back credentials and folders when clearing the legacy setting fails" do
    reject_setting_update(@legacy_key)

    assert {:ok, %{credentials_migration: {:error, _}}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert Integrations.list_connections("google") == []
    assert Settings.get_json_setting(@legacy_key) == @legacy_data
    assert Settings.get_json_setting("document_creator_folders") == nil
    refute_activity_logged("integration.legacy_migrated")
  end

  @tag :capture_log
  test "keeps the legacy data when saving folders fails and allows a later retry" do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("google", "default")

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "document_creator_folders",
        %{},
        "document_creator"
      )

    reject_setting_update("document_creator_folders")

    assert {:ok, %{credentials_migration: {:error, _}}} =
             PhoenixKitDocumentCreator.migrate_legacy()

    assert Settings.get_json_setting(@legacy_key) == @legacy_data
    assert {:ok, data} = Integrations.get_integration(uuid)
    refute data["client_id"]
    refute_activity_logged("integration.legacy_migrated")

    SQL.query!(
      Repo,
      "DROP TRIGGER dcr_reject_setting_update ON phoenix_kit_settings"
    )

    assert {:ok, %{credentials_migration: :migrated}} = PhoenixKitDocumentCreator.migrate_legacy()
    assert [%{uuid: ^uuid}] = Integrations.list_connections("google")
    assert Settings.get_json_setting(@legacy_key) == %{}
  end

  defp reject_setting_update(key) do
    # All DDL is inside the sandbox transaction and disappears with the test.
    SQL.query!(Repo, """
    CREATE FUNCTION pg_temp.dcr_reject_setting_update() RETURNS trigger AS $$
    BEGIN
      IF OLD.key = TG_ARGV[0] THEN
        RAISE EXCEPTION 'simulated settings write failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    # Both callers pass fixed setting keys, never user input.
    SQL.query!(Repo, """
    CREATE TRIGGER dcr_reject_setting_update BEFORE UPDATE ON phoenix_kit_settings
    FOR EACH ROW EXECUTE FUNCTION pg_temp.dcr_reject_setting_update('#{key}')
    """)
  end
end
