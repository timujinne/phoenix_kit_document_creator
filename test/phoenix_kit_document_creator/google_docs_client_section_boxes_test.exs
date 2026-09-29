defmodule PhoenixKitDocumentCreator.GoogleDocsClientSectionBoxesTest do
  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # A4-ish page: 595.28 x 841.89pt, default 72pt margins on every side unless noted.
  defp doc_style(overrides \\ %{}) do
    Map.merge(
      %{
        "pageSize" => %{
          "width" => %{"magnitude" => 595.28, "unit" => "PT"},
          "height" => %{"magnitude" => 841.89, "unit" => "PT"}
        }
      },
      overrides
    )
  end

  defp section_break(start_index, style \\ %{}) do
    %{"startIndex" => start_index, "sectionBreak" => %{"sectionStyle" => style}}
  end

  describe "section_boxes/1" do
    test "single portrait section — width/height minus default 72pt margins" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert box.start_index == 0
      assert_in_delta box.width_pt, 595.28 - 144.0, 0.001
      assert_in_delta box.height_pt, 841.89 - 144.0, 0.001
      assert box.margin_top == 72.0
      assert box.margin_bottom == 72.0
    end

    test "landscape section via document-level flipPageOrientation" do
      doc = %{
        "documentStyle" => Map.put(doc_style(), "flipPageOrientation", true),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      # Page dimensions are swapped: width becomes the taller side.
      assert_in_delta box.width_pt, 841.89 - 144.0, 0.001
      assert_in_delta box.height_pt, 595.28 - 144.0, 0.001
    end

    test "a section with its own flipPageOrientation: false wins over doc flip: true" do
      doc = %{
        "documentStyle" => Map.put(doc_style(), "flipPageOrientation", true),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 20, "paragraph" => %{}},
            section_break(20, %{"flipPageOrientation" => false}),
            %{"startIndex" => 21, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box1, box2] = GoogleDocsClient.section_boxes(doc)

      # Section 1 inherits doc flip: true → landscape shape.
      assert_in_delta box1.width_pt, 841.89 - 144.0, 0.001
      assert box1.start_index == 0
      assert box1.end_index == 20

      # Section 2 overrides flip: false → portrait shape, despite doc flip: true.
      assert_in_delta box2.width_pt, 595.28 - 144.0, 0.001
      assert box2.start_index == 20
    end

    test "section-level margins override the document's" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0, %{
              "marginTop" => %{"magnitude" => 36.0, "unit" => "PT"},
              "marginBottom" => %{"magnitude" => 36.0, "unit" => "PT"},
              "marginLeft" => %{"magnitude" => 36.0, "unit" => "PT"},
              "marginRight" => %{"magnitude" => 36.0, "unit" => "PT"}
            }),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert_in_delta box.width_pt, 595.28 - 72.0, 0.001
      assert_in_delta box.height_pt, 841.89 - 72.0, 0.001
      assert box.margin_top == 36.0
      assert box.margin_bottom == 36.0
    end

    test "a zero margin (proto3 drops the magnitude) is 0pt, not the 72pt default" do
      zero = %{"unit" => "PT"}

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0, %{
              "marginTop" => zero,
              "marginBottom" => zero,
              "marginLeft" => zero,
              "marginRight" => zero
            }),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert_in_delta box.width_pt, 595.28, 0.001
      assert_in_delta box.height_pt, 841.89, 0.001
      assert box.margin_top == 0.0
    end

    test "no pageSize → falls back like content_width_pt/1 (468pt width, Letter height 792-144)" do
      doc = %{
        "documentStyle" => %{},
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert box.width_pt == 468.0
      assert box.height_pt == 648.0
    end

    test "multiple sections span from one sectionBreak's startIndex to the next" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 20, "paragraph" => %{}},
            section_break(20),
            %{"startIndex" => 21, "endIndex" => 100, "paragraph" => %{}}
          ]
        }
      }

      [box1, box2] = GoogleDocsClient.section_boxes(doc)

      assert box1.start_index == 0
      assert box1.end_index == 20
      assert box2.start_index == 20
      assert box2.end_index == 100
    end

    test "single-section document: box width matches content_width_pt/1 (with an explicit pageSize)" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert box.width_pt == GoogleDocsClient.content_width_pt(doc)
    end

    test "single-section document: box width matches content_width_pt/1's fallback (no pageSize)" do
      doc = %{
        "documentStyle" => %{},
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert box.width_pt == GoogleDocsClient.content_width_pt(doc)
      assert box.width_pt == 468.0
    end
  end

  describe "section_boxes/1 — body_top_pt / body_bottom_pt" do
    # A default-style (11pt / 115% lineSpacing) line's height, including the
    # @font_leading (1.22) multiplier `estimate_paragraph_height_pt/1`
    # applies.
    @default_line_pt 11.0 * 1.15 * 1.22

    defp header_paragraph(text) do
      %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => text}}]}}
    end

    test "no header/footer content: body_top/bottom equal the nominal margins" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      assert box.body_top_pt == 72.0
      assert_in_delta box.body_bottom_pt, 841.89 - 72.0, 0.001
    end

    test "a header/footer shorter than its own margin: body_top/bottom still equal the margins" do
      doc = %{
        "documentStyle" =>
          Map.merge(doc_style(), %{
            "defaultHeaderId" => "h1",
            "defaultFooterId" => "f1"
          }),
        "headers" => %{"h1" => %{"content" => [header_paragraph("\n")]}},
        "footers" => %{"f1" => %{"content" => [header_paragraph("\n")]}},
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      # header/footer extent (@default_line_pt, one default-style line) +
      # marginHeader/Footer (36pt default) — well under marginTop/Bottom
      # (72pt) — the nominal margin wins the `max`.
      assert box.body_top_pt == 72.0
      assert_in_delta box.body_bottom_pt, 841.89 - 72.0, 0.001
    end

    test "a header/footer taller than its own margin pushes the body in" do
      tall_content = [header_paragraph("one"), header_paragraph("two"), header_paragraph("three")]

      doc = %{
        "documentStyle" =>
          Map.merge(doc_style(), %{
            "defaultHeaderId" => "h1",
            "defaultFooterId" => "f1"
          }),
        "headers" => %{"h1" => %{"content" => tall_content}},
        "footers" => %{"f1" => %{"content" => tall_content}},
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      # 3 default-style lines (3 * @default_line_pt); marginHeader/Footer (36)
      # + that comfortably clears the nominal 72pt margin, so the
      # header/footer content wins the `max`.
      extent = 3 * @default_line_pt
      assert_in_delta box.body_top_pt, 36.0 + extent, 0.001
      assert_in_delta box.body_bottom_pt, 841.89 - (36.0 + extent), 0.001
    end

    test "section-level header/footer margins are used when the section overrides them" do
      doc = %{
        "documentStyle" => Map.merge(doc_style(), %{"defaultHeaderId" => "h1"}),
        "headers" => %{"h1" => %{"content" => [header_paragraph("\n")]}},
        "body" => %{
          "content" => [
            section_break(0, %{"marginHeader" => %{"magnitude" => 0.0, "unit" => "PT"}}),
            %{"startIndex" => 1, "endIndex" => 50, "paragraph" => %{}}
          ]
        }
      }

      [box] = GoogleDocsClient.section_boxes(doc)

      # marginHeader override (0) + header extent (@default_line_pt), still
      # under marginTop (72) — nominal margin still wins.
      assert box.body_top_pt == 72.0
    end

    test "a section with no header of its own inherits the PREVIOUS section's, not the document's" do
      # Per the Docs API reference for defaultHeaderId/defaultFooterId: "If
      # unset, the value inherits from the previous SectionBreak's
      # SectionStyle. If the value is unset in the first SectionBreak, it
      # inherits from DocumentStyle's defaultHeaderId." Three sections:
      # section 1 has no header of its own (→ document default, "doc-h",
      # one default-style line); section 2 declares its own, taller header
      # ("sec2-h", 5 lines); section 3 has none of its own and must inherit
      # section 2's ("sec2-h"), NOT fall straight through to the document's
      # ("doc-h") — a `section_style["defaultHeaderId"] ||
      # document_style["defaultHeaderId"]` resolution (ignoring the chain)
      # would give section 3 the document's shorter header instead, failing
      # the body_top_pt equality assertion below.
      doc = %{
        "documentStyle" => Map.merge(doc_style(), %{"defaultHeaderId" => "doc-h"}),
        "headers" => %{
          "doc-h" => %{"content" => [header_paragraph("\n")]},
          "sec2-h" => %{
            "content" => for(_ <- 1..5, do: header_paragraph("\n"))
          }
        },
        "body" => %{
          "content" => [
            section_break(0),
            %{"startIndex" => 1, "endIndex" => 20, "paragraph" => %{}},
            section_break(20, %{"defaultHeaderId" => "sec2-h"}),
            %{"startIndex" => 21, "endIndex" => 40, "paragraph" => %{}},
            section_break(40),
            %{"startIndex" => 41, "endIndex" => 60, "paragraph" => %{}}
          ]
        }
      }

      [box1, box2, box3] = GoogleDocsClient.section_boxes(doc)

      # Section 1's one-line document-default header (36 + @default_line_pt
      # ≈ 51.4) is under marginTop (72) — the nominal margin wins there.
      assert box1.body_top_pt == 72.0
      assert_in_delta box2.body_top_pt, 36.0 + 5 * @default_line_pt, 0.001
      # Section 3 inherits section 2's header (5 lines), not the document's
      # (1 line) — same body_top_pt as section 2, not section 1.
      assert_in_delta box3.body_top_pt, box2.body_top_pt, 0.001
      assert abs(box3.body_top_pt - box1.body_top_pt) > 1.0
    end
  end
end
