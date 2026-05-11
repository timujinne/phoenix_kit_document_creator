defmodule PhoenixKitDocumentCreator.Integration.ImageSubstitutionTest do
  @moduledoc """
  End-to-end integration test for image tag substitution against a real Google
  account. Requires a live OAuth token.

  Run with:
    PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH=1 mix test --only external

  This test also validates the UTF-16 code unit offset invariant — it places
  Cyrillic text before an image tag so that any byte-vs-codepoint confusion
  in find_image_tag_ranges/2 would produce wrong deletion bounds.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  @moduletag :external
  @moduletag :integration

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Media

  setup_all do
    if System.get_env("PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH") in [nil, ""] do
      :skip
    else
      :ok
    end
  end

  # A 1×1 transparent PNG encoded as base64, small enough to pass Google's
  # 50 MB / 25 Mpx limits and ≤ 2 KB URL constraint.
  @tiny_png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  # Helper: create a minimal Google Doc programmatically and return its ID.
  defp create_test_template(body_text) do
    title = "ImageSubstitution E2E #{System.unique_integer([:positive])}"

    with {:ok, %{id: file_id}} <- GoogleDocsClient.create_document(title),
         # Replace the placeholder with our test content by writing it.
         {:ok, _} <- GoogleDocsClient.replace_all_text(file_id, %{"__BODY__" => body_text}) do
      {:ok, file_id}
    end
  end

  test "creates a doc with text and image substitutions including Cyrillic neighbour text" do
    # The template body has Cyrillic before the tag. If find_image_tag_ranges
    # uses raw byte offsets instead of codepoint/UTF-16 offsets, the deletion
    # range will point to the wrong characters and the test fails.
    template_body = "Привет, {{client}}! Логотип: {{ image: logo }} Конец."

    assert {:ok, template_file_id} = create_test_template(template_body)

    on_exit(fn ->
      # Best-effort cleanup — trash the template doc after the test.
      GoogleDocsClient.delete_file(template_file_id)
    end)

    # Register the template in DB so create_document_from_template can look
    # up variable config.
    {:ok, _} =
      Documents.upsert_template_from_drive(%{
        "id" => template_file_id,
        "name" => "E2E Cyrillic Template"
      })

    {:ok, fork} = Documents.detect_variables(template_file_id)
    assert "client" in fork.text
    assert Enum.any?(fork.image, &(&1.name == "logo" and &1.kind == :image))

    # Upload a tiny test PNG as a PhoenixKit media item and get its ID.
    png_bytes = Base.decode64!(@tiny_png_b64)
    {:ok, media_id} = upload_test_image(png_bytes)

    on_exit(fn ->
      delete_test_image(media_id)
    end)

    variable_values = %{
      "client" => "Тест",
      "logo" => %{"media_id" => media_id}
    }

    assert {:ok, %{url: doc_url, id: doc_file_id}} =
             Documents.create_document_from_template(
               template_file_id,
               variable_values,
               name: "E2E Test Document"
             )

    on_exit(fn ->
      GoogleDocsClient.delete_file(doc_file_id)
    end)

    assert is_binary(doc_url)

    # Fetch the generated document and assert:
    # 1. No leftover {{ or }} in body text (all tags were substituted/deleted).
    # 2. At least one inline object (the inserted image).
    # 3. The Cyrillic client name was substituted correctly.
    assert {:ok, doc_text} = GoogleDocsClient.get_document_text(doc_file_id)
    refute doc_text =~ "{{"
    refute doc_text =~ "}}"
    assert doc_text =~ "Тест"

    assert {:ok, %{body: full_doc}} = get_full_document(doc_file_id)
    inline_objects = Map.get(full_doc, "inlineObjects", %{})
    assert map_size(inline_objects) >= 1, "Expected at least one inline image object"
  end

  # Uploads a PNG bytes payload via PhoenixKit Media and returns the media_id.
  # Implementation depends on PhoenixKit Media's upload API — adjust as needed.
  defp upload_test_image(png_bytes) do
    media_module = Application.fetch_env!(:phoenix_kit_document_creator, :media_module)

    case media_module.upload(png_bytes, filename: "test.png", content_type: "image/png") do
      {:ok, media} -> {:ok, media.id}
      err -> err
    end
  end

  defp delete_test_image(nil), do: :ok

  defp delete_test_image(media_id) do
    media_module = Application.fetch_env!(:phoenix_kit_document_creator, :media_module)
    media_module.delete(media_id)
  end

  defp get_full_document(doc_id) do
    case GoogleDocsClient.request(:get, "/documents/#{doc_id}") do
      {:ok, %{body: body}} -> {:ok, body}
      err -> err
    end
  end
end
