defmodule PhoenixKitDocumentCreator.Test.ImageFixtures do
  @moduledoc "Minimal image data URIs whose headers carry a given size."

  @doc "A base64 PNG data URI whose IHDR declares `width` × `height`."
  def png_uri(width, height) do
    bytes =
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0,
        0::32, 0::size(64 * 8)>>

    "data:image/png;base64," <> Base.encode64(bytes)
  end
end
