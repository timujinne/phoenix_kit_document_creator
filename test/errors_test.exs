defmodule PhoenixKitDocumentCreator.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Errors

  # Pin the *content* of the returned message for every atom Errors emits.
  # `assert is_binary(msg)` would pass for any input — the workspace
  # playbook (agents.md test smells) explicitly rejects that pattern. If
  # someone reverts a `gettext("...")` wrap or renames an atom, one of
  # these per-atom tests fails with a clear diff against the expected
  # English source string.

  describe "message/1 for known atoms" do
    @atom_expectations [
      {:copy_failed, "Failed to copy the Google Doc"},
      {:create_document_failed, "Failed to create the Google Doc"},
      {:create_folder_failed, "Failed to create the Drive folder"},
      {:deleted_folder_not_found, "Deleted folder not found"},
      {:documents_folder_not_found, "Documents folder not found"},
      {:file_trashed, "File is in the Drive trash"},
      {:folder_not_found, "Folder not found"},
      {:folder_search_failed, "Failed to search Drive for the folder"},
      {:get_file_parents_failed, "Failed to read file parents from Drive"},
      {:invalid_action, "Invalid action"},
      {:invalid_file_id, "Invalid file ID"},
      {:invalid_google_doc_id, "Invalid Google Doc ID"},
      {:invalid_parent_folder_id, "Invalid parent folder ID"},
      {:list_files_failed, "Failed to list Drive files"},
      {:live_folder_not_found, "Live folder not found"},
      {:max_depth_exceeded, "Maximum folder depth exceeded"},
      {:missing_google_doc_id, "Missing Google Doc ID"},
      {:missing_name, "Missing name"},
      {:move_failed, "Failed to move the Drive file"},
      {:no_doc_id, "No Google Doc ID set on this record"},
      {:no_thumbnail, "No thumbnail available"},
      {:not_found, "Not found"},
      {:pdf_export_failed, "Failed to export PDF from Drive"},
      {:sync_failed, "Failed to sync from Google Drive"},
      {:templates_folder_not_found, "Templates folder not found"},
      {:thumbnail_fetch_failed, "Failed to fetch the thumbnail"},
      {:thumbnail_link_failed, "Failed to read the thumbnail link from Drive"}
    ]

    for {atom, expected} <- @atom_expectations do
      test "#{inspect(atom)} maps to #{inspect(expected)}" do
        assert Errors.message(unquote(atom)) == unquote(expected)
      end
    end
  end

  describe "message/1 unwrapping {:error, reason} tuples" do
    test "unwraps and translates the inner atom" do
      assert Errors.message({:error, :sync_failed}) == "Failed to sync from Google Drive"
    end

    test "unknown inner atom falls through to inspect" do
      assert Errors.message({:error, :totally_unknown}) =~ "totally_unknown"
    end
  end

  describe "message/1 for changeset" do
    test "renders changeset errors as field: msg pairs" do
      changeset =
        %Ecto.Changeset{
          types: %{name: :string},
          errors: [name: {"can't be blank", [validation: :required]}],
          valid?: false,
          data: %{},
          params: %{}
        }
        |> Map.put(:errors, name: {"can't be blank", [validation: :required]})

      result = Errors.message(changeset)
      assert result =~ "name"
      assert result =~ "can't be blank"
    end
  end

  describe "message/1 catch-all" do
    test "binary passes through verbatim (importer-style upstream strings)" do
      assert Errors.message("Specific upstream error text") == "Specific upstream error text"
    end

    test "unknown term gets inspected" do
      assert Errors.message({:weird, :tuple}) == "{:weird, :tuple}"
      assert Errors.message(:totally_made_up_atom) == ":totally_made_up_atom"
    end
  end

  describe "message/1 — image errors" do
    @image_atom_expectations [
      {:image_not_found, "Image media not found"},
      {:image_url_not_public, "Image URL is not publicly accessible or exceeds 2 KB"},
      {:image_too_large, "Image exceeds 50 MB or 25 megapixels"},
      {:image_insert_failed, "Failed to insert images into document"},
      {:image_tag_not_found, "Image placeholder tag not found in template"},
      {:missing_required_value, "A required variable was not filled"}
    ]

    for {atom, expected} <- @image_atom_expectations do
      test "#{inspect(atom)} maps to #{inspect(expected)}" do
        assert Errors.message(unquote(atom)) == unquote(expected)
        refute String.starts_with?(Errors.message(unquote(atom)), ":")
      end
    end
  end
end
