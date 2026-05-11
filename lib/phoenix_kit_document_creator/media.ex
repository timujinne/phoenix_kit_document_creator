defmodule PhoenixKitDocumentCreator.Media do
  @moduledoc """
  Façade over PhoenixKit.Modules.Storage for the image-substitution pipeline.

  Resolves a media_id (file UUID) to a public URL and stored pixel dimensions.
  The backing module is injectable via:

      config :phoenix_kit_document_creator, :media_module, MyStubStorage

  In production the default is `PhoenixKit.Modules.Storage`.
  """

  @doc """
  Resolves a media UUID to its public URL and stored pixel dimensions.

  Returns:
  - `{:ok, %{url: String.t(), width_px: integer() | nil, height_px: integer() | nil}}`
  - `{:error, :image_not_found}` — UUID has no matching file record
  - `{:error, :image_url_not_public}` — file exists but has no resolvable public URL
  """
  @spec get_url_and_dimensions(String.t()) ::
          {:ok, %{url: String.t(), width_px: integer() | nil, height_px: integer() | nil}}
          | {:error, :image_not_found | :image_url_not_public}
  def get_url_and_dimensions(media_id) when is_binary(media_id) do
    mod = media_module()

    case mod.get_file(media_id) do
      nil ->
        {:error, :image_not_found}

      file ->
        case mod.get_public_url(file) do
          nil ->
            {:error, :image_url_not_public}

          url ->
            {:ok, %{url: url, width_px: file.width, height_px: file.height}}
        end
    end
  end

  defp media_module do
    Application.get_env(
      :phoenix_kit_document_creator,
      :media_module,
      PhoenixKit.Modules.Storage
    )
  end
end
