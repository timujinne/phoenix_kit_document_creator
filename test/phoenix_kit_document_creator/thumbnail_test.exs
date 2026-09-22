defmodule PhoenixKitDocumentCreator.ThumbnailTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Thumbnail

  import PhoenixKitDocumentCreator.Test.ImageFixtures

  defp uri(type, bytes), do: "data:#{type};base64," <> Base.encode64(bytes)

  describe "dimensions/1" do
    test "reads a PNG header" do
      assert Thumbnail.dimensions(png_uri(1600, 1200)) == {:ok, {1600, 1200}}
    end

    test "reads a GIF header" do
      assert Thumbnail.dimensions(
               uri("image/gif", <<"GIF89a", 300::little-16, 200::little-16, 0::size(80)>>)
             ) ==
               {:ok, {300, 200}}
    end

    test "reads the three WebP variants" do
      vp8x =
        <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0::32, 399::little-24, 299::little-24>>

      assert Thumbnail.dimensions(uri("image/webp", vp8x)) == {:ok, {400, 300}}

      <<bits::32>> = <<0::4, 299::14, 399::14>>
      vp8l = <<"RIFF", 0::32, "WEBP", "VP8L", 0::32, 0x2F, bits::little-32, 0::32>>
      assert Thumbnail.dimensions(uri("image/webp", vp8l)) == {:ok, {400, 300}}

      vp8 =
        <<"RIFF", 0::32, "WEBP", "VP8 ", 0::32, 0::24, 0x9D, 0x01, 0x2A, 400::little-16,
          300::little-16, 0::32>>

      assert Thumbnail.dimensions(uri("image/webp", vp8)) == {:ok, {400, 300}}
    end

    test "walks JPEG segments to the SOF marker, past a large APP segment" do
      app1 = <<0xFF, 0xE1, 5002::16, 0::size(5000 * 8)>>
      sof0 = <<0xFF, 0xC0, 17::16, 8, 200::16, 300::16, 3, 0::size(9 * 8)>>
      jpeg = <<0xFF, 0xD8>> <> app1 <> <<0xFF, 0xC4, 4::16, 0::16>> <> sof0 <> <<0xFF, 0xD9>>

      assert Thumbnail.dimensions(uri("image/jpeg", jpeg)) == {:ok, {300, 200}}
    end

    test "returns :error for anything it cannot read" do
      assert Thumbnail.dimensions(nil) == :error
      assert Thumbnail.dimensions("https://example.com/t.png") == :error
      assert Thumbnail.dimensions("data:image/png,raw") == :error
      assert Thumbnail.dimensions("data:image/png;base64,AA") == :error
      assert Thumbnail.dimensions("data:image/png;base64,!!!!not-base64!!!!") == :error
      assert Thumbnail.dimensions(uri("image/jpeg", <<0xFF, 0xD8, 0xFF, 0xD9>>)) == :error
    end
  end

  describe "img_style/1" do
    test "a wider-than-tall image is fitted whole and centred" do
      assert Thumbnail.img_style(png_uri(1600, 1200)) =~
               "object-fit:contain;object-position:center"
    end

    test "a portrait, square or unreadable image keeps the top-anchored cover crop" do
      for thumb <- [png_uri(1200, 1600), png_uri(500, 500), "data:image/png;base64,AA", nil] do
        assert Thumbnail.img_style(thumb) =~ "object-fit:cover;object-position:top"
      end
    end
  end
end
