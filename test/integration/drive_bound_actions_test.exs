defmodule PhoenixKitDocumentCreator.Integration.DriveBoundActionsTest do
  @moduledoc """
  Happy-path coverage for the Drive-bound actions that were
  previously documented as uncovered in
  `activity_logging_test.exs:118-145`. The Batch 4 retrofit on
  `GoogleDocsClient` (resolver-injected `integrations_backend`) lets
  these tests stub the Drive API contract without external HTTP
  traffic, pinning the `:ok`-branch activity-log rows for every
  action.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Schemas.Template
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

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  describe "create_template/2 — happy path" do
    test "logs template.created on :ok with safe metadata" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_create!("drv-tpl-1", "Created Tpl")

      assert {:ok, %{doc_id: "drv-tpl-1", url: url}} =
               Documents.create_template("Created Tpl", actor_uuid: actor_uuid)

      assert is_binary(url)

      row =
        assert_activity_logged("template.created",
          actor_uuid: actor_uuid,
          metadata_has: %{
            "google_doc_id" => "drv-tpl-1",
            "name" => "Created Tpl"
          }
        )

      assert row.resource_type == "template"
      refute Map.has_key?(row.metadata, "db_pending")
    end

    test "logs db_pending row when Drive returns 5xx" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => %{"message" => "drive down"}}}}
      )

      assert {:error, :create_document_failed} =
               Documents.create_template("Drive Down Tpl", actor_uuid: actor_uuid)

      assert_activity_logged("template.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"db_pending" => true, "name" => "Drive Down Tpl"}
      )
    end
  end

  describe "create_document/2 — happy path" do
    test "logs document.created on :ok with safe metadata" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_create!("drv-doc-1", "Created Doc")

      assert {:ok, %{doc_id: "drv-doc-1"}} =
               Documents.create_document("Created Doc", actor_uuid: actor_uuid)

      assert_activity_logged("document.created",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "drv-doc-1", "name" => "Created Doc"}
      )
    end
  end

  describe "delete_document/2 — happy path" do
    test "logs document.deleted on :ok" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_move!("drv-doc-2")

      assert :ok = Documents.delete_document("drv-doc-2", actor_uuid: actor_uuid)

      row =
        assert_activity_logged("document.deleted",
          actor_uuid: actor_uuid,
          metadata_has: %{"google_doc_id" => "drv-doc-2"}
        )

      refute Map.has_key?(row.metadata, "db_pending")
    end
  end

  describe "delete_template/2 — happy path" do
    test "logs template.deleted on :ok" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_move!("drv-tpl-2")

      assert :ok = Documents.delete_template("drv-tpl-2", actor_uuid: actor_uuid)

      assert_activity_logged("template.deleted",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "drv-tpl-2"}
      )
    end
  end

  describe "delete_document/2 — data[\"deleted\"] stamping" do
    test "stamps data[deleted] with at and by_uuid when a DB record exists" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "drv-doc-del-data-1"

      {:ok, _} = Documents.register_existing_document(%{google_doc_id: file_id, name: "Doc"})

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.delete_document(file_id, actor_uuid: actor_uuid)

      record = TestRepo.get_by!(Document, google_doc_id: file_id)
      assert %{"deleted" => deleted} = record.data
      assert deleted["by_uuid"] == actor_uuid
      assert is_binary(deleted["at"])
      assert {:ok, _dt, _} = DateTime.from_iso8601(deleted["at"])
    end

    test "stamps data[deleted] with nil by_uuid when no actor_uuid given" do
      file_id = "drv-doc-del-data-2"

      {:ok, _} = Documents.register_existing_document(%{google_doc_id: file_id, name: "Doc"})

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.delete_document(file_id)

      record = TestRepo.get_by!(Document, google_doc_id: file_id)
      assert %{"deleted" => deleted} = record.data
      assert is_nil(deleted["by_uuid"])
    end

    test "preserves other data keys when stamping deleted" do
      file_id = "drv-doc-del-data-3"
      actor_uuid = Ecto.UUID.generate()

      {:ok, doc} = Documents.register_existing_document(%{google_doc_id: file_id, name: "Doc"})
      # Manually set an existing data key that must survive the delete stamp.
      TestRepo.update!(Document.changeset(doc, %{data: %{"recipe" => "preserved"}}))

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.delete_document(file_id, actor_uuid: actor_uuid)

      record = TestRepo.get_by!(Document, google_doc_id: file_id)
      assert record.data["recipe"] == "preserved"
      assert is_map(record.data["deleted"])
    end
  end

  describe "delete_template/2 — data[\"deleted\"] stamping" do
    test "stamps data[deleted] with at and by_uuid when a DB record exists" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "drv-tpl-del-data-1"

      {:ok, _} = Documents.register_existing_template(%{google_doc_id: file_id, name: "Tpl"})

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.delete_template(file_id, actor_uuid: actor_uuid)

      record = TestRepo.get_by!(Template, google_doc_id: file_id)
      assert %{"deleted" => deleted} = record.data
      assert deleted["by_uuid"] == actor_uuid
      assert is_binary(deleted["at"])
    end
  end

  describe "restore_document/2 — happy path" do
    test "logs document.restored on :ok" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_move!("drv-doc-3")

      assert :ok = Documents.restore_document("drv-doc-3", actor_uuid: actor_uuid)

      assert_activity_logged("document.restored",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "drv-doc-3"}
      )
    end
  end

  describe "restore_template/2 — happy path" do
    test "logs template.restored on :ok" do
      actor_uuid = Ecto.UUID.generate()

      stub_folder_resolution!()
      stub_drive_move!("drv-tpl-3")

      assert :ok = Documents.restore_template("drv-tpl-3", actor_uuid: actor_uuid)

      assert_activity_logged("template.restored",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => "drv-tpl-3"}
      )
    end
  end

  describe "restore_document/2 — data[\"deleted\"] clearing" do
    test "clears data[deleted] on restore when DB record exists" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "drv-doc-restore-data-1"

      {:ok, doc} = Documents.register_existing_document(%{google_doc_id: file_id, name: "Doc"})

      TestRepo.update!(
        Document.changeset(doc, %{
          data: %{
            "deleted" => %{"at" => "2025-01-01T00:00:00Z", "by_uuid" => actor_uuid},
            "recipe" => "preserved"
          }
        })
      )

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.restore_document(file_id, actor_uuid: actor_uuid)

      record = TestRepo.get_by!(Document, google_doc_id: file_id)
      refute Map.has_key?(record.data, "deleted")
      assert record.data["recipe"] == "preserved"
    end
  end

  describe "restore_template/2 — data[\"deleted\"] clearing" do
    test "clears data[deleted] on restore when DB record exists" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "drv-tpl-restore-data-1"

      {:ok, tpl} = Documents.register_existing_template(%{google_doc_id: file_id, name: "Tpl"})

      TestRepo.update!(
        Template.changeset(tpl, %{
          data: %{
            "deleted" => %{"at" => "2025-01-01T00:00:00Z", "by_uuid" => actor_uuid},
            "recipe" => "preserved"
          }
        })
      )

      stub_folder_resolution!()
      stub_drive_move!(file_id)

      assert :ok = Documents.restore_template(file_id, actor_uuid: actor_uuid)

      record = TestRepo.get_by!(Template, google_doc_id: file_id)
      refute Map.has_key?(record.data, "deleted")
      assert record.data["recipe"] == "preserved"
    end
  end

  describe "export_pdf/2 — happy path" do
    test "logs document.exported_pdf on :ok with size_bytes" do
      actor_uuid = Ecto.UUID.generate()
      pdf_body = String.duplicate("PDF", 100)

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/drv-doc-4/export",
        {:ok, %{status: 200, body: pdf_body, headers: %{"content-type" => ["application/pdf"]}}}
      )

      assert {:ok, ^pdf_body} =
               Documents.export_pdf("drv-doc-4", actor_uuid: actor_uuid, name: "Export.pdf")

      row =
        assert_activity_logged("document.exported_pdf",
          actor_uuid: actor_uuid,
          metadata_has: %{
            "google_doc_id" => "drv-doc-4",
            "name" => "Export.pdf",
            "size_bytes" => byte_size(pdf_body)
          }
        )

      refute Map.has_key?(row.metadata, "db_pending")
    end
  end

  describe "create_document_from_template/3 — happy path" do
    test "logs document.created_from_template after Drive copy + replace" do
      actor_uuid = Ecto.UUID.generate()
      stub_folder_resolution!()

      # Drive copy_file → returns the new document ID
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/tpl-src/copy",
        {:ok, %{status: 200, body: %{"id" => "drv-doc-5"}}}
      )

      # Drive replace_all_text via batchUpdate
      StubIntegrations.stub_request(
        :post,
        "/documents/drv-doc-5:batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      assert {:ok, %{doc_id: "drv-doc-5"}} =
               Documents.create_document_from_template(
                 "tpl-src",
                 %{"client" => "Acme"},
                 name: "From Tpl",
                 actor_uuid: actor_uuid
               )

      row =
        assert_activity_logged("document.created_from_template",
          actor_uuid: actor_uuid,
          metadata_has: %{
            "google_doc_id" => "drv-doc-5",
            "template_google_doc_id" => "tpl-src",
            "name" => "From Tpl"
          }
        )

      assert "client" in row.metadata["variables_used"]
      # PII audit: never log the variable values, only the keys.
      refute Map.has_key?(row.metadata, "variable_values")
    end
  end

  describe "set_correct_location/2 — happy path" do
    test "logs file.location_accepted on :ok" do
      actor_uuid = Ecto.UUID.generate()
      file_id = "drv-doc-6"

      # Seed a record so find_file_record/1 succeeds.
      {:ok, _} =
        Documents.register_existing_document(%{google_doc_id: file_id, name: "Existing"})

      # Test scenario: file's parent is "root", so resolve_folder_path/2
      # short-circuits at the "root" -> {:ok, ""} clause without further
      # GETs. The activity row records folder_id = "root".
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/#{file_id}",
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => file_id,
             "name" => "Existing",
             "parents" => ["root"],
             "trashed" => false
           }
         }}
      )

      assert :ok = Documents.set_correct_location(file_id, actor_uuid: actor_uuid)

      assert_activity_logged("file.location_accepted",
        actor_uuid: actor_uuid,
        metadata_has: %{"google_doc_id" => file_id, "folder_id" => "root"}
      )
    end
  end

  # ── Drive 404 handling ─────────────────────────────────────────────────

  describe "restore_document/2 — Drive 404 (file deleted from Drive)" do
    test "returns {:error, :drive_file_not_found} when GET parents returns 404" do
      file_id = "drv-doc-404-get"
      stub_folder_resolution!()

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok,
         %{status: 404, body: %{"error" => %{"code" => 404, "message" => "File not found."}}}}
      )

      assert {:error, :drive_file_not_found} =
               Documents.restore_document(file_id, actor_uuid: Ecto.UUID.generate())
    end

    test "returns {:error, :drive_file_not_found} when PATCH move returns 404" do
      file_id = "drv-doc-404-patch"
      stub_folder_resolution!()

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old-parent"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok,
         %{status: 404, body: %{"error" => %{"code" => 404, "message" => "File not found."}}}}
      )

      assert {:error, :drive_file_not_found} =
               Documents.restore_document(file_id, actor_uuid: Ecto.UUID.generate())
    end
  end

  describe "restore_template/2 — Drive 404 (file deleted from Drive)" do
    test "returns {:error, :drive_file_not_found} when Drive returns 404" do
      file_id = "drv-tpl-404"
      stub_folder_resolution!()

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok,
         %{status: 404, body: %{"error" => %{"code" => 404, "message" => "File not found."}}}}
      )

      assert {:error, :drive_file_not_found} =
               Documents.restore_template(file_id, actor_uuid: Ecto.UUID.generate())
    end
  end

  # ── Test stub helpers ─────────────────────────────────────────────────

  # `Documents.create_template/2` (and friends) call `get_folder_ids/0` →
  # `Settings.get_json_setting(...)`. In the test sandbox the cached
  # folder map is empty, so the call falls through to
  # `discover_folders/0` which spawns four parallel folder-resolution
  # tasks. To keep the test sandbox-friendly, seed the folder cache
  # directly via the Settings API so `get_folder_ids/0` returns canned
  # IDs without making any outbound API call.
  defp stub_folder_resolution! do
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

  defp stub_drive_create!(doc_id, name) do
    StubIntegrations.stub_request(
      :post,
      "/drive/v3/files",
      {:ok, %{status: 200, body: %{"id" => doc_id, "name" => name}}}
    )
  end

  # The `move_file/2` flow does GET parents → PATCH addParents+removeParents.
  # Stub both halves with a single helper.
  defp stub_drive_move!(file_id) do
    StubIntegrations.stub_request(
      :get,
      ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
      {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old-parent"]}}}
    )

    StubIntegrations.stub_request(
      :patch,
      "/drive/v3/files/#{file_id}",
      {:ok, %{status: 200, body: %{"id" => file_id}}}
    )
  end
end
