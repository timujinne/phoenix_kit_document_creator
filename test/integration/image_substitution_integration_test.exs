defmodule PhoenixKitDocumentCreator.Integration.ImageSubstitutionTest do
  @moduledoc """
  End-to-end integration test for image tag substitution against a real Google
  account. Requires a live OAuth token AND the document-creator folders
  configured in the dev environment.

  Run with:
    PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH=1 mix test --only external

  ### What this test verifies

  1. The full two-pass pipeline (text replaceAllText → image substitute_images)
     works against a real Google Doc.

  2. **UTF-16 code unit invariant** — "Привет, " (8 Cyrillic chars = 14 UTF-8
     bytes) precedes the `{{ image: logo }}` tag. If find_image_tag_ranges/2
     used raw byte offsets, the DeleteContentRange would target the wrong
     characters and the generated doc would retain literal `}}` residue.

  ### Media setup

  The test uses a lightweight stub media module (defined below) that returns a
  stable public HTTPS PNG URL without needing real PhoenixKit Storage. Override
  the URL via the `E2E_IMAGE_URL` env var if the default becomes unreachable.

  The stub is injected via Application.put_env and restored after the test.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  @moduletag :external
  @moduletag :integration

  alias PhoenixKitDocumentCreator.Documents
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Fake UUID used as the media_id throughout this test.
  @test_media_uuid "00000000-e2e1-0000-0000-000000000001"

  setup_all do
    if System.get_env("PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH") do
      :ok
    else
      {:skip, "PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH not set — skipping E2E integration tests"}
    end
  end

  # Minimal stub that satisfies PhoenixKitDocumentCreator.Media's interface:
  # get_file/1 returns a fake struct, get_public_url/1 returns the test URL.
  defmodule StubMedia do
    @media_uuid "00000000-e2e1-0000-0000-000000000001"
    @test_url "https://www.gstatic.com/webp/gallery3/1.png"

    def get_file(@media_uuid), do: %{uuid: @media_uuid, width: 200, height: 200}
    def get_file(_), do: nil

    def get_public_url(%{uuid: @media_uuid}),
      do: System.get_env("E2E_IMAGE_URL") || @test_url

    def get_public_url(_), do: nil
  end

  setup do
    prev = Application.get_env(:phoenix_kit_document_creator, :media_module)
    Application.put_env(:phoenix_kit_document_creator, :media_module, StubMedia)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:phoenix_kit_document_creator, :media_module, prev),
        else: Application.delete_env(:phoenix_kit_document_creator, :media_module)
    end)

    :ok
  end

  test "creates a doc with text and image substitutions including Cyrillic neighbour text" do
    # Step 1: Create a template Google Doc with Cyrillic text + mixed tags.
    # Body: "Привет, {{ client }}! Логотип: {{ image: logo }} Конец."
    # The 8-char Cyrillic prefix forces UTF-16 vs byte-offset divergence
    # (14 UTF-8 bytes vs 8 code units) — any byte-offset bug surfaces here.
    template_body = "Привет, {{ client }}! Логотип: {{ image: logo }} Конец."

    assert {:ok, template_file_id} = create_template_doc(template_body)
    on_exit(fn -> trash_doc(template_file_id) end)

    # Step 2: Register in DB (needed for variable config lookup).
    {:ok, _} =
      Documents.upsert_template_from_drive(%{
        "id" => template_file_id,
        "name" => "E2E Cyrillic Template"
      })

    assert {:ok, fork} = Documents.detect_variables(template_file_id)
    assert "client" in fork.text
    assert Enum.any?(fork.image, &(&1.name == "logo" and &1.kind == :image))

    # Step 3: Generate document with both variables filled.
    variable_values = %{
      "client" => "Тест",
      "logo" => %{"media_id" => @test_media_uuid}
    }

    assert {:ok, %{doc_id: doc_file_id, url: doc_url}} =
             Documents.create_document_from_template(
               template_file_id,
               variable_values,
               name: "E2E Cyrillic Test Doc"
             )

    on_exit(fn -> trash_doc(doc_file_id) end)

    assert is_binary(doc_url)

    # Step 4: Fetch text and verify:
    # - No literal {{ or }} left (all tags substituted or deleted)
    # - Cyrillic client name appears correctly
    # - Surrounding Cyrillic text intact (not chewed by wrong deletion bounds)
    assert {:ok, doc_text} = GoogleDocsClient.get_document_text(doc_file_id)

    refute doc_text =~ "{{",
           "leftover {{ found — likely a byte-offset bug in find_image_tag_ranges/2; " <>
             "Cyrillic chars before the tag cause byte vs UTF-16 code unit divergence"

    refute doc_text =~ "}}", "leftover }} found"
    assert doc_text =~ "Тест", "client variable was not substituted"
    assert doc_text =~ "Привет,", "Cyrillic prefix was corrupted"
    assert doc_text =~ "Конец.", "Cyrillic suffix missing"

    # Step 5: Verify at least one inline image object was inserted.
    assert {:ok, %{body: full_doc}} = GoogleDocsClient.get_document(doc_file_id)
    inline_objects = Map.get(full_doc, "inlineObjects", %{})

    assert map_size(inline_objects) >= 1,
           "No inline image found — check that StubMedia.get_public_url returns a reachable HTTPS URL"
  end

  # Creates a Google Doc with the given body text via insertText batchUpdate.
  # Returns {:ok, file_id} or {:error, reason}.
  defp create_template_doc(body_text) do
    title = "ImageSubstitution E2E #{System.unique_integer([:positive])}"

    with {:ok, %{doc_id: file_id}} <- GoogleDocsClient.create_document(title),
         requests = [%{insertText: %{location: %{index: 1}, text: body_text}}],
         {:ok, _} <- GoogleDocsClient.batch_update(file_id, requests) do
      {:ok, file_id}
    end
  end

  # NOTE: E2E test docs are created in the configured Drive folders. The tester
  # should periodically clean up docs prefixed "ImageSubstitution E2E" and
  # "E2E Cyrillic Test Doc" from the templates/documents folders.
  # We do not auto-trash here because GoogleDocsClient has no trash endpoint;
  # adding one is out of scope for this test task.
  defp trash_doc(_file_id), do: :ok
end
