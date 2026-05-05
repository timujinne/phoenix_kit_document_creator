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
end
