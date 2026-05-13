defmodule PhoenixKitDocumentCreator.Documents.ComposedDocumentTest do
  use PhoenixKitDocumentCreator.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.Schemas.{Document, DocumentSection, Template}
  alias PhoenixKitDocumentCreator.Test.StubDocsClientHelpers

  import StubDocsClientHelpers

  setup do
    stub_google_docs_client!()
    :ok
  end

  defp insert_template!(opts) do
    unique = System.unique_integer([:positive])
    google_doc_id = Keyword.get(opts, :google_doc_id, "tmpl-#{unique}")
    published = Keyword.get(opts, :published, true)
    status = if published, do: "published", else: "trashed"

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{
        name: "Template #{unique}",
        google_doc_id: google_doc_id,
        status: status
      })
      |> Repo.insert()

    template
  end

  describe "create_composed_document/2 — happy path" do
    test "creates one document with N section rows, copies first template, appends rest" do
      t1 = insert_template!(google_doc_id: "tmpl-1", published: true)
      t2 = insert_template!(google_doc_id: "tmpl-2", published: true)

      # Both sections use the same key "name" — range-scoped substitution means
      # section 0 resolves {{name}} → "Alice" and section 1 resolves {{name}} → "Bob"
      # independently, each within its own character range.
      sections = [
        %{
          template_uuid: t1.uuid,
          position: 0,
          variable_values: %{"name" => "Alice"},
          image_params: %{}
        },
        %{
          template_uuid: t2.uuid,
          position: 1,
          variable_values: %{"name" => "Bob"},
          image_params: %{}
        }
      ]

      user = Ecto.UUID.generate()

      assert {:ok, %Document{} = doc} =
               Documents.create_composed_document(sections,
                 created_by_uuid: user,
                 name: "Test composed doc"
               )

      assert doc.google_doc_id == "copy-of-tmpl-1"

      rows =
        Repo.all(
          from(s in DocumentSection,
            where: s.document_uuid == ^doc.uuid,
            order_by: s.position
          )
        )

      assert [%{position: 0, template_uuid: t1uuid}, %{position: 1, template_uuid: t2uuid}] =
               rows

      assert t1uuid == t1.uuid
      assert t2uuid == t2.uuid

      # copy_document → document_content_range (section 0 range) → append_template
      # (section 1) → substitute_all_sections (single atomic pass for all sections).
      assert_google_docs_calls_in_order([
        :copy_document,
        :document_content_range,
        :append_template,
        :substitute_all_sections
      ])
    end

    test "defaults to :page_break separator and raises on unsupported values" do
      t1 = insert_template!(google_doc_id: "tmpl-1", published: true)
      section = %{template_uuid: t1.uuid, position: 0, variable_values: %{}, image_params: %{}}
      user = Ecto.UUID.generate()

      assert {:ok, %Document{}} =
               Documents.create_composed_document([section],
                 created_by_uuid: user,
                 name: "Sep default"
               )

      assert {:ok, %Document{}} =
               Documents.create_composed_document([section],
                 created_by_uuid: user,
                 name: "Sep pb",
                 separator: :page_break
               )

      assert_raise ArgumentError, ~r/unsupported separator/, fn ->
        Documents.create_composed_document([section],
          created_by_uuid: user,
          name: "Sep bad",
          separator: :blank_line
        )
      end
    end

    test "single-section document does not call append_template" do
      t1 = insert_template!(google_doc_id: "tmpl-single", published: true)
      section = %{template_uuid: t1.uuid, position: 0, variable_values: %{}, image_params: %{}}

      assert {:ok, %Document{}} =
               Documents.create_composed_document([section],
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Single"
               )

      assert_google_docs_calls_in_order([
        :copy_document,
        :document_content_range,
        :substitute_all_sections
      ])
    end
  end

  describe "create_composed_document/2 — validation" do
    test "returns error for empty sections" do
      assert {:error, :empty_sections} =
               Documents.create_composed_document([],
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Empty"
               )
    end

    test "returns error for unknown template_uuid" do
      missing = Ecto.UUID.generate()

      assert {:error, {:unknown_templates, [^missing]}} =
               Documents.create_composed_document(
                 [
                   %{template_uuid: missing, position: 0, variable_values: %{}, image_params: %{}}
                 ],
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Missing"
               )
    end

    test "returns error for unpublished template" do
      t = insert_template!(published: false)

      assert {:error, {:unpublished_templates, [_]}} =
               Documents.create_composed_document(
                 [%{template_uuid: t.uuid, position: 0, variable_values: %{}, image_params: %{}}],
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Unpublished"
               )
    end

    test "returns error for duplicate positions" do
      t = insert_template!(published: true)

      sections = [
        %{template_uuid: t.uuid, position: 0, variable_values: %{}, image_params: %{}},
        %{template_uuid: t.uuid, position: 0, variable_values: %{}, image_params: %{}}
      ]

      assert {:error, {:duplicate_positions, [0]}} =
               Documents.create_composed_document(sections,
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Dup"
               )
    end
  end

  describe "create_composed_document/2 — rollback and cleanup (5c)" do
    test "rolls back DB and deletes the Google Doc when substitution fails" do
      t1 = insert_template!(google_doc_id: "tmpl-1", published: true)
      t2 = insert_template!(google_doc_id: "tmpl-2", published: true)

      stub_substitute_in_range_error!(:any, :rate_limited)

      sections = [
        %{template_uuid: t1.uuid, position: 0, variable_values: %{}, image_params: %{}},
        %{template_uuid: t2.uuid, position: 1, variable_values: %{}, image_params: %{}}
      ]

      assert {:error, :rate_limited} =
               Documents.create_composed_document(sections,
                 created_by_uuid: Ecto.UUID.generate(),
                 name: "Rollback test"
               )

      assert Repo.aggregate(Document, :count) == 0
      assert Repo.aggregate(DocumentSection, :count) == 0
      assert_google_doc_deleted!("copy-of-tmpl-1")
    end

    test "logs but does not fail if cleanup deletion fails" do
      t1 = insert_template!(google_doc_id: "tmpl-1", published: true)

      stub_substitute_in_range_error!(:any, :boom)
      stub_delete_document_error!(:gone)

      log =
        capture_log(fn ->
          assert {:error, :boom} =
                   Documents.create_composed_document(
                     [
                       %{
                         template_uuid: t1.uuid,
                         position: 0,
                         variable_values: %{},
                         image_params: %{}
                       }
                     ],
                     created_by_uuid: Ecto.UUID.generate(),
                     name: "Cleanup fail"
                   )
        end)

      assert log =~ "orphaned google doc"
    end
  end
end
