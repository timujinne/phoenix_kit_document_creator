defmodule PhoenixKitDocumentCreator.Thumbnail do
  @moduledoc """
  Server-side orientation of a cached thumbnail data URI.

  Drive renders a thumbnail in the page's own orientation, so a landscape
  document (`documentStyle.flipPageOrientation`) comes back wider than tall.
  The admin grids show every thumbnail in a fixed portrait frame with
  `object-fit: cover` anchored to the top, which would crop a landscape page
  to its middle strip; `img_style/1` switches such an image to `contain`.

  The decision is made here from the image header rather than in an `onload`
  handler: LiveView's DOM patch rewrites a JS-mutated `style` attribute back to
  the rendered one on the next re-render (and `onload` does not fire again for
  an unchanged `src`), and a host `Content-Security-Policy: script-src 'self'`
  blocks inline handlers outright.

  Only the header is decoded. PNG, GIF, WebP and baseline/progressive JPEG are
  recognised — the four types `GoogleDocsClient` stores. Anything else reads as
  portrait, which is the frame's original behaviour.
  """

  @portrait_style "width:100%;height:100%;object-fit:cover;object-position:top;"
  @landscape_style "width:100%;height:100%;object-fit:contain;object-position:center;"

  # 44 base64 chars → 33 bytes, enough for the PNG, GIF and WebP headers.
  @short_prefix 44
  # JPEG puts its SOF marker after the APPn / DQT / DHT segments, usually in
  # the first few KB of a Drive thumbnail.
  @jpeg_prefix 16_384

  @doc "Inline `style` for a thumbnail `<img>` inside a fixed portrait frame."
  @spec img_style(term()) :: String.t()
  def img_style(data_uri) do
    if landscape?(data_uri), do: @landscape_style, else: @portrait_style
  end

  @doc "Whether the image in `data_uri` is wider than it is tall."
  @spec landscape?(term()) :: boolean()
  def landscape?(data_uri) do
    case dimensions(data_uri) do
      {:ok, {width, height}} -> width > height
      :error -> false
    end
  end

  @doc """
  `{:ok, {width, height}}` read from the header of a base64 image data URI,
  or `:error` when it isn't one or the format isn't recognised.
  """
  @spec dimensions(term()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def dimensions("data:" <> rest) do
    with [meta, payload] <- :binary.split(rest, ","),
         true <- String.ends_with?(meta, ";base64"),
         {:ok, head} <- decode_prefix(payload, @short_prefix) do
      if jpeg?(head), do: jpeg_payload_dimensions(payload), else: header_dimensions(head)
    else
      _ -> :error
    end
  end

  def dimensions(_), do: :error

  defp decode_prefix(payload, max) do
    size = min(byte_size(payload), max)
    # A cut must land on a 4-char boundary; only the true end may carry padding.
    prefix =
      binary_part(payload, 0, if(size == byte_size(payload), do: size, else: size - rem(size, 4)))

    Base.decode64(prefix)
  end

  defp jpeg_payload_dimensions(payload) do
    case decode_prefix(payload, @jpeg_prefix) do
      {:ok, bytes} -> jpeg_dimensions(bytes)
      :error -> :error
    end
  end

  defp jpeg?(<<0xFF, 0xD8, _::binary>>), do: true
  defp jpeg?(_), do: false

  defp header_dimensions(
         <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>>
       ),
       do: positive(w, h)

  defp header_dimensions(<<"GIF8", _v::binary-size(2), w::little-16, h::little-16, _::binary>>),
    do: positive(w, h)

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8X", _::binary-size(8), w::little-24, h::little-24,
           _::binary>>
       ),
       do: positive(w + 1, h + 1)

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8L", _::32, 0x2F, bits::little-32, _::binary>>
       ) do
    <<_::4, h::14, w::14>> = <<bits::32>>
    positive(w + 1, h + 1)
  end

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8 ", _::binary-size(10), w::little-16, h::little-16,
           _::binary>>
       ),
       do: positive(Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF))

  defp header_dimensions(_), do: :error

  # Walks the JPEG segments to the first SOFn marker (C0–CF, bar C4/C8/CC).
  defp jpeg_dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_segments(rest)

  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>), do: jpeg_segments(<<0xFF, rest::binary>>)

  defp jpeg_segments(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: positive(w, h)

  defp jpeg_segments(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    case rest do
      <<_::binary-size(len - 2), next::binary>> -> jpeg_segments(next)
      _ -> :error
    end
  end

  defp jpeg_segments(_), do: :error

  defp positive(w, h) when w > 0 and h > 0, do: {:ok, {w, h}}
  defp positive(_, _), do: :error
end
