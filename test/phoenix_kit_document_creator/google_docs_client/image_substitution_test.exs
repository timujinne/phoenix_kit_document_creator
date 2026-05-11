defmodule PhoenixKitDocumentCreator.GoogleDocsClient.ImageSubstitutionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Mimics a minimal Google Docs JSON response.
  defp doc_with_text(text, start_index \\ 1) do
    %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{
                  "startIndex" => start_index,
                  "endIndex" => start_index + String.length(text),
                  "textRun" => %{"content" => text}
                }
              ]
            }
          }
        ]
      }
    }
  end

  describe "find_image_tag_ranges/2" do
    test "finds a single tag in body" do
      doc = doc_with_text("Logo: {{ image: logo }} done", 1)

      assert GoogleDocsClient.find_image_tag_ranges(doc, ["logo"]) == [
               %{
                 name: "logo",
                 start_index: 7,
                 end_index: 24
               }
             ]
    end

    test "finds the same tag in multiple positions" do
      doc = doc_with_text("A {{ image: x }} B {{ image: x }} C", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["x"])
      assert length(ranges) == 2
      assert Enum.all?(ranges, &(&1.name == "x"))
    end

    test "ignores tags not in the requested name list" do
      doc = doc_with_text("{{ image: yes }} {{ image: no }}", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["yes"])
      assert Enum.map(ranges, & &1.name) == ["yes"]
    end

    test "walks into headers" do
      doc = %{
        "body" => %{"content" => []},
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "walks into footers" do
      doc = %{
        "body" => %{"content" => []},
        "footers" => %{
          "kix.f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "Cyrillic text before tag uses UTF-16 code unit offsets not byte offsets" do
      # "Привет, " = 8 chars, 14 UTF-8 bytes — verifies we use codepoint
      # (UTF-16) offsets, not byte offsets. base = 1 (Google-assigned).
      # The tag "{{ image: logo }}" starts at codepoint 8, so
      # start_index = 1 + 8 = 9, end_index = 1 + 8 + 17 = 26.
      doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 27,
                    "textRun" => %{"content" => "Привет, {{ image: logo }}"}
                  }
                ]
              }
            }
          ]
        }
      }

      [range] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
      assert range.start_index == 9
      assert range.end_index == 26
    end

    test "walks into table cells" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [
                                %{
                                  "startIndex" => 5,
                                  "endIndex" => 22,
                                  "textRun" => %{"content" => "{{ image: logo }}"}
                                }
                              ]
                            }
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%{name: "logo", start_index: 5, end_index: 22}] =
               GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end
  end

  describe "build_image_batch_requests/2" do
    test "single image: delete range + insert one image" do
      ranges = [%{name: "logo", start_index: 10, end_index: 27}]

      fills = %{
        "logo" => %{
          kind: :image,
          default_width_px: 400,
          separator: nil,
          media: [%{uri: "https://x/a.png", width_px: 800, height_px: 400}]
        }
      }

      [delete, insert] = GoogleDocsClient.build_image_batch_requests(ranges, fills)

      assert delete == %{
               deleteContentRange: %{range: %{startIndex: 10, endIndex: 27}}
             }

      assert insert == %{
               insertInlineImage: %{
                 location: %{index: 10},
                 uri: "https://x/a.png",
                 objectSize: %{
                   width: %{magnitude: 400 * 9525, unit: "EMU"},
                   height: %{magnitude: 200 * 9525, unit: "EMU"}
                 }
               }
             }
    end

    test "image_list with newline separator: insertions ordered last-first to preserve visual order" do
      ranges = [%{name: "photos", start_index: 5, end_index: 24}]

      fills = %{
        "photos" => %{
          kind: :image_list,
          default_width_px: 400,
          separator: :newline,
          media: [
            %{uri: "u1", width_px: 400, height_px: 400},
            %{uri: "u2", width_px: 400, height_px: 400},
            %{uri: "u3", width_px: 400, height_px: 400}
          ]
        }
      }

      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills)

      assert [
               %{deleteContentRange: _},
               %{insertInlineImage: %{uri: "u3"}},
               %{insertText: %{text: "\n", location: %{index: 5}}},
               %{insertInlineImage: %{uri: "u2"}},
               %{insertText: %{text: "\n", location: %{index: 5}}},
               %{insertInlineImage: %{uri: "u1"}}
             ] = requests
    end

    test "image_list with :none separator: no insertText" do
      ranges = [%{name: "x", start_index: 0, end_index: 17}]

      fills = %{
        "x" => %{
          kind: :image_list,
          default_width_px: 400,
          separator: :none,
          media: [
            %{uri: "u1", width_px: 400, height_px: 400},
            %{uri: "u2", width_px: 400, height_px: 400}
          ]
        }
      }

      requests = GoogleDocsClient.build_image_batch_requests(ranges, fills)
      refute Enum.any?(requests, &Map.has_key?(&1, :insertText))
    end

    test "multiple ranges: processed in descending startIndex order" do
      ranges = [
        %{name: "a", start_index: 5, end_index: 22},
        %{name: "a", start_index: 50, end_index: 67}
      ]

      fills = %{
        "a" => %{
          kind: :image,
          default_width_px: 400,
          separator: nil,
          media: [%{uri: "u", width_px: 400, height_px: 400}]
        }
      }

      [del1, _ins1, del2, _ins2] = GoogleDocsClient.build_image_batch_requests(ranges, fills)
      assert get_in(del1, [:deleteContentRange, :range, :startIndex]) == 50
      assert get_in(del2, [:deleteContentRange, :range, :startIndex]) == 5
    end

    test "optional empty value still deletes the tag" do
      ranges = [%{name: "x", start_index: 5, end_index: 22}]

      fills = %{
        "x" => %{kind: :image, default_width_px: 400, separator: nil, media: []}
      }

      assert [%{deleteContentRange: _}] =
               GoogleDocsClient.build_image_batch_requests(ranges, fills)
    end
  end

  describe "substitute_images/3" do
    test "no-op when there are no image fills" do
      get_fn = fn _ -> flunk("get should not be called") end
      batch_fn = fn _, _ -> flunk("batch_update should not be called") end

      assert {:ok, :noop} =
               GoogleDocsClient.substitute_images("file-id", %{},
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end

    test "calls batch_update with built requests" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 18,
                    "textRun" => %{"content" => "{{ image: logo }}"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn "file-id" -> {:ok, %{body: doc}} end

      batch_fn = fn "file-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      fills = %{
        "logo" => %{
          kind: :image,
          default_width_px: 400,
          separator: nil,
          media: [%{uri: "u", width_px: 400, height_px: 400}]
        }
      }

      assert {:ok, _} =
               GoogleDocsClient.substitute_images("file-id", fills,
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{deleteContentRange: _}, %{insertInlineImage: _}]}
    end

    test "no batch call when fills present but no tags found in doc" do
      doc = %{"body" => %{"content" => []}}

      get_fn = fn _ -> {:ok, %{body: doc}} end
      batch_fn = fn _, _ -> flunk("batch_update should not be called") end

      fills = %{
        "logo" => %{
          kind: :image,
          default_width_px: 400,
          separator: nil,
          media: [%{uri: "u", width_px: 400, height_px: 400}]
        }
      }

      assert {:ok, _} =
               GoogleDocsClient.substitute_images("file-id", fills,
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end

    test "propagates get_fn error" do
      get_fn = fn _ -> {:error, :boom} end
      batch_fn = fn _, _ -> flunk("batch_update should not be called") end

      fills = %{
        "logo" => %{
          kind: :image,
          default_width_px: 400,
          separator: nil,
          media: [%{uri: "u", width_px: 400, height_px: 400}]
        }
      }

      assert {:error, :boom} =
               GoogleDocsClient.substitute_images("file-id", fills,
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end
  end
end
