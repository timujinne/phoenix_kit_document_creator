defmodule PhoenixKitDocumentCreator.GoogleDocsClientHeaderFooterExtentTest do
  @moduledoc """
  Coverage for `header_extent_pt/2` / `footer_extent_pt/2` — the header/footer
  content estimator `section_boxes/1` folds into `body_top_pt`/`body_bottom_pt`
  (see block D of `docs/superpowers/specs/2026-09-22-section-orientation-and-page-fit.md`).
  """

  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # A default-style (11pt / 115% lineSpacing) line's height, including the
  # @font_leading (1.22) multiplier `estimate_paragraph_height_pt/1`
  # applies — see its moduledoc for the live measurement this reproduces.
  @default_line_pt 11.0 * 1.15 * 1.22

  defp para(text, style_overrides \\ %{}) do
    %{
      "paragraph" => %{
        "elements" => [%{"textRun" => %{"content" => text}}],
        "paragraphStyle" => style_overrides
      }
    }
  end

  defp para_with_image(inline_object_id) do
    %{
      "paragraph" => %{
        "elements" => [%{"inlineObjectElement" => %{"inlineObjectId" => inline_object_id}}]
      }
    }
  end

  defp inline_object(id, height, width \\ 100.0, embedded_overrides \\ %{}) do
    {id,
     %{
       "inlineObjectProperties" => %{
         "embeddedObject" =>
           Map.merge(
             %{
               "size" => %{
                 "height" => %{"magnitude" => height, "unit" => "PT"},
                 "width" => %{"magnitude" => width, "unit" => "PT"}
               }
             },
             embedded_overrides
           )
       }
     }}
  end

  describe "header_extent_pt/2 and footer_extent_pt/2" do
    test "sums estimated paragraph heights (fontSize x lineSpacing/100 + spaceAbove + spaceBelow)" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              para("Line one"),
              para("Line two", %{"lineSpacing" => 200})
            ]
          }
        }
      }

      # Line one: default font/spacing → @default_line_pt. Line two: 11 * 2.0 * 1.22.
      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}),
                      @default_line_pt + 11.0 * 2.0 * 1.22,
                      0.001
    end

    test "an empty paragraph still counts as one line" do
      doc = %{
        "documentStyle" => %{"defaultFooterId" => "f1"},
        "footers" => %{"f1" => %{"content" => [para("\n")]}}
      }

      assert_in_delta GoogleDocsClient.footer_extent_pt(doc, %{}), @default_line_pt, 0.001
    end

    test "a `\\u000B` soft line break inside a paragraph counts as one more line" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{"content" => [para("first line\u000Bsecond line\n")]}
        }
      }

      # One soft break → 2 lines, not 1 — a plain single-line paragraph would
      # estimate to @default_line_pt instead of double that.
      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}), @default_line_pt * 2, 0.001
    end

    test "a soft line break split across separate textRun elements still counts" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"textRun" => %{"content" => "one\u000B"}},
                    %{"textRun" => %{"content" => "two\n"}}
                  ]
                }
              }
            ]
          }
        }
      }

      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}), @default_line_pt * 2, 0.001
    end

    test "a horizontalRule element counts as one extra line, sized like its sibling textRun" do
      doc = %{
        "documentStyle" => %{"defaultFooterId" => "f1"},
        "footers" => %{
          "f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"horizontalRule" => %{"textStyle" => %{}}},
                    %{"textRun" => %{"content" => "\n", "textStyle" => %{}}}
                  ]
                }
              }
            ]
          }
        }
      }

      # 2 lines (the rule + the trailing textRun's own line) at the default
      # font size (no fontSize on either element) — this is the shape of the
      # house footer's rule paragraph.
      assert_in_delta GoogleDocsClient.footer_extent_pt(doc, %{}), @default_line_pt * 2, 0.001
    end

    test "a horizontalRule element's own textStyle.fontSize is used when no textRun has one" do
      doc = %{
        "documentStyle" => %{"defaultFooterId" => "f1"},
        "footers" => %{
          "f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "horizontalRule" => %{"textStyle" => %{"fontSize" => %{"magnitude" => 9.5}}}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      # 2 lines (base + the rule) at 9.5pt / default 115% lineSpacing.
      expected = 2 * 9.5 * 1.15 * 1.22
      assert_in_delta GoogleDocsClient.footer_extent_pt(doc, %{}), expected, 0.001
    end

    test "paragraphStyle.borderTop/borderBottom (width + padding) are added to the paragraph" do
      doc = %{
        "documentStyle" => %{"defaultFooterId" => "f1"},
        "footers" => %{
          "f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "textRun" => %{
                        "content" => "\n",
                        "textStyle" => %{"fontSize" => %{"magnitude" => 4.0}}
                      }
                    }
                  ],
                  "paragraphStyle" => %{
                    "spaceBelow" => %{"magnitude" => 6.0},
                    "borderBottom" => %{
                      "width" => %{"magnitude" => 0.75, "unit" => "PT"},
                      "padding" => %{"magnitude" => 1.0, "unit" => "PT"}
                    }
                  }
                }
              }
            ]
          }
        }
      }

      # Some OTHER templates draw the house footer's rule as a thin bordered
      # paragraph instead of a `horizontalRule` element: 4pt font, 6pt
      # spaceBelow, 0.75pt borderBottom width, 1pt padding — matches a live
      # measurement of one such template (2026-09-23).
      expected = 4.0 * 1.15 * 1.22 + 6.0 + 0.75 + 1.0
      assert_in_delta GoogleDocsClient.footer_extent_pt(doc, %{}), expected, 0.001
    end

    test "a table is the sum of its rows; a row is the tallest of its cells" do
      no_padding = %{
        "paddingTop" => %{"magnitude" => 0.0},
        "paddingBottom" => %{"magnitude" => 0.0}
      }

      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              %{
                "table" => %{
                  "tableRows" => [
                    %{
                      "tableCells" => [
                        %{"content" => [para("short")], "tableCellStyle" => no_padding},
                        %{"content" => [para("a"), para("b")], "tableCellStyle" => no_padding}
                      ]
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      # cell 1: one paragraph (@default_line_pt). cell 2: two paragraphs
      # (2 * @default_line_pt). Row = max, not sum.
      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}), @default_line_pt * 2, 0.001
    end

    test "a cell's own tableCellStyle padding is added when the table declares it" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              %{
                "table" => %{
                  "tableRows" => [
                    %{
                      "tableCells" => [
                        %{
                          "content" => [para("x")],
                          "tableCellStyle" => %{
                            "paddingTop" => %{"magnitude" => 3.0, "unit" => "PT"},
                            "paddingBottom" => %{"magnitude" => 4.0, "unit" => "PT"}
                          }
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}),
                      @default_line_pt + 3.0 + 4.0,
                      0.001
    end

    test "a cell's own tableCellStyle border widths are added on top of its padding" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              %{
                "table" => %{
                  "tableRows" => [
                    %{
                      "tableCells" => [
                        %{
                          "content" => [para("x")],
                          "tableCellStyle" => %{
                            "paddingTop" => %{"magnitude" => 0.0},
                            "paddingBottom" => %{"magnitude" => 0.0},
                            "borderTop" => %{"width" => %{"magnitude" => 1.0, "unit" => "PT"}},
                            "borderBottom" => %{"width" => %{"magnitude" => 2.0, "unit" => "PT"}}
                          }
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}),
                      @default_line_pt + 1.0 + 2.0,
                      0.001
    end

    test "falls back to 5pt/5pt cell padding when the table doesn't declare it" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "headers" => %{
          "h1" => %{
            "content" => [
              %{"table" => %{"tableRows" => [%{"tableCells" => [%{"content" => [para("x")]}]}]}}
            ]
          }
        }
      }

      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}),
                      @default_line_pt + 5.0 + 5.0,
                      0.001
    end

    test "a paragraph holding an inline image is sized from the image, not the font formula" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "inlineObjects" => Map.new([inline_object("img1", 40.0)]),
        "headers" => %{"h1" => %{"content" => [para_with_image("img1")]}}
      }

      # 40pt image + 5pt/5pt fallback padding (no explicit embeddedObject margins).
      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}), 50.0, 0.001
    end

    test "an inline image's own embeddedObject margins are used when present" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "h1"},
        "inlineObjects" =>
          Map.new([
            inline_object("img1", 40.0, 100.0, %{
              "marginTop" => %{"magnitude" => 2.0, "unit" => "PT"},
              "marginBottom" => %{"magnitude" => 3.0, "unit" => "PT"}
            })
          ]),
        "headers" => %{"h1" => %{"content" => [para_with_image("img1")]}}
      }

      assert_in_delta GoogleDocsClient.header_extent_pt(doc, %{}), 40.0 + 2.0 + 3.0, 0.001
    end

    test "no default id (section or document) estimates to 0.0" do
      doc = %{"documentStyle" => %{}}
      assert GoogleDocsClient.header_extent_pt(doc, %{}) == 0.0
      assert GoogleDocsClient.footer_extent_pt(doc, %{}) == 0.0
    end

    test "an empty (0-content) segment estimates to 0.0" do
      doc = %{
        "documentStyle" => %{"defaultFooterId" => "f1"},
        "footers" => %{"f1" => %{"content" => []}}
      }

      assert GoogleDocsClient.footer_extent_pt(doc, %{}) == 0.0
    end

    test "a section's own defaultHeaderId wins over the document's" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "doc-header"},
        "headers" => %{
          "doc-header" => %{"content" => [para("doc")]},
          "sec-header" => %{"content" => [para("sec"), para("sec2")]}
        }
      }

      assert_in_delta(
        GoogleDocsClient.header_extent_pt(doc, %{"defaultHeaderId" => "sec-header"}),
        @default_line_pt * 2,
        0.001
      )
    end
  end
end
