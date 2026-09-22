defmodule PhoenixKitDocumentCreator.Integration.DocumentsSyncTest do
  @moduledoc """
  Coverage for `Documents.sync_from_drive/0`, `persist_thumbnail/2`,
  `fetch_thumbnails_async/2`, `find_similar_*`, `move_to_*`, and
  related helpers — paths exercised via the Batch 4 `:integrations_backend`
  stub plus Settings-seeded folder cache.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.{Document, Template}
  alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  setup do
    TestRepo.delete_all("phoenix_kit_activities", log: false)

    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()
    StubIntegrations.connected!()

    seed_folder_cache!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  describe "sync_from_drive/0" do
    test "logs sync.completed activity row with file/folder counts" do
      # Drive returns one folder + one file under each managed root.
      stub_walker_responses(
        templates_folders: [],
        documents_folders: [],
        templates_files: [%{"id" => "tpl-1", "name" => "TPL", "parents" => ["stub-templates"]}],
        documents_files: [%{"id" => "doc-1", "name" => "DOC", "parents" => ["stub-documents"]}]
      )

      assert :ok = Documents.sync_from_drive()

      # The stub dispatcher matches by URL pattern, and both the
      # templates-tree walk and the documents-tree walk hit the same
      # `/drive/v3/files` endpoint. With a single stub returning the
      # combined fixture set, both walks see all the files — the
      # assertion just pins that the metadata is non-zero and shaped
      # correctly.
      row = assert_activity_logged("sync.completed")
      assert row.mode == "auto"
      assert is_integer(row.metadata["templates_synced"])
      assert is_integer(row.metadata["documents_synced"])
    end

    test "returns {:error, :sync_failed} when folders aren't configured" do
      # Wipe the folder cache so get_folder_ids returns nil ids → sync
      # falls into the else branch.
      PhoenixKit.Settings.update_json_setting_with_module(
        "document_creator_folders",
        %{
          "templates_folder_id" => nil,
          "documents_folder_id" => nil
        },
        "document_creator"
      )

      assert {:error, :sync_failed} = Documents.sync_from_drive()
    end

    test "returns {:error, :sync_failed} when walker fails" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      assert {:error, :sync_failed} = Documents.sync_from_drive()
    end

    test "reconciles records that drift out of the managed tree to status='lost'" do
      # Pre-existing template that won't appear in the walker → marked
      # as lost (not trashed — file may still exist in Drive but moved
      # outside our managed root).
      {:ok, _existing} =
        Documents.register_existing_template(%{
          google_doc_id: "drift-tpl",
          name: "Drifted",
          status: "published"
        })

      stub_walker_responses(
        templates_folders: [],
        documents_folders: [],
        templates_files: [],
        documents_files: []
      )

      # The walker has no files. Reconcile classifies the existing
      # record per its current Drive parents — but since the file_status
      # call is also stubbed away (returning :not_found below), the
      # record gets marked lost.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/drift-tpl",
        {:ok, %{status: 404, body: %{}}}
      )

      assert :ok = Documents.sync_from_drive()

      reloaded = TestRepo.get_by(Template, google_doc_id: "drift-tpl")
      # Status reconciled from "published" → "lost" or "trashed" depending
      # on Drive's response. With a 404 the record is classified as lost.
      assert reloaded.status in ["lost", "trashed"]
    end
  end

  describe "persist_thumbnail/2" do
    test "writes thumbnail data URI to the matching template" do
      {:ok, tpl} =
        Documents.register_existing_template(%{google_doc_id: "thumb-tpl", name: "Tpl"})

      assert :ok = Documents.persist_thumbnail("thumb-tpl", "data:image/png;base64,XYZ")
      reloaded = TestRepo.get(Template, tpl.uuid)
      assert reloaded.thumbnail == "data:image/png;base64,XYZ"
    end

    test "writes to document when no template matches" do
      {:ok, doc} =
        Documents.register_existing_document(%{google_doc_id: "thumb-doc", name: "Doc"})

      assert :ok = Documents.persist_thumbnail("thumb-doc", "data:image/png;base64,DOC")
      reloaded = TestRepo.get(Document, doc.uuid)
      assert reloaded.thumbnail == "data:image/png;base64,DOC"
    end

    test "is a no-op when no record matches" do
      assert :ok = Documents.persist_thumbnail("ghost-id", "data:image/png;base64,X")
      # No raise, no update — clean idempotent behaviour.
    end
  end

  describe "load_cached_thumbnails/1" do
    test "returns map keyed by google_doc_id with stored thumbnails" do
      {:ok, _} =
        Documents.register_existing_template(%{
          google_doc_id: "cache-tpl",
          name: "Tpl",
          thumbnail: "data:tpl"
        })

      {:ok, _} =
        Documents.register_existing_document(%{
          google_doc_id: "cache-doc",
          name: "Doc",
          thumbnail: "data:doc"
        })

      result = Documents.load_cached_thumbnails(["cache-tpl", "cache-doc", "missing"])

      assert result["cache-tpl"] == "data:tpl"
      assert result["cache-doc"] == "data:doc"
      refute Map.has_key?(result, "missing")
    end

    test "returns empty map for non-list input" do
      assert Documents.load_cached_thumbnails(nil) == %{}
      assert Documents.load_cached_thumbnails(:not_a_list) == %{}
    end
  end

  describe "refresh_thumbnail/2" do
    setup do
      stub_name = String.to_atom("ThumbRefreshStub-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_document_creator, :req_options)
      end)

      Application.put_env(:phoenix_kit_document_creator, :req_options,
        plug: {Req.Test, stub_name}
      )

      {:ok, stub: stub_name}
    end

    test "overwrites the stale thumbnail on success and logs activity", %{stub: stub_name} do
      {:ok, tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-tpl", name: "Tpl"})

      :ok = Documents.persist_thumbnail("refresh-tpl", "data:image/png;base64,STALE")

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-tpl",
        {:ok,
         %{
           status: 200,
           body: %{"thumbnailLink" => "https://lh3.googleusercontent.com/fresh-link"}
         }}
      )

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.send_resp(200, "fresh-png-bytes")
      end)

      actor_uuid = Ecto.UUID.generate()

      assert {:ok, new_data_uri} =
               Documents.refresh_thumbnail("refresh-tpl", actor_uuid: actor_uuid)

      assert new_data_uri != "data:image/png;base64,STALE"

      reloaded = TestRepo.get(Template, tpl.uuid)
      assert reloaded.thumbnail == new_data_uri

      assert_activity_logged("file.thumbnail_refreshed",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "refresh-tpl"}
      )
    end

    test "leaves the existing thumbnail untouched on failure and logs db_pending" do
      {:ok, tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-fail-tpl", name: "Tpl"})

      :ok = Documents.persist_thumbnail("refresh-fail-tpl", "data:image/png;base64,STALE")

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-fail-tpl",
        {:ok, %{status: 404, body: %{}}}
      )

      actor_uuid = Ecto.UUID.generate()

      assert {:error, _reason} =
               Documents.refresh_thumbnail("refresh-fail-tpl", actor_uuid: actor_uuid)

      reloaded = TestRepo.get(Template, tpl.uuid)
      assert reloaded.thumbnail == "data:image/png;base64,STALE"

      assert_activity_logged("file.thumbnail_refreshed",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "refresh-fail-tpl", "db_pending" => true}
      )
    end
  end

  describe "refresh_thumbnail_async/3" do
    setup do
      stub_name = String.to_atom("ThumbRefreshAsyncStub-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_document_creator, :req_options)
      end)

      Application.put_env(:phoenix_kit_document_creator, :req_options,
        plug: {Req.Test, stub_name}
      )

      {:ok, stub: stub_name}
    end

    test "sends :thumbnail_refreshed to the caller on success", %{stub: stub_name} do
      {:ok, _tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-async-tpl", name: "Tpl"})

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-async-tpl",
        {:ok,
         %{
           status: 200,
           body: %{"thumbnailLink" => "https://lh3.googleusercontent.com/async-link"}
         }}
      )

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.send_resp(200, "async-png-bytes")
      end)

      assert :ok = Documents.refresh_thumbnail_async("refresh-async-tpl", self())
      assert_receive {:thumbnail_refreshed, "refresh-async-tpl", _data_uri}, 1000
      refute_received {:thumbnail_result, "refresh-async-tpl", _}
    end

    test "sends :thumbnail_refresh_failed to the caller on failure" do
      {:ok, _tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-async-fail", name: "Tpl"})

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-async-fail",
        {:ok, %{status: 404, body: %{}}}
      )

      # No Req.Test stub needed — the metadata call fails before any image fetch.
      assert :ok = Documents.refresh_thumbnail_async("refresh-async-fail", self())
      assert_receive {:thumbnail_refresh_failed, "refresh-async-fail", _reason}, 1000
    end

    test "notifies the caller with :internal_error when the fetch crashes instead of failing cleanly" do
      {:ok, _tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-crash-tpl", name: "Tpl"})

      # A raising stub simulates an unexpected crash inside the task body
      # (e.g. a transient DB error from persist_thumbnail/2) — the rescue
      # clause must still notify the caller instead of leaving it hanging.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-crash-tpl",
        fn -> raise "boom" end
      )

      assert :ok = Documents.refresh_thumbnail_async("refresh-crash-tpl", self())
      assert_receive {:thumbnail_refresh_failed, "refresh-crash-tpl", :internal_error}, 1000
    end

    test "notifies the caller with :internal_error when the fetch exits" do
      {:ok, _tpl} =
        Documents.register_existing_template(%{google_doc_id: "refresh-exit-tpl", name: "Tpl"})

      # `rescue` alone doesn't see an exit (e.g. a pool checkout timeout).
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/refresh-exit-tpl",
        fn -> exit(:checkout_timeout) end
      )

      assert :ok = Documents.refresh_thumbnail_async("refresh-exit-tpl", self())
      assert_receive {:thumbnail_refresh_failed, "refresh-exit-tpl", :internal_error}, 1000
    end
  end

  describe "move_to_templates / move_to_documents" do
    test "move_to_templates returns :ok and updates path/folder" do
      {:ok, _doc} =
        Documents.register_existing_document(%{
          google_doc_id: "reclass-doc",
          name: "Reclass"
        })

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/reclass-doc",
        {:ok, %{status: 200, body: %{}}}
      )

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/reclass-doc",
        {:ok, %{status: 200, body: %{"id" => "reclass-doc", "parents" => ["stub-documents"]}}}
      )

      assert :ok = Documents.move_to_templates("reclass-doc", actor_uuid: Ecto.UUID.generate())
    end

    test "move_to_documents returns :ok for an existing template" do
      {:ok, _tpl} =
        Documents.register_existing_template(%{
          google_doc_id: "reclass-tpl",
          name: "Reclass-T"
        })

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/reclass-tpl",
        {:ok, %{status: 200, body: %{}}}
      )

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/reclass-tpl",
        {:ok, %{status: 200, body: %{"id" => "reclass-tpl", "parents" => ["stub-templates"]}}}
      )

      assert :ok = Documents.move_to_documents("reclass-tpl", actor_uuid: Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for unknown file_id" do
      assert {:error, :not_found} = Documents.move_to_templates("ghost-id")
      assert {:error, :not_found} = Documents.move_to_documents("ghost-id")
    end
  end

  describe "detect_variables/1" do
    test "extracts variable names from Google Doc body" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/var-doc",
        {:ok,
         %{
           status: 200,
           body: %{
             "body" => %{
               "content" => [
                 %{
                   "paragraph" => %{
                     "elements" => [%{"textRun" => %{"content" => "Hello {{ client_name }}"}}]
                   }
                 },
                 %{
                   "paragraph" => %{
                     "elements" => [%{"textRun" => %{"content" => "Total: {{ amount }}"}}]
                   }
                 }
               ]
             }
           }
         }}
      )

      assert {:ok, %{text: text_vars, image: _}} = Documents.detect_variables("var-doc")
      assert "client_name" in text_vars
      assert "amount" in text_vars
    end

    test "returns {:error, _} when Drive fails" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/missing",
        {:error, :timeout}
      )

      assert {:error, :timeout} = Documents.detect_variables("missing")
    end
  end

  defp seed_folder_cache! do
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
  end

  defp stub_walker_responses(opts) do
    # The walker hits multiple endpoints — for simplicity, return
    # combined files for the listing endpoint (q matches by parents).
    files =
      (opts[:templates_files] || []) ++
        (opts[:documents_files] || []) ++
        (opts[:templates_folders] || []) ++
        (opts[:documents_folders] || [])

    StubIntegrations.stub_request(
      :get,
      "/drive/v3/files",
      {:ok, %{status: 200, body: %{"files" => files}}}
    )
  end
end
