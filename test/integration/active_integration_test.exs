defmodule PhoenixKitDocumentCreator.Integration.ActiveIntegrationTest do
  @moduledoc """
  Tests `GoogleDocsClient.active_integration_uuid/0` and the legacy
  auto-migration flow that converts old `"google"` / `"google:name"`
  settings values to integration uuids on first read.

  Uses DataCase for settings + the StubIntegrations backend for
  Integrations dispatch.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  @settings_key "document_creator_settings"

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)

      StubIntegrations.reset!()

      Settings.update_json_setting_with_module(@settings_key, %{}, "document_creator")
    end)

    :ok
  end

  defp set_connection_setting(value) do
    current = Settings.get_json_setting(@settings_key, %{})
    updated = Map.put(current, "google_connection", value)
    Settings.update_json_setting_with_module(@settings_key, updated, "document_creator")
  end

  defp clear_connection_setting do
    Settings.update_json_setting_with_module(@settings_key, %{}, "document_creator")
  end

  describe "active_integration_uuid/0" do
    test "returns nil when no setting is stored" do
      clear_connection_setting()
      assert GoogleDocsClient.active_integration_uuid() == nil
    end

    test "returns the uuid as-is when already in the modern shape" do
      uuid = "019d0000-0000-7000-8000-000000000001"
      set_connection_setting(uuid)

      assert GoogleDocsClient.active_integration_uuid() == uuid
    end
  end

  describe "active_integration_uuid/0 — legacy auto-migration" do
    test ~s|legacy "google:name" — exact match resolves to the row's uuid + persists| do
      uuid = "019d0000-0000-7000-8000-000000000002"

      StubIntegrations.connected!("test@example.com")

      StubIntegrations.seed_connection!("google", %{
        uuid: uuid,
        name: "personal",
        data: %{"name" => "personal", "provider" => "google"}
      })

      set_connection_setting("google:personal")

      # First read auto-migrates and returns the uuid.
      assert GoogleDocsClient.active_integration_uuid() == uuid

      # The setting was rewritten in place.
      assert %{"google_connection" => ^uuid} = Settings.get_json_setting(@settings_key, %{})

      # Second read is a direct passthrough (no migration logic re-runs).
      assert GoogleDocsClient.active_integration_uuid() == uuid
    end

    test ~s|legacy bare "google" — resolves to "google:default" when a matching connection exists| do
      uuid = "019d0000-0000-7000-8000-000000000003"

      StubIntegrations.seed_connection!("google", %{
        uuid: uuid,
        name: "default",
        data: %{"name" => "default", "provider" => "google"}
      })

      set_connection_setting("google")

      # Bare `"google"` is parsed as `provider="google", name="default"`
      # (same heuristic as the boot-time sweep in
      # `migrate_legacy_connection_references/0`). Both paths now
      # require an exact match; symmetric behavior closes the
      # "silently picks first row" footgun for multi-account installs.
      assert GoogleDocsClient.active_integration_uuid() == uuid

      assert %{"google_connection" => ^uuid} = Settings.get_json_setting(@settings_key, %{})
    end

    test ~s|legacy bare "google" — clears setting when no "default" connection exists| do
      # Pre-fix this scenario silently picked the first connection of
      # any name. Post-fix the lookup fails loudly and the setting
      # gets cleared, forcing the admin to re-pick via the
      # integration picker. Asymmetry between boot and lazy paths
      # closed by phoenix_kit_document_creator follow-up to PR #12 §1.2.
      StubIntegrations.seed_connection!("google", %{
        uuid: "019d0000-0000-7000-8000-000000000099",
        name: "personal",
        data: %{"name" => "personal", "provider" => "google"}
      })

      set_connection_setting("google")

      assert GoogleDocsClient.active_integration_uuid() == nil

      refute Map.has_key?(Settings.get_json_setting(@settings_key, %{}), "google_connection")
    end

    test "legacy value with no resolvable target → nil + setting cleared" do
      # No connections seeded; the stub returns empty list_connections.
      set_connection_setting("google:ghost")

      assert GoogleDocsClient.active_integration_uuid() == nil

      # Setting was cleared so subsequent calls don't re-attempt the
      # migration on every page load.
      refute Map.has_key?(Settings.get_json_setting(@settings_key, %{}), "google_connection")
    end
  end

  describe "get_credentials/0" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.get_credentials()
    end

    test "dispatches to the backend with the active uuid" do
      uuid = "019d0000-0000-7000-8000-000000000010"
      set_connection_setting(uuid)
      StubIntegrations.connected!()

      assert {:ok, %{access_token: "stub-token"}} = GoogleDocsClient.get_credentials()
    end
  end

  describe "connection_status/0" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end

    test "extracts the connected email from the integration metadata" do
      uuid = "019d0000-0000-7000-8000-000000000020"
      set_connection_setting(uuid)
      StubIntegrations.connected!("user@example.com")

      assert {:ok, %{email: "user@example.com"}} = GoogleDocsClient.connection_status()
    end

    test "returns the backend's error tuple unchanged when not connected" do
      uuid = "019d0000-0000-7000-8000-000000000021"
      set_connection_setting(uuid)
      StubIntegrations.disconnected!()

      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end
  end

  describe "authenticated_request/3" do
    test "returns :not_configured when no integration is picked" do
      clear_connection_setting()
      assert {:error, :not_configured} = GoogleDocsClient.authenticated_request(:get, "/foo")
    end

    test "forwards through the backend's stub when connected" do
      uuid = "019d0000-0000-7000-8000-000000000030"
      set_connection_setting(uuid)
      StubIntegrations.connected!()

      StubIntegrations.stub_request(:get, "drive/v3/files", {:ok, %{status: 200, body: %{}}})

      assert {:ok, %{status: 200}} =
               GoogleDocsClient.authenticated_request(
                 :get,
                 "https://www.googleapis.com/drive/v3/files"
               )
    end
  end

  describe "migrate_legacy/0 — combined entry point" do
    test "returns {:ok, summary} with both migration kinds reported" do
      clear_connection_setting()

      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{},
        "document_creator"
      )

      {:ok, summary} = PhoenixKitDocumentCreator.migrate_legacy()

      assert is_map(summary)
      assert Map.has_key?(summary, :credentials_migration)
      assert Map.has_key?(summary, :reference_migration)
    end

    test "credentials migration: legacy oauth setting gets converted to integration row" do
      # Stage legacy oauth tokens under the OLD settings key.
      legacy_oauth = %{
        "client_id" => "old-client-id",
        "client_secret" => "old-client-secret",
        "access_token" => "old-access-token",
        "refresh_token" => "old-refresh-token",
        "connected_email" => "user@example.com"
      }

      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        legacy_oauth,
        "document_creator"
      )

      # No `integration:google:default` row yet — migration should create it.
      {:ok, _summary} = PhoenixKitDocumentCreator.migrate_legacy()

      # New integration row exists with the migrated tokens.
      assert {:ok, %{"client_id" => "old-client-id"} = data} =
               PhoenixKit.Integrations.get_integration("google:default")

      assert data["access_token"] == "old-access-token"
      assert data["status"] == "connected"
      assert data["external_account_id"] == "user@example.com"
    end

    @tag :requires_unreleased_core
    test "credentials migration: clears the legacy oauth key after success" do
      # Stage legacy plaintext OAuth tokens.
      legacy_oauth = %{
        "client_id" => "old-client-id",
        "client_secret" => "old-client-secret",
        "access_token" => "old-access-token",
        "refresh_token" => "old-refresh-token",
        "connected_email" => "user@example.com"
      }

      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        legacy_oauth,
        "document_creator"
      )

      {:ok, _summary} = PhoenixKitDocumentCreator.migrate_legacy()

      # Plaintext secrets must not survive the migration. Row may
      # remain (settings table doesn't expose a delete) but the
      # secret-bearing fields must be gone.
      legacy_after = Settings.get_json_setting("document_creator_google_oauth", %{})
      refute Map.has_key?(legacy_after, "client_secret")
      refute Map.has_key?(legacy_after, "access_token")
      refute Map.has_key?(legacy_after, "refresh_token")
    end

    @tag :requires_unreleased_core
    test "credentials migration: short-circuits when integration row already exists" do
      # Stage both: legacy oauth + a manually-created integration row.
      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{"client_id" => "should-not-be-migrated"},
        "document_creator"
      )

      {:ok, %{uuid: uuid}} = PhoenixKit.Integrations.add_connection("google", "default")
      {:ok, _} = PhoenixKit.Integrations.save_setup(uuid, %{"client_id" => "manual-cid"})

      {:ok, _summary} = PhoenixKitDocumentCreator.migrate_legacy()

      # The pre-existing manual data is intact — legacy didn't overwrite it.
      assert {:ok, %{"client_id" => "manual-cid"}} =
               PhoenixKit.Integrations.get_integration("google:default")
    end

    @tag :requires_unreleased_core
    test "reference migration: rewrites string-shape google_connection to uuid" do
      # Pre-stage an integration row + a settings value pointing at
      # it via name string.
      {:ok, %{uuid: integration_uuid}} =
        PhoenixKit.Integrations.add_connection("google", "personal")

      {:ok, _} = PhoenixKit.Integrations.save_setup(integration_uuid, %{"client_id" => "cid"})

      set_connection_setting("google:personal")

      {:ok, _summary} = PhoenixKitDocumentCreator.migrate_legacy()

      # Setting was rewritten in place to the uuid form.
      assert %{"google_connection" => ^integration_uuid} =
               Settings.get_json_setting("document_creator_settings", %{})
    end

    @tag :requires_unreleased_core
    test "is idempotent — calling twice yields the same end state" do
      {:ok, %{uuid: uuid}} = PhoenixKit.Integrations.add_connection("google", "default")
      {:ok, _} = PhoenixKit.Integrations.save_setup(uuid, %{"client_id" => "cid"})

      set_connection_setting("google:default")

      {:ok, _} = PhoenixKitDocumentCreator.migrate_legacy()
      first_state = Settings.get_json_setting("document_creator_settings", %{})

      {:ok, _} = PhoenixKitDocumentCreator.migrate_legacy()
      second_state = Settings.get_json_setting("document_creator_settings", %{})

      assert first_state == second_state
      assert first_state["google_connection"] == uuid
    end
  end
end
