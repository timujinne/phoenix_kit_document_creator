defmodule PhoenixKitDocumentCreator.Documents.RenameDocumentTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.Document
  alias PhoenixKitDocumentCreator.Test.StubDocsClientHelpers

  import StubDocsClientHelpers

  setup do
    stub_google_docs_client!()
    :ok
  end

  defp insert_document!(opts \\ []) do
    unique = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        name: Keyword.get(opts, :name, "Document #{unique}"),
        google_doc_id: Keyword.get(opts, :google_doc_id, "gdoc-#{unique}"),
        status: "active"
      })
      |> Repo.insert()

    doc
  end

  describe "rename_document/2 — happy path" do
    test "renames the document in Drive and updates the DB record" do
      doc = insert_document!(name: "Old Name", google_doc_id: "gdoc-abc")

      assert {:ok, updated} = Documents.rename_document(doc.uuid, "New Name")
      assert updated.name == "New Name"

      # Verify DB was updated
      reloaded = Repo.get(Document, doc.uuid)
      assert reloaded.name == "New Name"
    end

    test "calls rename_file on the Drive client with the document's google_doc_id" do
      doc = insert_document!(name: "Old Name", google_doc_id: "gdoc-xyz")

      assert {:ok, _updated} = Documents.rename_document(doc.uuid, "Renamed")

      assert Enum.any?(
               PhoenixKitDocumentCreator.Test.StubDocsClient.calls(),
               fn
                 {:rename_file, "gdoc-xyz"} -> true
                 _ -> false
               end
             )
    end
  end

  describe "rename_document/2 — blank name rejection" do
    test "returns {:error, :blank_name} for an empty string" do
      doc = insert_document!()
      assert {:error, :blank_name} = Documents.rename_document(doc.uuid, "")
    end

    test "returns {:error, :blank_name} for a whitespace-only string" do
      doc = insert_document!()
      assert {:error, :blank_name} = Documents.rename_document(doc.uuid, "   ")
    end
  end

  describe "rename_document/2 — not found" do
    test "returns {:error, :not_found} for a non-existent uuid" do
      assert {:error, :not_found} =
               Documents.rename_document(Ecto.UUID.generate(), "Whatever")
    end
  end

  describe "rename_document/2 — Drive error propagation" do
    test "returns the Drive error when rename_file fails" do
      doc = insert_document!(name: "Existing", google_doc_id: "gdoc-fail")
      StubDocsClientHelpers.stub_rename_file_error!({:api_error, "Drive API 500"})

      assert {:error, {:api_error, "Drive API 500"}} =
               Documents.rename_document(doc.uuid, "New Name")

      # DB record should remain unchanged
      reloaded = Repo.get(Document, doc.uuid)
      assert reloaded.name == "Existing"
    end
  end
end
