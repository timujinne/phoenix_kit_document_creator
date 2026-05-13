if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.ImageSlotsTest do
    use PhoenixKitDocumentCreator.DataCase, async: false

    alias PhoenixKitDocumentCreator.Documents

    defmodule StubDocsClient do
      def get_document_text(doc_id) do
        case Process.get({:stub_doc_text, doc_id}) do
          nil -> {:error, :not_found}
          text -> {:ok, text}
        end
      end
    end

    setup do
      prev = Application.get_env(:phoenix_kit_document_creator, :docs_client)
      Application.put_env(:phoenix_kit_document_creator, :docs_client, StubDocsClient)

      on_exit(fn ->
        if prev do
          Application.put_env(:phoenix_kit_document_creator, :docs_client, prev)
        else
          Application.delete_env(:phoenix_kit_document_creator, :docs_client)
        end
      end)

      :ok
    end

    defp insert_template_with_doc_text!(text) do
      unique = System.unique_integer([:positive])
      doc_id = "stub-doc-#{unique}"
      Process.put({:stub_doc_text, doc_id}, text)

      {:ok, template} =
        Documents.upsert_template_from_drive(%{"id" => doc_id, "name" => "Test #{unique}"})

      template
    end

    describe "image_slots_for_template/1" do
      test "returns {:ok, slots} with image and image_list kinds" do
        template =
          insert_template_with_doc_text!("""
            Hello {{ name }}.
            Logo: {{ image: logo }}
            Gallery: {{ images: photos }}
          """)

        assert {:ok, slots} = Documents.image_slots_for_template(template.uuid)

        assert Enum.sort_by(slots, & &1.name) == [
                 %{name: "logo", kind: :image},
                 %{name: "photos", kind: :image_list}
               ]
      end

      test "returns {:error, :not_found} for unknown template uuid" do
        assert {:error, :not_found} =
                 Documents.image_slots_for_template(Ecto.UUID.generate())
      end

      test "returns empty list when template has no image tags" do
        template = insert_template_with_doc_text!("Hello {{ name }}. No images here.")

        assert {:ok, []} = Documents.image_slots_for_template(template.uuid)
      end
    end
  end
end
