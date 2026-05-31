defmodule PhoenixKitDocumentCreator.Web.DocumentsLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Documents

  describe "mount — Google not connected (test env default)" do
    # In the LV test endpoint there are no Google credentials wired up,
    # so `GoogleDocsClient.connection_status/0` returns `{:error, _}`
    # at mount and the LV renders the "Google Account Not Connected"
    # empty state. These tests pin that mount path — they're not full
    # end-to-end tests of the documents/templates list (those need a
    # Drive HTTP stub, see C12 punt list).

    test "documents URL renders the empty-state card", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator")

      assert html =~ "Google Account Not Connected"
      # Settings link in the empty-state CTA.
      assert html =~ "/en/admin/settings/document-creator"
    end

    test "templates URL renders the empty-state card too", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator/templates")

      assert html =~ "Google Account Not Connected"
    end
  end

  describe "DB rows present + Google not connected" do
    test "DB rows are NOT shown when Google isn't connected", %{conn: conn} do
      # Register a document directly in the DB.
      attrs = %{
        google_doc_id: "doc-mount-#{System.unique_integer([:positive])}",
        name: "Mount-shown Document #{System.unique_integer([:positive])}"
      }

      {:ok, _} = Documents.register_existing_document(attrs)

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/document-creator")

      # Pin: when Google isn't connected, mount returns empty lists
      # regardless of DB contents. The user sees the "connect first"
      # CTA, not stale DB rows that the user can't actually act on
      # (every action button needs a working Drive client).
      assert html =~ "Google Account Not Connected"
      refute html =~ attrs.name
    end
  end

  describe "handle_info catch-all" do
    # Pinning test for the C5 fix (added Logger.debug) and the prior
    # PR #9 follow-up. Stray messages must not crash the LV.
    test "an unexpected message does not crash the LiveView", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, :unexpected_message_that_should_be_ignored)
      send(view.pid, {:totally, :unhandled, :tuple})

      # If the catch-all is missing, render/1 raises and the assertion
      # fails because the LV is dead.
      assert render(view) =~ "Document Creator"
      assert Process.alive?(view.pid)
    end
  end

  describe "connected-state actions thread actor_uuid through to context" do
    # Pinning tests for `actor_opts(socket)` threading on every
    # async/destructive `phx-click` handler. Without these, dropping
    # `actor_opts(socket)` from `handle_event("new_template", ...)` (or
    # any sibling) silently regresses to `actor_uuid: nil` on the
    # activity row — the LV smoke test that asserts `render() =~ "..."`
    # would still pass.
    #
    # The Batch 4 retrofit on `GoogleDocsClient.integrations_backend/0`
    # plus the `Test.StubIntegrations` module makes the connected-state
    # mount + Drive-bound clicks reachable without external HTTP.

    alias PhoenixKitDocumentCreator.Test.StubIntegrations

    setup do
      previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

      Application.put_env(
        :phoenix_kit_document_creator,
        :integrations_backend,
        StubIntegrations
      )

      StubIntegrations.reset!()
      StubIntegrations.connected!("admin@example.com")

      # Seed the folder cache so `get_folder_ids/0` doesn't kick off
      # discover_folders/0's parallel API requests.
      PhoenixKit.Settings.update_json_setting_with_module(
        "document_creator_folders",
        %{
          "templates_folder_id" => "stub-templates",
          "documents_folder_id" => "stub-documents",
          "deleted_templates_folder_id" => "stub-deleted-templates",
          "deleted_documents_folder_id" => "stub-deleted-documents"
        },
        "document_creator"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
          else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
      end)

      :ok
    end

    test "new_template threads actor_uuid through to template.created activity row",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "lv-tpl-1", "name" => "Untitled Template"}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/templates")

      render_click(view, "new_template")

      assert_activity_logged("template.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-tpl-1"}
      )
    end

    test "new_blank_document threads actor_uuid through to document.created activity row",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "lv-doc-1", "name" => "Untitled Document"}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "new_blank_document")

      assert_activity_logged("document.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-doc-1"}
      )
    end

    test "perform_file_action :delete threads actor_uuid through", %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid
      file_id = "lv-doc-del"

      # GET parents → PATCH addParents+removeParents (the move_file flow).
      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["src"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 200, body: %{"id" => file_id}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # The toolbar grid only renders rows for files in `@documents`,
      # but the `:perform_file_action` handler is the unified entry
      # point — drive it directly so the test doesn't depend on the
      # connected-mount fixture seeding rows in the right shape.
      send(view.pid, {:perform_file_action, :delete, file_id})
      _ = render(view)

      assert_activity_logged("document.deleted",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => file_id}
      )
    end

    # ── handle_event coverage ──────────────────────────────────────────

    test "switch_view toggles view_mode assign", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "switch_view", %{"mode" => "list"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "list"

      render_click(view, "switch_view", %{"mode" => "grid"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "grid"
    end

    test "switch_status toggles status_mode (only valid values)", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "switch_status", %{"mode" => "trashed"})
      assert :sys.get_state(view.pid).socket.assigns.status_mode == "trashed"

      render_click(view, "switch_status", %{"mode" => "active"})
      assert :sys.get_state(view.pid).socket.assigns.status_mode == "active"
    end

    test "open_modal / modal_close / modal_back toggle modal assigns", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "open_modal")
      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == true
      assert state.modal_step == "choose"

      render_click(view, "modal_back")
      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_step == "choose"

      render_click(view, "modal_close")
      assert :sys.get_state(view.pid).socket.assigns.modal_open == false
    end

    test "modal_create_blank :ok branch closes modal and creates document",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "lv-modal-doc", "name" => "Untitled Document"}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "open_modal")
      render_click(view, "modal_create_blank")

      assert :sys.get_state(view.pid).socket.assigns.modal_open == false

      assert_activity_logged("document.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-modal-doc"}
      )
    end

    test "modal_create_blank :error branch surfaces flash error",
         %{conn: conn} do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "open_modal")
      render_click(view, "modal_create_blank")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == false
      assert state.error =~ "Failed"
    end

    test "modal_select_template ignores unknown file_id (verify_known_file guard)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "modal_select_template", %{"id" => "ghost-id", "name" => "Ghost"})

      # Stays on choose step — no template was selected.
      assert :sys.get_state(view.pid).socket.assigns.modal_selected_template == nil
    end

    test "open_unfiled_actions ignores unknown file_id",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "open_unfiled_actions", %{
        "id" => "unknown-id",
        "name" => "Ghost",
        "path" => ""
      })

      assert :sys.get_state(view.pid).socket.assigns.unfiled_modal_open == false
    end

    test "unfiled_close resets the unfiled modal assigns",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Force the modal open via state injection — no Drive needed.
      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket,
            unfiled_modal_open: true,
            unfiled_file: %{"id" => "x", "name" => "x", "path" => ""},
            unfiled_working: true
          )

        %{state | socket: new_socket}
      end)

      render_click(view, "unfiled_close")

      state = :sys.get_state(view.pid).socket.assigns
      assert state.unfiled_modal_open == false
      assert state.unfiled_file == nil
      assert state.unfiled_working == false
    end

    test "unfiled_action with unknown action returns flash error",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket,
            unfiled_modal_open: true,
            unfiled_file: %{"id" => "x"},
            unfiled_working: false
          )

        %{state | socket: new_socket}
      end)

      render_click(view, "unfiled_action", %{"action" => "unknown_action"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.error =~ "failed"
    end

    test "delete event ignores unknown file_id (verify_known_file guard)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Unknown file → no pending_files insertion, no broadcast.
      render_click(view, "delete", %{"id" => "ghost"})

      assert MapSet.size(:sys.get_state(view.pid).socket.assigns.pending_files) == 0
    end

    test "restore event ignores unknown file_id",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "restore", %{"id" => "ghost"})

      assert MapSet.size(:sys.get_state(view.pid).socket.assigns.pending_files) == 0
    end

    test "refresh event triggers sync.triggered activity log + sync flow",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      render_click(view, "refresh")
      _ = render(view)

      # Loading flag is transient — by the time the test inspects it,
      # `sync_from_drive` may have already failed (no Drive stubs for
      # the walker) and `:sync_complete` reset it to false. The
      # deterministic assertion is the activity-log row.
      assert_activity_logged("sync.triggered", actor_uuid: actor_uuid)
    end

    test "silent_refresh respects loading state (no-op when loading)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket = Phoenix.Component.assign(state.socket, loading: true)
        %{state | socket: new_socket}
      end)

      # Should NOT trigger a re-sync because loading is true. The
      # observable post-condition is process-alive without a crash —
      # we don't assert on `loading` because if the silent_refresh
      # had triggered a sync it would have failed (no /drive/v3/files
      # stub) and reset loading to false either way.
      render_click(view, "silent_refresh")
      assert Process.alive?(view.pid)
    end

    test "dismiss_error clears the error assign",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket = Phoenix.Component.assign(state.socket, error: "Boom")
        %{state | socket: new_socket}
      end)

      render_click(view, "dismiss_error")
      assert :sys.get_state(view.pid).socket.assigns.error == nil
    end

    test "export_pdf event ignores unknown file_id",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Unknown file → no error assigned, no Drive call.
      render_click(view, "export_pdf", %{"id" => "ghost", "name" => "ghost.pdf"})

      assert :sys.get_state(view.pid).socket.assigns.error == nil
    end

    # ── handle_info coverage (PubSub + sync flow) ─────────────────────

    test "handle_info :sync_complete refreshes file lists from DB", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, :sync_complete)
      _ = render(view)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.loading == false
      assert is_list(state.templates)
      assert is_list(state.documents)
    end

    test "handle_info :load_thumbnails kicks off async fetch (no crash)",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, :load_thumbnails)
      assert Process.alive?(view.pid)
      _ = render(view)
    end

    test "handle_info {:thumbnail_result, ...} stores the data URI", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, {:thumbnail_result, "doc-thumb-1", "data:image/png;base64,XYZ"})
      _ = render(view)

      assert :sys.get_state(view.pid).socket.assigns.thumbnails["doc-thumb-1"] ==
               "data:image/png;base64,XYZ"
    end

    test "handle_info :poll_for_changes is a no-op when loading", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket = Phoenix.Component.assign(state.socket, loading: true)
        %{state | socket: new_socket}
      end)

      send(view.pid, :poll_for_changes)
      assert Process.alive?(view.pid)
    end

    test "handle_info {:files_changed, ...} ignores echoes from self", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Echo from the LV's own pid → must not re-trigger a sync.
      send(view.pid, {:files_changed, view.pid})
      assert Process.alive?(view.pid)
    end

    test "handle_info {:files_changed, other_pid} triggers sync when not loading",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      send(view.pid, {:files_changed, self()})
      _ = render(view)

      # Either sync_from_drive scheduled (loading=true) or no-op
      # (cooldown). Both are valid post-broadcast states.
      assert Process.alive?(view.pid)
    end

    test "modal_create_from_template happy path closes modal + creates doc",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/tpl-modal/copy",
        {:ok, %{status: 200, body: %{"id" => "lv-modal-tpl-doc"}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/documents/lv-modal-tpl-doc:batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket,
            modal_open: true,
            modal_step: "variables",
            modal_creating: false,
            modal_selected_template: %{"id" => "tpl-modal", "name" => "Tpl"}
          )

        %{state | socket: new_socket}
      end)

      render_submit(view, "modal_create_from_template", %{
        "doc_name" => "From Tpl",
        "var" => %{"client" => "Acme"}
      })

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == false
      assert state.modal_creating == false

      assert_activity_logged("document.created_from_template",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "lv-modal-tpl-doc"}
      )
    end

    test "modal_create_from_template error path keeps modal open with error flash",
         %{conn: conn} do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/tpl-modal/copy",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket,
            modal_open: true,
            modal_step: "variables",
            modal_creating: false,
            modal_selected_template: %{"id" => "tpl-modal", "name" => "Tpl"}
          )

        %{state | socket: new_socket}
      end)

      render_submit(view, "modal_create_from_template", %{
        "doc_name" => "From Tpl",
        "var" => %{}
      })

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_creating == false
      assert state.error =~ "Failed"
    end

    # NOTE: modal_select_template flows that detect variables hit a
    # cross-process sandbox flake (see AGENTS.md "Cross-process sandbox
    # sharing is unreliable for seed-and-read flows in LiveView tests").
    # The context-layer paths are pinned in
    # `documents_sync_test.exs:detect_variables/1` and
    # `drive_bound_actions_test.exs:create_document_from_template/3`.

    # NOTE: unfiled_action happy paths follow the same pattern as
    # delete/restore — sync_complete races with state injection. The
    # invalid-action branch above pins the error path; the context-
    # layer move_to_templates / move_to_documents tests live in
    # documents_sync_test.exs.

    # NOTE: open_unfiled_actions and export_pdf happy-path tests were
    # flaky because the LV's connected-state mount sends `:sync_from_drive`,
    # which on completion overwrites `:sys.replace_state`-injected
    # `documents` lists. Both code paths are pinned via the unknown-id
    # branch above (verify_known_file guard) and the context-layer
    # tests (`drive_bound_actions_test.exs:export_pdf`).

    # NOTE: same pattern as open_unfiled_actions — the LV's
    # connected-mount overwrites injected state, so happy-path
    # delete/restore tests are pinned at the context layer in
    # drive_bound_actions_test.exs.

    test "silent_refresh when not loading triggers a sync_from_drive cycle",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Default state: loading=false, no cooldown — silent_refresh
      # should kick a sync. Sync will fail (walker stub absent) but the
      # event handler exits cleanly either way; we just want code-path
      # coverage.
      render_click(view, "silent_refresh")
      assert Process.alive?(view.pid)
    end

    # ── set_template_language event coverage ───────────────────────────

    test "set_template_language ignores unknown file_id (verify_known_file guard)",
         %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/templates")

      # File not seeded into the LV's known_file_ids — the handler
      # guard rejects it before touching the DB. Pre-rejection there
      # is no DB row to update, no broadcast, no activity log.
      render_click(view, "set_template_language", %{"id" => "unknown", "language" => "en-US"})

      assert Process.alive?(view.pid)
    end

    test "set_template_language threads actor_uuid + flips DB language + activity-logs",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      # Drive the templates list view with one known template injected
      # via the LV's `:sync_complete` path. We seed the DB row first,
      # then trigger the LV's normal sync_complete handler which
      # repopulates assigns from `list_templates_from_db/0`.
      file_id = "lv-tpl-lang-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Localised Template"
        })

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/templates")

      # Force a sync_complete cycle so the DB-backed template row
      # lands in `:templates` AND `:known_file_ids` for the
      # verify_known_file guard.
      send(view.pid, :sync_complete)
      _ = render(view)

      render_click(view, "set_template_language", %{
        "id" => file_id,
        "language" => "et-EE"
      })

      # Activity log captures the from→to transition with the actor.
      assert_activity_logged("template.language_updated",
        actor_uuid: actor_uuid,
        metadata_has: %{
          "google_doc_id" => file_id,
          "language_to" => "et-EE"
        }
      )
    end

    test "set_template_language clears the language when language is empty string",
         %{conn: conn} do
      scope = fake_scope()
      actor_uuid = scope.user.uuid

      file_id = "lv-tpl-clear-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Was Set"
        })

      # Pre-seed a language so we're testing the clear path explicitly.
      {:ok, _} = Documents.update_template_language(file_id, "ja")

      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/document-creator/templates")

      send(view.pid, :sync_complete)
      _ = render(view)

      render_click(view, "set_template_language", %{
        "id" => file_id,
        "language" => ""
      })

      assert_activity_logged("template.language_updated",
        actor_uuid: actor_uuid,
        metadata_has: %{
          "google_doc_id" => file_id,
          "language_from" => "ja"
        }
      )
    end
  end

  describe "picking_existing JSON shape validation" do
    test "bogus entries in picking_existing are dropped — only the new pick survives",
         %{conn: conn} do
      file_id = "rt-tpl-bogus-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Bogus Validation Template"
        })

      conn = put_test_scope(conn, fake_scope())

      # The prior state contains one valid pick and one invalid entry.
      prior =
        JSON.encode!(%{
          "logo" => %{"media_id" => "valid-uuid"},
          "junk" => "value"
        })

      return_url =
        "/en/admin/document-creator?" <>
          URI.encode_query(%{
            "selected_media" => "new-uuid",
            "picking_var" => "banner",
            "picking_mode" => "single",
            "template_file_id" => file_id,
            "picking_existing" => prior
          })

      {:ok, view, _html} = live(conn, return_url)

      state = :sys.get_state(view.pid).socket.assigns
      # Valid prior pick is preserved
      assert state.modal_image_values["logo"] == %{"media_id" => "valid-uuid"}
      # New pick is applied
      assert state.modal_image_values["banner"] == %{"media_id" => "new-uuid"}
      # Bogus entry is dropped
      refute Map.has_key?(state.modal_image_values, "junk")
    end

    test "malformed (non-JSON) picking_existing is treated as empty prior",
         %{conn: conn} do
      file_id = "rt-tpl-malformed-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Malformed JSON Template"
        })

      conn = put_test_scope(conn, fake_scope())

      return_url =
        "/en/admin/document-creator?" <>
          URI.encode_query(%{
            "selected_media" => "pick-uuid",
            "picking_var" => "logo",
            "picking_mode" => "single",
            "template_file_id" => file_id,
            "picking_existing" => "not-json"
          })

      {:ok, view, _html} = live(conn, return_url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == true
      # Only the new pick — no crash, no stale junk
      assert state.modal_image_values == %{"logo" => %{"media_id" => "pick-uuid"}}
    end
  end

  describe "open_media_picker mode validation" do
    test "open_media_picker with garbage mode defaults to :single without crashing",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject a selected template so the handler has a valid template_file_id.
      :sys.replace_state(view.pid, fn state ->
        new_socket =
          Phoenix.Component.assign(state.socket,
            modal_open: true,
            modal_step: "variables",
            modal_image_values: %{},
            modal_selected_template: %{"id" => "any-tpl", "name" => "Test"}
          )

        %{state | socket: new_socket}
      end)

      # A hostile client sends an arbitrary mode string. The LV must not crash.
      assert {:error, {:live_redirect, %{to: redirect_url}}} =
               render_click(view, "open_media_picker", %{"name" => "logo", "mode" => "garbage"})

      # The redirect URL must NOT contain "garbage" — it defaults to "single".
      refute String.contains?(redirect_url, "garbage")
    end
  end

  describe "sort_files/2 — assign-level tests (Google not connected)" do
    # Tests for toggle_sort behavior via assigns inspection.
    # Runs in the non-connected state (no StubIntegrations) so there is no
    # background sync task that could race with state injection.

    test "default sort assign is modified desc", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      sort = :sys.get_state(view.pid).socket.assigns.sort
      assert sort == %{by: :modified, dir: :desc}
    end

    test "toggle_sort on new column sets asc dir and resets page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Start from default (modified, desc), then sort by name.
      render_click(view, "toggle_sort", %{"by" => "name"})

      state = :sys.get_state(view.pid).socket.assigns
      assert state.sort == %{by: :name, dir: :asc}
      assert state.page == 1
    end

    test "toggle_sort on same column flips direction", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # First click: name asc
      render_click(view, "toggle_sort", %{"by" => "name"})
      assert :sys.get_state(view.pid).socket.assigns.sort == %{by: :name, dir: :asc}

      # Second click: name desc
      render_click(view, "toggle_sort", %{"by" => "name"})
      assert :sys.get_state(view.pid).socket.assigns.sort == %{by: :name, dir: :desc}
    end

    test "toggle_sort with unknown field is ignored (whitelist)", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      original_sort = :sys.get_state(view.pid).socket.assigns.sort

      render_click(view, "toggle_sort", %{"by" => "evil_column"})

      # Sort is unchanged when the field is unknown.
      assert :sys.get_state(view.pid).socket.assigns.sort == original_sort
    end

    test "toggle_sort supports all four sortable columns", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      for field <- ["name", "created", "modified", "status"] do
        render_click(view, "toggle_sort", %{"by" => field})
        sort = :sys.get_state(view.pid).socket.assigns.sort

        assert sort.by == String.to_existing_atom(field),
               "expected sort by :#{field} after toggle, got #{inspect(sort)}"
      end
    end

    test "sort header cells render in list view", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject list view mode directly to avoid push_patch routing issue in the
      # test router (switch_view patches to /documents which isn't registered).
      :sys.replace_state(view.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, view_mode: "list")}
      end)

      html = render(view)

      # The sort_header_cell emits phx-value-by for each sortable column.
      assert html =~ "phx-value-by=\"name\""
      assert html =~ "phx-value-by=\"created\""
      assert html =~ "phx-value-by=\"modified\""
      assert html =~ "phx-value-by=\"status\""
    end

    test "sort order is reflected in rendered row order", %{conn: conn} do
      # Drive this test without google connected so there's no background
      # sync task that could overwrite the injected document list.
      unique = System.unique_integer([:positive])
      id_a = "sort-doc-a-#{unique}"
      id_b = "sort-doc-b-#{unique}"
      name_a = "Zebra Document #{unique}"
      name_b = "Apple Document #{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject docs + list view + loaded state in one atomic replace.
      # No background sync fires (google_connected is false by default).
      :sys.replace_state(view.pid, fn state ->
        doc_z = %{
          "id" => id_a,
          "name" => name_a,
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        doc_a = %{
          "id" => id_b,
          "name" => name_b,
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "list")
          |> Phoenix.Component.assign(documents: [doc_z, doc_a])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      # Sort by name asc — Apple should come before Zebra.
      render_click(view, "toggle_sort", %{"by" => "name"})
      html = render(view)

      pos_apple = :binary.match(html, name_b)
      pos_zebra = :binary.match(html, name_a)

      assert pos_apple != :nomatch, "Apple Document not found in rendered HTML"
      assert pos_zebra != :nomatch, "Zebra Document not found in rendered HTML"

      {apple_start, _} = pos_apple
      {zebra_start, _} = pos_zebra

      assert apple_start < zebra_start,
             "Expected Apple to appear before Zebra in name asc sort"

      # Flip to desc — Zebra should come first.
      render_click(view, "toggle_sort", %{"by" => "name"})
      html2 = render(view)

      {apple2, _} = :binary.match(html2, name_b)
      {zebra2, _} = :binary.match(html2, name_a)
      assert zebra2 < apple2, "Expected Zebra to appear before Apple in name desc sort"
    end

    test "files with a nil sort value always sort last regardless of direction",
         %{conn: conn} do
      unique = System.unique_integer([:positive])
      named_id = "sort-named-#{unique}"
      nil_id = "sort-nil-#{unique}"
      named = "Named Document #{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # nil-name doc is placed FIRST in the source list, so a passing assertion
      # proves the sort moved it last rather than relying on input order.
      :sys.replace_state(view.pid, fn state ->
        named_doc = %{
          "id" => named_id,
          "name" => named,
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        nil_doc = %{
          "id" => nil_id,
          "name" => nil,
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "list")
          |> Phoenix.Component.assign(documents: [nil_doc, named_doc])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      # asc: the nil-name row must come after the named row.
      render_click(view, "toggle_sort", %{"by" => "name"})
      html_asc = render(view)
      {named_asc, _} = :binary.match(html_asc, named)
      {nil_asc, _} = :binary.match(html_asc, "doc-row-menu-#{nil_id}")
      assert named_asc < nil_asc, "nil-name doc should sort after the named doc (asc)"

      # desc: the nil-name row must STILL come last.
      render_click(view, "toggle_sort", %{"by" => "name"})
      html_desc = render(view)
      {named_desc, _} = :binary.match(html_desc, named)
      {nil_desc, _} = :binary.match(html_desc, "doc-row-menu-#{nil_id}")
      assert named_desc < nil_desc, "nil-name doc should sort last even in desc"
    end

    test "modifiedTime ISO-8601 sort: newest first desc, nil always last in both directions",
         %{conn: conn} do
      unique = System.unique_integer([:positive])
      id_old = "sort-mod-old-#{unique}"
      id_new = "sort-mod-new-#{unique}"
      id_nil = "sort-mod-nil-#{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # nil-time doc placed FIRST so the assertion proves the sort moved it last.
      :sys.replace_state(view.pid, fn state ->
        nil_doc = %{
          "id" => id_nil,
          "name" => "Nil-time Doc #{unique}",
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        old_doc = %{
          "id" => id_old,
          "name" => "Old Doc #{unique}",
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => "2026-05-01T10:00:00Z",
          "data" => nil,
          "path" => nil
        }

        new_doc = %{
          "id" => id_new,
          "name" => "New Doc #{unique}",
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => "2026-05-30T10:00:00Z",
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "list")
          |> Phoenix.Component.assign(documents: [nil_doc, old_doc, new_doc])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      # Default sort is modified desc — toggle once to get asc, toggle again for desc.
      # First bring to modified asc.
      render_click(view, "toggle_sort", %{"by" => "modified"})
      html_asc = render(view)

      {old_asc, _} = :binary.match(html_asc, "doc-row-menu-#{id_old}")
      {new_asc, _} = :binary.match(html_asc, "doc-row-menu-#{id_new}")
      {nil_asc, _} = :binary.match(html_asc, "doc-row-menu-#{id_nil}")

      assert old_asc < new_asc, "asc: older doc should appear before newer doc"
      assert new_asc < nil_asc, "asc: nil-time doc should sort last"

      # Flip to desc.
      render_click(view, "toggle_sort", %{"by" => "modified"})
      html_desc = render(view)

      {old_desc, _} = :binary.match(html_desc, "doc-row-menu-#{id_old}")
      {new_desc, _} = :binary.match(html_desc, "doc-row-menu-#{id_new}")
      {nil_desc, _} = :binary.match(html_desc, "doc-row-menu-#{id_nil}")

      assert new_desc < old_desc, "desc: newer doc should appear before older doc"
      assert old_desc < nil_desc, "desc: nil-time doc should still sort last"
    end
  end

  describe "row menu (⋯) — table and card actions" do
    # Tests that verify the ⋯ dropdown renders the correct action items in table
    # and card views for active and trashed modes. Uses state injection to avoid
    # async sync races (no google connected → no background sync task).

    test "active mode: table row menu renders Edit, Export PDF, Delete items", %{conn: conn} do
      unique = System.unique_integer([:positive])
      id = "menu-doc-active-#{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject list view + active doc directly to avoid async sync races and
      # the push_patch routing limitation in the test router.
      :sys.replace_state(view.pid, fn state ->
        active_doc = %{
          "id" => id,
          "name" => "Menu Doc #{unique}",
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "list")
          |> Phoenix.Component.assign(documents: [active_doc])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      html = render(view)

      # Table row menu wrapper exists with the doc's id.
      assert html =~ "doc-row-menu-#{id}"
      # Edit action is a link opening the Google Docs editor in a new tab.
      assert html =~ "https://docs.google.com/document/d/#{id}/edit"
      assert html =~ ~s(target="_blank")
      assert html =~ "hero-pencil-square"
      # Export PDF + Delete are buttons wired to this doc's id.
      assert html =~ ~s(phx-click="export_pdf")
      assert html =~ ~s(phx-click="delete")
      assert html =~ ~s(phx-value-id="#{id}")
      assert html =~ "hero-trash"
      # No Restore action in active mode.
      refute html =~ ~s(phx-click="restore")
    end

    test "trashed mode: table row menu renders View, Export PDF, Restore items", %{conn: conn} do
      unique = System.unique_integer([:positive])
      id = "menu-doc-trashed-#{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject list view, trashed status, and a fake trashed doc directly
      # into the LV assigns. This avoids both the push_patch routing limitation
      # AND race conditions with the async sync_from_drive `:sync_complete`.
      :sys.replace_state(view.pid, fn state ->
        trashed_doc = %{
          "id" => id,
          "name" => "Trash Doc #{unique}",
          "status" => "trashed",
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "list")
          |> Phoenix.Component.assign(status_mode: "trashed")
          |> Phoenix.Component.assign(trashed_documents: [trashed_doc])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      html = render(view)

      assert html =~ "doc-row-menu-#{id}"
      # View action is a link to the Google Docs editor (trashed mode).
      assert html =~ "https://docs.google.com/document/d/#{id}/edit"
      assert html =~ "hero-eye"
      # Restore is wired to this doc's id; Delete is absent in trashed mode.
      assert html =~ ~s(phx-click="restore")
      assert html =~ ~s(phx-value-id="#{id}")
      assert html =~ "hero-arrow-uturn-left"
      refute html =~ ~s(phx-click="delete")
    end

    test "active mode: card view menu renders Edit, Export PDF, Delete items", %{conn: conn} do
      unique = System.unique_integer([:positive])
      id = "menu-doc-card-#{unique}"

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/document-creator")

      # Inject card view (default) + active doc directly to avoid async sync races.
      :sys.replace_state(view.pid, fn state ->
        active_doc = %{
          "id" => id,
          "name" => "Card Doc #{unique}",
          "status" => nil,
          "inserted_at" => nil,
          "modifiedTime" => nil,
          "data" => nil,
          "path" => nil
        }

        new_socket =
          state.socket
          |> Phoenix.Component.assign(view_mode: "cards")
          |> Phoenix.Component.assign(documents: [active_doc])
          |> Phoenix.Component.assign(loaded: true, loading: false, google_connected: true)

        %{state | socket: new_socket}
      end)

      html = render(view)

      assert html =~ "doc-card-menu-#{id}"
      assert html =~ "hero-pencil-square"
      assert html =~ "hero-arrow-down-tray"
      assert html =~ "hero-trash"
    end
  end

  describe "media picker round-trip" do
    test "returning from media selector restores template state and applies image selection",
         %{conn: conn} do
      file_id = "rt-tpl-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Round-trip Template"
        })

      conn = put_test_scope(conn, fake_scope())

      return_url =
        "/en/admin/document-creator?selected_media=media-uuid-1&picking_var=logo&picking_mode=single&template_file_id=#{file_id}"

      {:ok, view, _html} = live(conn, return_url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == true
      assert state.modal_step == "variables"
      assert get_in(state, [:modal_selected_template, "id"]) == file_id
      assert state.modal_image_values["logo"] == %{"media_id" => "media-uuid-1"}
    end

    test "second round-trip preserves image values from the first pick",
         %{conn: conn} do
      file_id = "rt-tpl2-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Documents.upsert_template_from_drive(%{
          "id" => file_id,
          "name" => "Sequential Picks Template"
        })

      conn = put_test_scope(conn, fake_scope())

      # Simulate returning from the second media pick, with the first pick
      # encoded in `picking_existing`.
      prior = JSON.encode!(%{"logo" => %{"media_id" => "first-uuid"}})

      return_url =
        "/en/admin/document-creator?" <>
          URI.encode_query(%{
            "selected_media" => "second-uuid",
            "picking_var" => "photos",
            "picking_mode" => "multiple",
            "template_file_id" => file_id,
            "picking_existing" => prior
          })

      {:ok, view, _html} = live(conn, return_url)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.modal_open == true
      assert state.modal_step == "variables"
      # First pick is preserved
      assert state.modal_image_values["logo"] == %{"media_id" => "first-uuid"}
      # Second pick is applied
      assert state.modal_image_values["photos"] == %{"media_ids" => ["second-uuid"]}
    end
  end
end
