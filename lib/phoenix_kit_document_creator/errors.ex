defmodule PhoenixKitDocumentCreator.Errors do
  @moduledoc """
  Single translation point for every error atom the Document Creator
  module emits.

  Call sites return plain `{:error, :atom}` tuples — never free-text
  strings — and the UI / API layer translates via `message/1` at the
  boundary. This keeps error semantics testable (assert on the atom,
  not on a string that might get reworded) and makes translations
  consistent (every place that surfaces `:templates_folder_not_found`
  renders the exact same gettext string).

  Translation files live in this module's own `priv/gettext/`; the
  msgids below are literal arguments to `gettext/1` so
  `mix gettext.extract` picks them up correctly. Do NOT refactor this
  into a lookup map — the extractor only sees literal arguments to
  `gettext/1` at the call site.

  Unknown atoms fall through to `inspect/1` so the catch-all returns
  a useful-if-ugly string rather than crashing.
  """

  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  @type error_atom ::
          :copy_failed
          | :create_document_failed
          | :create_folder_failed
          | :deleted_folder_not_found
          | :documents_folder_not_found
          | :file_trashed
          | :folder_not_found
          | :folder_search_failed
          | :get_file_parents_failed
          | :invalid_action
          | :invalid_file_id
          | :invalid_google_doc_id
          | :invalid_parent_folder_id
          | :list_files_failed
          | :live_folder_not_found
          | :max_depth_exceeded
          | :missing_google_doc_id
          | :missing_name
          | :move_failed
          | :no_doc_id
          | :no_thumbnail
          | :not_found
          | :pdf_export_failed
          | :sync_failed
          | :templates_folder_not_found
          | :thumbnail_fetch_failed
          | :thumbnail_link_failed
          | :image_not_found
          | :image_url_not_public
          | :image_too_large
          | :image_insert_failed
          | :image_tag_not_found
          | :missing_required_value

  @doc """
  Returns a human-readable message for an error atom, changeset, or
  other value. Safe for any input — falls through to `inspect/1` for
  unknown terms.
  """
  @spec message(term()) :: String.t()
  def message(:copy_failed), do: gettext("Failed to copy the Google Doc")
  def message(:create_document_failed), do: gettext("Failed to create the Google Doc")
  def message(:create_folder_failed), do: gettext("Failed to create the Drive folder")
  def message(:deleted_folder_not_found), do: gettext("Deleted folder not found")
  def message(:documents_folder_not_found), do: gettext("Documents folder not found")
  def message(:file_trashed), do: gettext("File is in the Drive trash")
  def message(:folder_not_found), do: gettext("Folder not found")
  def message(:folder_search_failed), do: gettext("Failed to search Drive for the folder")
  def message(:get_file_parents_failed), do: gettext("Failed to read file parents from Drive")
  def message(:invalid_action), do: gettext("Invalid action")
  def message(:invalid_file_id), do: gettext("Invalid file ID")
  def message(:invalid_google_doc_id), do: gettext("Invalid Google Doc ID")
  def message(:invalid_parent_folder_id), do: gettext("Invalid parent folder ID")
  def message(:list_files_failed), do: gettext("Failed to list Drive files")
  def message(:live_folder_not_found), do: gettext("Live folder not found")
  def message(:max_depth_exceeded), do: gettext("Maximum folder depth exceeded")
  def message(:missing_google_doc_id), do: gettext("Missing Google Doc ID")
  def message(:missing_name), do: gettext("Missing name")
  def message(:move_failed), do: gettext("Failed to move the Drive file")
  def message(:no_doc_id), do: gettext("No Google Doc ID set on this record")
  def message(:no_thumbnail), do: gettext("No thumbnail available")
  def message(:not_found), do: gettext("Not found")
  def message(:pdf_export_failed), do: gettext("Failed to export PDF from Drive")
  def message(:sync_failed), do: gettext("Failed to sync from Google Drive")
  def message(:templates_folder_not_found), do: gettext("Templates folder not found")
  def message(:thumbnail_fetch_failed), do: gettext("Failed to fetch the thumbnail")
  def message(:thumbnail_link_failed), do: gettext("Failed to read the thumbnail link from Drive")

  def message(:image_not_found), do: gettext("Image media not found")

  def message(:image_url_not_public),
    do: gettext("Image URL is not publicly accessible or exceeds 2 KB")

  def message(:image_too_large), do: gettext("Image exceeds 50 MB or 25 megapixels")
  def message(:image_insert_failed), do: gettext("Failed to insert images into document")
  def message(:image_tag_not_found), do: gettext("Image placeholder tag not found in template")
  def message(:missing_required_value), do: gettext("A required variable was not filled")

  def message({:error, reason}), do: message(reason)

  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} ->
      "#{field}: #{Enum.join(msgs, ", ")}"
    end)
  end

  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason)
end
