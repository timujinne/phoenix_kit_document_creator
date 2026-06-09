defmodule PhoenixKitDocumentCreator.GoogleDocsClientMediaHeightTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Regression test for the bug fixed in PR #26:
  #
  # Before the fix, `build_media_items/1` only mapped `:uri` and `:width_px`
  # from the string-keyed "media" list, silently dropping `"height_px"`.
  # The resulting fill had `height_px: nil` in every media item.
  #
  # Downstream, `scale_height/3` is called as:
  #
  #   round(target_width * src_height / src_width)
  #
  # With `src_height = nil` this evaluates `round(target * nil / width)` and
  # raises `(ArithmeticError) bad argument in arithmetic expression` for every
  # inline / columns==1 image insert.
  #
  # The fix adds `:height_px` to the struct literal in `build_media_items/1`.
  # These tests verify the fix is present and that the full
  #   image_params (string-keyed "media") → build_image_fills → build_media_items
  #   → build_image_batch_requests → insertInlineImage objectSize.height.magnitude
  # path produces a positive, aspect-ratio-correct height.

  describe "regression: build_media_items carries height_px through to batch requests" do
    test "height_px is preserved in the fill produced by build_image_fills_for_test/1" do
      image_params = %{
        "photo" => %{
          "kind" => "image",
          "width_px" => 400,
          "media" => [
            %{
              "uri" => "https://example.com/img.png",
              "width_px" => 800,
              "height_px" => 600
            }
          ]
        }
      }

      fills = GoogleDocsClient.build_image_fills_for_test(image_params)

      assert %{
               "photo" => %{
                 kind: :image,
                 media: [%{uri: _, width_px: 800, height_px: 600}]
               }
             } = fills

      # height_px must not be nil — a nil here is the original bug
      [%{height_px: height_px}] = fills["photo"].media

      refute is_nil(height_px),
             "height_px must not be nil — nil causes ArithmeticError in scale_height/3"
    end

    test "objectSize.height.magnitude is a positive number (proportional to aspect ratio)" do
      # Source image: 800×600 → aspect ratio 4:3.
      # Display width: 400 px → expected height: round(400 * 600 / 800) = 300 px.
      # Google Docs API uses PT (1 px = 0.75 pt), so expected height = 225.0 PT.
      image_params = %{
        "photo" => %{
          "kind" => "image",
          "width_px" => 400,
          "media" => [
            %{
              "uri" => "https://example.com/img.png",
              "width_px" => 800,
              "height_px" => 600
            }
          ]
        }
      }

      fills = GoogleDocsClient.build_image_fills_for_test(image_params)

      ranges = [%{name: "photo", start_index: 1, end_index: 18}]

      [_delete, insert] = GoogleDocsClient.build_image_batch_requests(ranges, fills)

      assert %{
               insertInlineImage: %{
                 objectSize: %{
                   height: %{magnitude: height_magnitude, unit: "PT"},
                   width: %{magnitude: _width_magnitude, unit: "PT"}
                 }
               }
             } = insert

      # Before the fix, height_magnitude would be nil (or crash with ArithmeticError).
      assert is_number(height_magnitude), "height magnitude must be a number, not nil"
      assert height_magnitude > 0, "height magnitude must be positive"

      # Verify the proportional value: 400px display width, 800×600 source
      # → height = 300px = 225.0 PT
      assert height_magnitude == 300 * 0.75,
             "expected height 225.0 PT (300px × 0.75), got #{height_magnitude}"
    end

    test "substitute_images/3 with injected fns completes without ArithmeticError" do
      # End-to-end path through substitute_images/3 using fills built via
      # build_image_fills_for_test/1 — ensures the full pipeline does not crash
      # when height_px is present in the fill.
      image_params = %{
        "photo" => %{
          "kind" => "image",
          "width_px" => 400,
          "media" => [
            %{
              "uri" => "https://example.com/portrait.jpg",
              "width_px" => 400,
              "height_px" => 600
            }
          ]
        }
      }

      fills = GoogleDocsClient.build_image_fills_for_test(image_params)

      doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 18,
                    "textRun" => %{"content" => "{{ image: photo }}"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn "doc-id" -> {:ok, %{body: doc}} end

      batch_fn = fn "doc-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.substitute_images("doc-id", fills,
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{deleteContentRange: _}, %{insertInlineImage: insert_body}]}

      height_magnitude = get_in(insert_body, [:objectSize, :height, :magnitude])

      # 400x600 source at 400px display width: scale_height(400, 400, 600) = 600px
      # → 600 * 0.75 = 450.0 PT. Pin the exact value so a wrong-but-positive
      # regression is also caught.
      assert height_magnitude == 450.0,
             "expected height 450.0 PT, got: #{inspect(height_magnitude)}"
    end
  end
end
