defmodule PhoenixKitDocumentCreator.Documents.ImagePipelineTest do
  use ExUnit.Case, async: false

  alias PhoenixKitDocumentCreator.Documents

  # Stub GoogleDocsClient for the two-pass pipeline tests.
  # Records calls so we can assert ordering without hitting the API.
  defmodule StubDocsClient do
    def copy_file(_template_id, _name, _opts), do: {:ok, "new-doc-id"}

    def replace_all_text(_doc_id, _values), do: {:ok, %{}}

    def substitute_images(_doc_id, fills, _opts) when fills == %{},
      do: {:ok, :noop}

    def substitute_images("new-doc-id", fills, _opts) do
      send(self(), {:substitute_images, fills})
      {:ok, %{}}
    end

    def get_edit_url(doc_id), do: "https://docs.google.com/d/#{doc_id}"
  end

  defmodule StubMediaModule do
    def get_file("good-uuid"), do: %{uuid: "good-uuid", width: 800, height: 400}
    def get_file(_), do: nil
    def get_public_url(%{uuid: "good-uuid"}), do: "https://cdn.example.com/img.png"
    def get_public_url(_), do: nil
  end

  # Template DB row used across tests — pre-populated with one image var and
  # one text var in the variables jsonb.
  defp template_vars do
    [
      %{
        "name" => "logo",
        "type" => "image",
        "config" => %{"default_width_px" => 400}
      },
      %{
        "name" => "photos",
        "type" => "image_list",
        "config" => %{"default_width_px" => 300, "separator" => "newline"}
      }
    ]
  end

  setup do
    Application.put_env(:phoenix_kit_document_creator, :docs_client, StubDocsClient)
    Application.put_env(:phoenix_kit_document_creator, :media_module, StubMediaModule)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_document_creator, :docs_client)
      Application.delete_env(:phoenix_kit_document_creator, :media_module)
    end)

    :ok
  end

  describe "split_text_and_image_values/1" do
    test "separates text, single-image, and list-image values" do
      values = %{
        "client_name" => "Acme",
        "logo" => %{"media_id" => "abc"},
        "photos" => %{"media_ids" => ["x", "y"]}
      }

      {text, images} = Documents.split_text_and_image_values(values)
      assert text == %{"client_name" => "Acme"}

      assert images == %{
               "logo" => %{"media_id" => "abc"},
               "photos" => %{"media_ids" => ["x", "y"]}
             }
    end

    test "all text values produces empty image map" do
      {text, images} = Documents.split_text_and_image_values(%{"a" => "1", "b" => "2"})
      assert text == %{"a" => "1", "b" => "2"}
      assert images == %{}
    end

    test "empty map produces two empty maps" do
      assert {%{}, %{}} = Documents.split_text_and_image_values(%{})
    end
  end

  describe "resolve_image_fills/2" do
    test "resolves a single-image fill from media module" do
      spec = %{"logo" => %{"media_id" => "good-uuid"}}

      assert {:ok, fills} = Documents.resolve_image_fills(template_vars(), spec)

      assert %{
               "logo" => %{
                 kind: :image,
                 default_width_px: 400,
                 media: [%{uri: "https://cdn.example.com/img.png", width_px: 800, height_px: 400}]
               }
             } = fills
    end

    test "returns :image_not_found when media_id does not exist" do
      spec = %{"logo" => %{"media_id" => "missing-uuid"}}
      assert {:error, :image_not_found} = Documents.resolve_image_fills(template_vars(), spec)
    end

    test "returns :image_tag_not_found when variable is not in template defs" do
      spec = %{"unknown_var" => %{"media_id" => "good-uuid"}}
      assert {:error, :image_tag_not_found} = Documents.resolve_image_fills(template_vars(), spec)
    end

    test "resolves image_list fill with multiple media ids" do
      spec = %{"photos" => %{"media_ids" => ["good-uuid", "good-uuid"]}}

      assert {:ok, fills} = Documents.resolve_image_fills(template_vars(), spec)
      assert %{"photos" => %{kind: :image_list, media: [_, _]}} = fills
    end
  end
end
