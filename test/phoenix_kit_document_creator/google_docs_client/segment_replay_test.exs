defmodule PhoenixKitDocumentCreator.GoogleDocsClient.SegmentReplayTest do
  @moduledoc """
  Coverage for `SegmentReplay`'s fingerprint and pure request builders.

  The fingerprint fixtures below are trimmed, hand-built versions of three
  REAL "home" header/footer segments (three separately-templated documents
  meant to share one look) fetched live 2026-09-23 via
  `GoogleDocsClient.get_document/1` against a production stand — all
  requisites text and image URIs replaced with placeholders here; see
  `SegmentReplay`'s moduledoc for the specific discrepancies (table/image
  size, cell padding, rule representation) this is calibrated to tolerate.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient.SegmentReplay

  # ---- fixtures, matching the live shapes -------------------------------

  defp para(elements, style \\ %{}) do
    %{"paragraph" => %{"elements" => elements, "paragraphStyle" => style}}
  end

  defp text_run(content, style \\ %{}) do
    %{"textRun" => %{"content" => content, "textStyle" => style}}
  end

  defp image_run(id) do
    %{"inlineObjectElement" => %{"inlineObjectId" => id, "textStyle" => %{}}}
  end

  defp cell(content),
    do: %{"content" => content, "tableCellStyle" => %{"columnSpan" => 1, "rowSpan" => 1}}

  defp table(cells, opts \\ []) do
    %{
      "table" => %{
        "rows" => 1,
        "columns" => length(cells),
        "tableRows" => [%{"tableCells" => cells}],
        "tableStyle" => %{"tableColumnProperties" => Keyword.get(opts, :column_properties, [])}
      }
    }
  end

  defp inline_object(width, height, uri) do
    %{
      "inlineObjectProperties" => %{
        "embeddedObject" => %{
          "size" => %{
            "width" => %{"magnitude" => width, "unit" => "PT"},
            "height" => %{"magnitude" => height, "unit" => "PT"}
          },
          "imageProperties" => %{"contentUri" => uri}
        }
      }
    }
  end

  # A header shaped like the three live homes: tiny spacer, 1x2 table
  # (logo | empty text cell), tiny spacer.
  defp home_header(image_id, image_dims, column_pt) do
    [
      para([text_run("\n", %{"fontSize" => %{"magnitude" => 1, "unit" => "PT"}})]),
      table(
        [
          cell([para([image_run(image_id), text_run("\n")])]),
          cell([
            para([text_run("\n", %{"foregroundColor" => %{"color" => %{"rgbColor" => %{}}}})], %{
              "alignment" => "END"
            })
          ])
        ],
        column_properties: [
          %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => column_pt, "unit" => "PT"}},
          %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => column_pt, "unit" => "PT"}}
        ]
      ),
      para([text_run("\n", %{"fontSize" => %{"magnitude" => 2, "unit" => "PT"}})])
    ]
    |> then(
      &{&1,
       %{
         image_id =>
           inline_object(
             elem(image_dims, 0),
             elem(image_dims, 1),
             "https://example.test/#{image_id}"
           )
       }}
    )
  end

  # A footer shaped like the three live homes: spacer, a "rule" (either a
  # native horizontalRule or a bordered stand-in paragraph), spacer, a 1x2
  # requisites table, spacer.
  defp home_footer(rule_shape) do
    rule_paragraph =
      case rule_shape do
        :horizontal_rule ->
          para([
            %{
              "horizontalRule" => %{
                "textStyle" => %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}}
              }
            },
            text_run("\n", %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}})
          ])

        :bordered_paragraph ->
          para(
            [text_run("\n", %{"fontSize" => %{"magnitude" => 4, "unit" => "PT"}})],
            %{
              "borderBottom" => %{
                "color" => %{"color" => %{"rgbColor" => %{"red" => 0.45}}},
                "dashStyle" => "SOLID",
                "padding" => %{"magnitude" => 1, "unit" => "PT"},
                "width" => %{"magnitude" => 0.75, "unit" => "PT"}
              },
              "spaceBelow" => %{"magnitude" => 6, "unit" => "PT"}
            }
          )
      end

    [
      para([text_run("\n", %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}})], %{
        "alignment" => "START"
      }),
      rule_paragraph,
      para([text_run("\n", %{"fontSize" => %{"magnitude" => 1.5, "unit" => "PT"}})]),
      table([
        cell([
          para([
            text_run("Example Company OÜ\n", %{
              "fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}
            })
          ])
        ]),
        cell([
          para(
            [text_run("Reg. kood 123\n", %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}})],
            %{"alignment" => "END"}
          )
        ])
      ]),
      para([text_run("\n", %{"fontSize" => %{"magnitude" => 1, "unit" => "PT"}})])
    ]
  end

  describe "fingerprint/2 — home headers across differently-rebuilt templates" do
    test "two home headers with different logos/column widths/URIs fingerprint equal" do
      {hinna, hinna_objects} = home_header("kix.hinna_logo", {236.25, 46.0}, 261.0)
      {leping, leping_objects} = home_header("kix.leping_logo", {215.21, 41.99}, 225.64)

      assert SegmentReplay.fingerprint(hinna, hinna_objects) ==
               SegmentReplay.fingerprint(leping, leping_objects)
    end

    test "a genuinely different header (extra line of text) fingerprints differently" do
      {hinna, hinna_objects} = home_header("kix.hinna_logo", {236.25, 46.0}, 261.0)

      joonised_two_lines = [
        para([text_run("\n", %{"fontSize" => %{"magnitude" => 1, "unit" => "PT"}})]),
        table([
          cell([para([image_run("kix.j_logo"), text_run("\n")])]),
          cell([
            para([text_run("Joonised {{customer_name}}\n")], %{"alignment" => "END"}),
            para([text_run("Kõik joonised kontrollib tootmine!\n")], %{"alignment" => "END"})
          ])
        ]),
        para([text_run("\n", %{"fontSize" => %{"magnitude" => 2, "unit" => "PT"}})])
      ]

      joonised_objects = %{"kix.j_logo" => inline_object(215.0, 42.0, "https://example.test/j")}

      refute SegmentReplay.fingerprint(hinna, hinna_objects) ==
               SegmentReplay.fingerprint(joonised_two_lines, joonised_objects)
    end
  end

  describe "fingerprint/2 — rule unification" do
    test "a native horizontalRule and a rebuilt bordered paragraph fingerprint the same" do
      hr_footer = home_footer(:horizontal_rule)
      bordered_footer = home_footer(:bordered_paragraph)

      assert SegmentReplay.fingerprint(hr_footer, %{}) ==
               SegmentReplay.fingerprint(bordered_footer, %{})
    end

    test "a rule token never leaks the paragraph's own font size/border width" do
      footer_a = home_footer(:bordered_paragraph)

      footer_b =
        List.update_at(footer_a, 1, fn %{"paragraph" => p} ->
          %{
            "paragraph" =>
              put_in(
                p,
                ["elements", Access.at(0), "textRun", "textStyle", "fontSize", "magnitude"],
                5
              )
          }
        end)

      assert SegmentReplay.fingerprint(footer_a, %{}) == SegmentReplay.fingerprint(footer_b, %{})
    end
  end

  describe "fingerprint/2 — real differences are still detected" do
    test "different cell text differs" do
      content = fn text ->
        [table([cell([para([text_run(text)])])])]
      end

      refute SegmentReplay.fingerprint(content.("Hello\n"), %{}) ==
               SegmentReplay.fingerprint(content.("Goodbye\n"), %{})
    end

    test "bold vs plain run differs" do
      plain = [para([text_run("Hi\n")])]
      bold = [para([text_run("Hi\n", %{"bold" => true})])]

      refute SegmentReplay.fingerprint(plain, %{}) == SegmentReplay.fingerprint(bold, %{})
    end

    test "no header/footer content at all fingerprints as an empty list" do
      assert SegmentReplay.fingerprint([], %{}) == []
    end
  end

  describe "with_segment_id/2" do
    test "tags top-level location/range/tableStartLocation, leaving other keys alone" do
      requests = [
        %{"insertText" => %{"location" => %{"index" => 0}, "text" => "hi"}},
        %{
          "updateParagraphStyle" => %{
            "range" => %{"startIndex" => 0, "endIndex" => 2},
            "paragraphStyle" => %{"alignment" => "START"},
            "fields" => "alignment"
          }
        },
        %{
          "updateTableColumnProperties" => %{
            "tableStartLocation" => %{"index" => 5},
            "columnIndices" => [0],
            "tableColumnProperties" => %{"widthType" => "FIXED_WIDTH"},
            "fields" => "widthType"
          }
        }
      ]

      tagged = SegmentReplay.with_segment_id(requests, "kix.seg1")

      assert Enum.at(tagged, 0)["insertText"]["location"] == %{
               "index" => 0,
               "segmentId" => "kix.seg1"
             }

      assert Enum.at(tagged, 1)["updateParagraphStyle"]["range"]["segmentId"] == "kix.seg1"

      assert Enum.at(tagged, 2)["updateTableColumnProperties"]["tableStartLocation"]["segmentId"] ==
               "kix.seg1"
    end

    test "tags a doubly-nested tableStartLocation (updateTableCellStyle)" do
      request = [
        %{
          "updateTableCellStyle" => %{
            "tableRange" => %{
              "tableCellLocation" => %{
                "tableStartLocation" => %{"index" => 3},
                "rowIndex" => 0,
                "columnIndex" => 1
              },
              "rowSpan" => 1,
              "columnSpan" => 1
            },
            "tableCellStyle" => %{"contentAlignment" => "TOP"},
            "fields" => "contentAlignment"
          }
        }
      ]

      [tagged] = SegmentReplay.with_segment_id(request, "kix.seg2")

      inner =
        tagged["updateTableCellStyle"]["tableRange"]["tableCellLocation"]["tableStartLocation"]

      assert inner == %{"index" => 3, "segmentId" => "kix.seg2"}

      # tableRange itself carries no location key of its own — untouched.
      refute Map.has_key?(tagged["updateTableCellStyle"]["tableRange"], "segmentId")
    end

    test "never overwrites an already-present segmentId" do
      requests = [
        %{"insertText" => %{"location" => %{"index" => 0, "segmentId" => "kix.original"}}}
      ]

      [tagged] = SegmentReplay.with_segment_id(requests, "kix.new")

      assert tagged["insertText"]["location"]["segmentId"] == "kix.original"
    end
  end

  describe "create_segment_request/2 and segment_id_from_replies/2" do
    test "header" do
      assert SegmentReplay.create_segment_request(:header, 41) == %{
               "createHeader" => %{
                 "type" => "DEFAULT",
                 "sectionBreakLocation" => %{"index" => 41}
               }
             }

      assert SegmentReplay.segment_id_from_replies(:header, [
               %{"createHeader" => %{"headerId" => "kix.h1"}}
             ]) ==
               "kix.h1"
    end

    test "footer" do
      assert SegmentReplay.create_segment_request(:footer, 41) == %{
               "createFooter" => %{
                 "type" => "DEFAULT",
                 "sectionBreakLocation" => %{"index" => 41}
               }
             }

      assert SegmentReplay.segment_id_from_replies(:footer, [
               %{"createFooter" => %{"footerId" => "kix.f1"}}
             ]) ==
               "kix.f1"
    end

    test "no matching reply returns nil" do
      assert SegmentReplay.segment_id_from_replies(:header, [%{"insertText" => %{}}]) == nil
    end
  end

  describe "skeleton_requests/3" do
    test "insertText at index 0, then paragraph style before text style" do
      paragraphs = [
        %{
          start_offset: 0,
          length: 3,
          style: %{
            alignment: "START",
            line_spacing: nil,
            space_above: nil,
            space_below: nil,
            named_style_type: "NORMAL_TEXT",
            indent_start: nil,
            indent_first_line: nil
          },
          bullet: nil
        }
      ]

      runs = [
        %{
          text: "Hi\n",
          start_offset: 0,
          length: 3,
          bold: false,
          italic: false,
          font_size: nil,
          color: nil
        }
      ]

      [insert, para_style, text_style] = SegmentReplay.skeleton_requests("Hi\n", runs, paragraphs)

      assert insert == %{"insertText" => %{"location" => %{"index" => 0}, "text" => "Hi\n"}}

      assert %{"updateParagraphStyle" => %{"range" => %{"startIndex" => 0, "endIndex" => 3}}} =
               para_style

      assert %{"updateTextStyle" => %{"range" => %{"startIndex" => 0, "endIndex" => 3}}} =
               text_style
    end

    test "empty text skips insertText — the Docs API rejects an empty one, same as body's/a cell's" do
      paragraphs = [
        %{
          start_offset: 0,
          length: 1,
          style: %{
            alignment: nil,
            line_spacing: nil,
            space_above: nil,
            space_below: nil,
            named_style_type: "NORMAL_TEXT",
            indent_start: nil,
            indent_first_line: nil
          },
          bullet: nil
        }
      ]

      # a fully-empty template (no captured runs at all — e.g. a single
      # blank paragraph whose own trailing newline was stripped by the
      # caller, see GoogleDocsClient.skeleton_insert_text/2) still gets its
      # paragraph style applied, targeting the segment's own pre-existing
      # newline at [0, 1).
      assert [para_style] = SegmentReplay.skeleton_requests("", [], paragraphs)

      assert %{"updateParagraphStyle" => %{"range" => %{"startIndex" => 0, "endIndex" => 1}}} =
               para_style
    end
  end

  describe "extra_paragraph_style_requests/2" do
    defp span(start_offset, length), do: %{start_offset: start_offset, length: length}

    defp no_paragraph_extras do
      %{
        border_top: nil,
        border_bottom: nil,
        border_left: nil,
        border_right: nil,
        shading: nil,
        space_below: nil
      }
    end

    test "one request per span carrying at least one extra field, none for a span with none" do
      border = %{"width" => %{"magnitude" => 0.75, "unit" => "PT"}}

      spans_with_extras = [
        {span(0, 1), %{no_paragraph_extras() | border_bottom: border}},
        {span(1, 3), no_paragraph_extras()}
      ]

      assert [request] = SegmentReplay.extra_paragraph_style_requests(10, spans_with_extras)

      assert request == %{
               "updateParagraphStyle" => %{
                 "range" => %{"startIndex" => 10, "endIndex" => 11},
                 "paragraphStyle" => %{"borderBottom" => border},
                 "fields" => "borderBottom"
               }
             }
    end

    test "forced spaceBelow (the horizontalRule stand-in) is included when present" do
      extras = %{no_paragraph_extras() | space_below: 6.0}

      assert [request] = SegmentReplay.extra_paragraph_style_requests(0, [{span(0, 1), extras}])

      assert request["updateParagraphStyle"]["paragraphStyle"]["spaceBelow"] ==
               %{"magnitude" => 6.0, "unit" => "PT"}
    end

    test "a zero-length span never gets a request" do
      extras = %{no_paragraph_extras() | shading: %{"backgroundColor" => %{}}}
      assert SegmentReplay.extra_paragraph_style_requests(0, [{span(0, 0), extras}]) == []
    end
  end

  describe "extra_text_style_requests/2" do
    defp run_span(start_offset, length), do: %{start_offset: start_offset, length: length}

    defp no_text_extras do
      %{
        weighted_font_family: nil,
        underline: nil,
        link: nil,
        baseline_offset: nil,
        font_size: nil
      }
    end

    test "one request per run carrying at least one extra field, none for a run with none" do
      family = %{"fontFamily" => "Calibri", "weight" => 400}
      link = %{"url" => "http://example.test"}

      runs_with_extras = [
        {run_span(0, 5),
         %{no_text_extras() | weighted_font_family: family, underline: true, link: link}},
        {run_span(5, 2), no_text_extras()}
      ]

      assert [request] = SegmentReplay.extra_text_style_requests(100, runs_with_extras)
      style = request["updateTextStyle"]

      assert style["range"] == %{"startIndex" => 100, "endIndex" => 105}

      assert style["textStyle"] == %{
               "weightedFontFamily" => family,
               "underline" => true,
               "link" => link
             }

      # `fields` lists the same keys as `textStyle` — order isn't part of the
      # contract (plain map key order isn't specified).
      assert MapSet.new(String.split(style["fields"], ",")) ==
               MapSet.new(Map.keys(style["textStyle"]))
    end

    test "a forced font_size (the horizontalRule stand-in) becomes a fontSize dimension" do
      extras = %{no_text_extras() | font_size: 4.0}

      assert [request] = SegmentReplay.extra_text_style_requests(0, [{run_span(0, 1), extras}])

      assert request["updateTextStyle"]["textStyle"]["fontSize"] == %{
               "magnitude" => 4.0,
               "unit" => "PT"
             }
    end
  end

  describe "replayable?/2" do
    defp paragraph(elements, extra \\ %{}),
      do: %{"paragraph" => Map.merge(%{"elements" => elements}, extra)}

    defp text(content), do: %{"textRun" => %{"content" => content}}
    defp image(id), do: %{"inlineObjectElement" => %{"inlineObjectId" => id}}

    defp one_cell_table(cell_content),
      do: %{"table" => %{"tableRows" => [%{"tableCells" => [%{"content" => cell_content}]}]}}

    @logo %{
      "kix.logo" => %{
        "inlineObjectProperties" => %{
          "embeddedObject" => %{
            "imageProperties" => %{"contentUri" => "https://example.test/l.png"}
          }
        }
      }
    }

    test "text, rule paragraphs, and an image-only table cell replay" do
      content = [
        paragraph([text("Reg\n")]),
        paragraph([%{"horizontalRule" => %{}}, text("\n")]),
        one_cell_table([paragraph([image("kix.logo"), text("\n")])])
      ]

      assert SegmentReplay.replayable?(content, @logo)
    end

    test "page numbers, a paragraph-level image, and a floating object don't" do
      refute SegmentReplay.replayable?(
               [paragraph([%{"autoText" => %{"type" => "PAGE_NUMBER"}}, text("\n")])],
               %{}
             )

      refute SegmentReplay.replayable?([paragraph([image("kix.logo"), text("\n")])], @logo)

      refute SegmentReplay.replayable?(
               [paragraph([text("\n")], %{"positionedObjectIds" => ["kix.float"]})],
               %{}
             )
    end

    test "a cell image without a contentUri, next to text, or doubled doesn't" do
      refute SegmentReplay.replayable?([one_cell_table([paragraph([image("kix.chart")])])], %{})

      refute SegmentReplay.replayable?(
               [one_cell_table([paragraph([image("kix.logo"), text("Acme\n")])])],
               @logo
             )

      refute SegmentReplay.replayable?(
               [one_cell_table([paragraph([image("kix.logo"), image("kix.logo")])])],
               @logo
             )
    end
  end

  describe "table_fill_requests/2" do
    defp base_entry(overrides) do
      Map.merge(
        %{
          table_start: 10,
          columns: 2,
          cells: [%{insert_index: 11}, %{insert_index: 13}],
          column_properties: [],
          cell_styles: [
            %{
              content_alignment: nil,
              padding_top: nil,
              padding_bottom: nil,
              padding_left: nil,
              padding_right: nil
            },
            %{
              content_alignment: "TOP",
              padding_top: %{"magnitude" => 5.0, "unit" => "PT"},
              padding_bottom: nil,
              padding_left: nil,
              padding_right: nil
            }
          ],
          cell_texts: ["", "Hi\n"],
          cell_runs: [
            [],
            [
              %{
                text: "Hi\n",
                start_offset: 0,
                length: 3,
                bold: false,
                italic: false,
                font_size: nil,
                color: nil
              }
            ]
          ],
          cell_paragraphs: [
            [%{start_offset: 0, length: 1, style: unset_style(), bullet: nil}],
            [%{start_offset: 0, length: 3, style: unset_style(), bullet: nil}]
          ],
          cell_image_ids: [nil, nil],
          cell_paragraph_extras: [[], []],
          cell_run_extras: [[], []]
        },
        overrides
      )
    end

    defp unset_style do
      %{
        alignment: nil,
        line_spacing: nil,
        space_above: nil,
        space_below: nil,
        named_style_type: "NORMAL_TEXT",
        indent_start: nil,
        indent_first_line: nil
      }
    end

    test "column widths, cell style (border always cleared, padding/alignment replayed), and cell fill" do
      entry =
        base_entry(%{
          column_properties: [
            %{width_type: "FIXED_WIDTH", magnitude: 225.6, unit: "PT"},
            %{width_type: "EVENLY_DISTRIBUTED", magnitude: nil, unit: nil}
          ]
        })

      requests = SegmentReplay.table_fill_requests([entry], %{})

      assert [
               %{
                 "updateTableColumnProperties" => %{
                   "tableStartLocation" => %{"index" => 10},
                   "columnIndices" => [0]
                 }
               }
             ] =
               Enum.filter(requests, &Map.has_key?(&1, "updateTableColumnProperties"))

      cell_styles = Enum.filter(requests, &Map.has_key?(&1, "updateTableCellStyle"))
      assert length(cell_styles) == 2

      [col0_style, col1_style] =
        Enum.sort_by(
          cell_styles,
          & &1["updateTableCellStyle"]["tableRange"]["tableCellLocation"]["columnIndex"]
        )

      # cleared border on every cell, even the one with no captured style at all.
      assert col0_style["updateTableCellStyle"]["tableCellStyle"]["borderTop"]["width"][
               "magnitude"
             ] == 0.0

      refute Map.has_key?(col0_style["updateTableCellStyle"]["tableCellStyle"], "paddingTop")

      assert col1_style["updateTableCellStyle"]["tableCellStyle"]["contentAlignment"] == "TOP"

      assert col1_style["updateTableCellStyle"]["tableCellStyle"]["paddingTop"] == %{
               "magnitude" => 5.0,
               "unit" => "PT"
             }

      assert Enum.any?(
               requests,
               &match?(%{"insertText" => %{"location" => %{"index" => 13}, "text" => "Hi\n"}}, &1)
             )

      # the empty first cell gets only its paragraph style, no insertText.
      refute Enum.any?(
               requests,
               &match?(%{"insertText" => %{"location" => %{"index" => 11}}}, &1)
             )
    end

    test "an image cell gets its paragraph style then an insertInlineImage with the source's own size/uri" do
      entry =
        base_entry(%{
          cell_texts: ["", ""],
          cell_runs: [[], []],
          cell_image_ids: ["kix.logo", nil]
        })

      inline_objects = %{
        "kix.logo" => inline_object(236.25, 46.0, "https://example.test/logo.png")
      }

      requests = SegmentReplay.table_fill_requests([entry], inline_objects)

      image_request = Enum.find(requests, &Map.has_key?(&1, "insertInlineImage"))
      assert image_request["insertInlineImage"]["location"]["index"] == 11
      assert image_request["insertInlineImage"]["uri"] == "https://example.test/logo.png"

      assert image_request["insertInlineImage"]["objectSize"] == %{
               "width" => %{"magnitude" => 236.25, "unit" => "PT"},
               "height" => %{"magnitude" => 46.0, "unit" => "PT"}
             }

      # paragraph style for the image cell is still applied.
      assert Enum.any?(
               requests,
               &match?(
                 %{
                   "updateParagraphStyle" => %{"range" => %{"startIndex" => 11, "endIndex" => 12}}
                 },
                 &1
               )
             )
    end

    test "a multi-row table's cell styles are addressed row-major, never past the last column" do
      style = %{
        content_alignment: nil,
        padding_top: nil,
        padding_bottom: nil,
        padding_left: nil,
        padding_right: nil
      }

      empty_paragraph = [%{start_offset: 0, length: 1, style: unset_style(), bullet: nil}]

      entry =
        base_entry(%{
          cells: Enum.map([11, 13, 16, 18], &%{insert_index: &1}),
          cell_styles: List.duplicate(style, 4),
          cell_texts: List.duplicate("", 4),
          cell_runs: List.duplicate([], 4),
          cell_paragraphs: List.duplicate(empty_paragraph, 4),
          cell_image_ids: List.duplicate(nil, 4),
          cell_paragraph_extras: List.duplicate([], 4),
          cell_run_extras: List.duplicate([], 4)
        })

      locations =
        [entry]
        |> SegmentReplay.table_fill_requests(%{})
        |> Enum.filter(&Map.has_key?(&1, "updateTableCellStyle"))
        |> Enum.map(fn request ->
          location = request["updateTableCellStyle"]["tableRange"]["tableCellLocation"]
          {location["rowIndex"], location["columnIndex"]}
        end)

      assert locations == [{0, 0}, {0, 1}, {1, 0}, {1, 1}]
    end

    test "cell fill/image requests are sorted descending by index across the table" do
      entry =
        base_entry(%{
          cell_texts: ["First\n", "Second\n"],
          cell_runs: [[], []]
        })

      requests = SegmentReplay.table_fill_requests([entry], %{})

      insert_indices =
        requests
        |> Enum.filter(&Map.has_key?(&1, "insertText"))
        |> Enum.map(& &1["insertText"]["location"]["index"])

      assert insert_indices == Enum.sort(insert_indices, :desc)
    end

    test "a cell's extra paragraph/run style (border, font-family/link) is applied at that cell's own index" do
      family = %{"fontFamily" => "Calibri", "weight" => 400}
      link = %{"url" => "https://example.test"}

      entry =
        base_entry(%{
          cell_texts: ["", "Hi\n"],
          cell_paragraph_extras: [
            [],
            [
              {%{start_offset: 0, length: 3},
               %{
                 border_top: nil,
                 border_bottom: nil,
                 border_left: nil,
                 border_right: nil,
                 shading: nil
               }}
            ]
          ],
          cell_run_extras: [
            [],
            [
              {%{start_offset: 0, length: 3},
               %{
                 weighted_font_family: family,
                 underline: nil,
                 link: link,
                 baseline_offset: nil,
                 font_size: nil
               }}
            ]
          ]
        })

      requests = SegmentReplay.table_fill_requests([entry], %{})

      link_request =
        Enum.find(requests, fn
          %{"updateTextStyle" => %{"textStyle" => %{"link" => _}}} -> true
          _ -> false
        end)

      assert link_request["updateTextStyle"]["range"] == %{"startIndex" => 13, "endIndex" => 16}

      assert link_request["updateTextStyle"]["textStyle"] == %{
               "weightedFontFamily" => family,
               "link" => link
             }
    end
  end
end
