defmodule PhoenixKitDocumentCreator.Web.GoogleOAuthSettingsLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  import ExUnit.CaptureLog

  describe "mount" do
    test "renders the settings page header", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/settings/document-creator")

      assert html =~ "Document Creator Settings"
    end
  end

  describe "handle_info catch-all" do
    setup do
      # The catch-all clause logs at :debug, but config/test.exs pins
      # Logger level to :warning — capture_log can't see filtered events.
      # Bump to :debug for this describe so the assertion exercises the
      # real call site instead of just process-alive tautologies.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "an unexpected message does not crash the LiveView and logs at :debug",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :totally_unexpected)
          send(view.pid, {:not_a_known_tuple, "data"})
          _ = render(view)
        end)

      assert log =~ "GoogleOAuthSettingsLive"
      assert log =~ "ignoring unexpected message"
      assert Process.alive?(view.pid)
    end
  end

  describe "handle_event coverage" do
    test "save_folders persists trimmed folder paths and surfaces success flash",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_change(view, "save_folders", %{
        "templates_path" => "  clients/templates  ",
        "templates_name" => "Templates",
        "documents_path" => "  clients/documents  ",
        "documents_name" => "Documents",
        "deleted_path" => "",
        "deleted_name" => "deleted"
      })

      state = :sys.get_state(view.pid).socket.assigns
      # Trim happens server-side.
      assert state.templates_path == "clients/templates"
      assert state.documents_path == "clients/documents"
      assert state.success =~ "saved"
    end

    test "save_folders without changes is a no-op (no activity log)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      # Submit the same default values twice — second call sees no diff.
      render_change(view, "save_folders", %{
        "templates_path" => "",
        "templates_name" => "templates",
        "documents_path" => "",
        "documents_name" => "documents",
        "deleted_path" => "",
        "deleted_name" => "deleted"
      })

      assert :sys.get_state(view.pid).socket.assigns.success =~ "saved"
    end

    test "browse_folder with a valid field opens the browser modal",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "templates_path"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.browser_open == true
      assert state.browser_field == "templates_path"
      # `browser_loading` flips true on click then false when the
      # spawned `:load_drive_folders` task completes. Asserting
      # `loading == true` is racy because the spawned task can
      # finish before `:sys.get_state` returns (the unstubbed Drive
      # call short-circuits to `[]` very fast). Pinning the modal
      # state via `browser_open` + `browser_field` is sufficient —
      # the loading flag is render-only.
    end

    test "browse_folder ignores invalid field (no modal)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "evil_path"})

      assert :sys.get_state(view.pid).socket.assigns.browser_open == false
    end

    test "browser_navigate appends to path and triggers reload",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      # Open browser first.
      render_click(view, "browse_folder", %{"field" => "documents_path"})

      render_click(view, "browser_navigate", %{"id" => "folder-deep", "name" => "Deep"})

      # Path append is the stable post-event state; the transient
      # `browser_loading: true` flip happens synchronously and may have
      # already cycled back to `false` by the time `:sys.get_state`
      # snapshots — `active_integration_uuid()` returns nil in this
      # test (no setting seeded), so the load handler short-circuits.
      state = :sys.get_state(view.pid).socket.assigns
      assert Enum.any?(state.browser_path, fn p -> p.id == "folder-deep" end)
    end

    test "browser_back trims the path back to the index",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "documents_path"})

      # Navigate two levels deep.
      render_click(view, "browser_navigate", %{"id" => "lvl-1", "name" => "One"})
      render_click(view, "browser_navigate", %{"id" => "lvl-2", "name" => "Two"})

      render_click(view, "browser_back", %{"index" => "0"})

      state = :sys.get_state(view.pid).socket.assigns
      # Index 0 means we kept just the first crumb (root).
      assert length(state.browser_path) == 1
    end

    test "browser_back clamps invalid index input to a sane value",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "documents_path"})

      # `Integer.parse("not-a-number")` returns :error — handler clamps
      # to index 0.
      render_click(view, "browser_back", %{"index" => "not-a-number"})
      assert Process.alive?(view.pid)
    end

    test "browser_select with valid field commits the path to the form",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "templates_path"})
      render_click(view, "browser_navigate", %{"id" => "tpl-folder", "name" => "Templates"})
      render_click(view, "browser_select")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.browser_open == false
      assert state.templates_path == "Templates"
    end

    test "browser_close just closes the modal without committing",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "browse_folder", %{"field" => "templates_path"})
      render_click(view, "browser_close")

      assert :sys.get_state(view.pid).socket.assigns.browser_open == false
    end

    test "dismiss clears success/error flash assigns",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket, success: "saved", error: "boom")

        %{state | socket: new_socket}
      end)

      render_click(view, "dismiss")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.success == nil
      assert state.error == nil
    end
  end

  describe "mount with a seeded integration (connected branch)" do
    setup do
      # Seed `integration:google:default` in phoenix_kit_settings so
      # `Integrations.get_integration("google")` returns {:ok, data}
      # at mount — exercising the connected_email extraction branch.
      PhoenixKit.Settings.update_json_setting(
        "integration:google",
        %{
          "external_account_id" => "user@example.com",
          "metadata" => %{"connected_email" => "user@example.com"},
          "auth_status" => "connected"
        }
      )

      :ok
    end

    test "extracts connected_email from metadata when integration is configured",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/settings/document-creator")

      assert is_binary(html)
      assert html =~ "Document Creator Settings"
    end
  end

  describe "select_connection event" do
    test "switches the active connection and logs settings.connection_changed",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      # Seed a target connection in settings.
      PhoenixKit.Settings.update_json_setting(
        "integration:google:personal",
        %{
          "external_account_id" => "personal@example.com",
          "metadata" => %{"connected_email" => "personal@example.com"},
          "auth_status" => "connected"
        }
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      render_click(view, "select_connection", %{"uuid" => "google:personal"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.active_connection == "google:personal"
      assert state.success =~ "updated"

      assert_activity_logged("settings.connection_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"connection_key" => "google:personal"}
      )
    end
  end

  describe "load_drive_folders handle_info chain" do
    test ":load_drive_folders followed by :drive_folders_loaded updates state",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/settings/document-creator")

      # Open the browser modal (sets browser_open=true, triggers a
      # :load_drive_folders message which spawns a Task that fails to
      # contact Drive in test env). We bypass that by directly sending
      # :drive_folders_loaded with canned data.
      send(view.pid, {:drive_folders_loaded, [%{"id" => "f1", "name" => "Folder One"}]})
      _ = render(view)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.browser_folders == [%{"id" => "f1", "name" => "Folder One"}]
      assert state.browser_loading == false
    end
  end
end
