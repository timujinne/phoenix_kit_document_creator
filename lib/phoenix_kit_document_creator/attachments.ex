defmodule PhoenixKitDocumentCreator.Attachments do
  @moduledoc """
  Scope folder for images uploaded from the template image picker:

      config :phoenix_kit_document_creator, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:document_image, actor_uuid, %{template_file_id: id})` (or `/2`),
  returning `{:ok, folder_uuid}` or `nil` (no scope, today's behaviour).

  The answer is passed to core's media selector as `scope_folder`, which files
  uploads made from the selector under that folder; picking an existing file
  does not move it. The hook contract is core's
  `PhoenixKit.Modules.Storage.ResourceFolders`: an answer that is not a uuid,
  or a hook that raises, throws or exits, is logged and treated as `nil`.
  """

  alias PhoenixKit.Modules.Storage.ResourceFolders

  @spec scope_folder(String.t() | nil, String.t() | nil) :: String.t() | nil
  def scope_folder(template_file_id, actor_uuid) do
    ResourceFolders.parent_uuid(:phoenix_kit_document_creator, :document_image, actor_uuid, %{
      template_file_id: template_file_id
    })
  end
end
