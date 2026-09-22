defmodule PhoenixKitDocumentCreator.GoogleDocsClientAppendTablesTest do
  @moduledoc """
  Coverage for the append-with-tables pipeline described in
  `GoogleDocsClient.append_template/3`'s doc: `append_template/2` used to
  flatten a template via `get_document_text/1`, which silently dropped every
  table (and any `{{var}}` placeholder that lived only inside one). These
  tests cover the fix: `flatten_template_with_table_markers/1` (Phase 0),
  `find_table_marker_ranges/1` + `table_skeleton_requests/2` (Phase 1),
  the cell-fill phase (`build_table_fill_requests/3`, private — exercised
  through the flow tests), and the full `append_template/3` orchestration
  via injected `:get_fn`/`:batch_fn`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # The paragraphStyle payload/fields mask a paragraph with no explicit
  # `paragraphStyle` key replays as — see
  # `GoogleDocsClient.paragraph_style_requests/2`'s anti-inheritance doc.
  # Reused across every fixture below whose paragraphs don't set an explicit
  # style, which is most of them.
  #
  # Only `namedStyleType` carries a value: every other field stays in the
  # mask with NO value, which is how the Docs API spells "unset this
  # property" — the paragraph then inherits it from its named style instead
  # of from whatever paragraph sat at the insertion point.
  @unset_paragraph_style %{"namedStyleType" => "NORMAL_TEXT"}
  @paragraph_style_fields "alignment,lineSpacing,spaceAbove,spaceBelow,namedStyleType,indentStart,indentFirstLine"

  defp unset_paragraph_style_request(start_index, end_index) do
    %{
      "updateParagraphStyle" => %{
        "range" => %{"startIndex" => start_index, "endIndex" => end_index},
        "paragraphStyle" => @unset_paragraph_style,
        "fields" => @paragraph_style_fields
      }
    }
  end

  # Atom-keyed counterpart to @unset_paragraph_style — the internal span
  # shape `paragraph_style_requests/2` and `paragraph_bullet_requests/2`
  # consume, as opposed to the JSON-shaped request payload above.
  defp unset_span_style do
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

  # Minimal single-paragraph document, mirrors the helper used throughout the
  # sibling GoogleDocsClient test files.
  defp doc_with_text(text, start_index) do
    %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{"startIndex" => start_index, "textRun" => %{"content" => text}}
              ]
            }
          }
        ]
      }
    }
  end

  defp table_block(opts) do
    rows = Keyword.fetch!(opts, :rows)
    row_texts = Keyword.fetch!(opts, :row_texts)

    table_rows =
      Enum.map(row_texts, fn cell_texts ->
        %{
          "tableCells" =>
            Enum.map(cell_texts, fn
              nil ->
                %{"content" => []}

              text ->
                %{
                  "content" => [
                    %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => text}}]}}
                  ]
                }
            end)
        }
      end)

    %{
      "table" => %{
        "rows" => rows,
        "columns" => Keyword.fetch!(opts, :columns),
        "tableRows" => table_rows
      }
    }
  end

  # A single textRun element, optionally carrying a textStyle — real Docs API
  # shape. `run` is either a plain string (no textStyle key at all, matching
  # how Google omits it for fully-default runs) or `{text, style_map}`.
  defp text_run_elem({text, style}) when is_map(style),
    do: %{"textRun" => %{"content" => text, "textStyle" => style}}

  defp text_run_elem(text) when is_binary(text), do: %{"textRun" => %{"content" => text}}

  # A paragraph block built from a list of runs (plain strings and/or
  # `{text, style}` tuples, see text_run_elem/1) — for body (non-table) text
  # style tests, where `table_block/1`'s plain-string-only row_texts can't
  # express a styled run.
  defp styled_paragraph_block(runs) do
    %{"paragraph" => %{"elements" => Enum.map(runs, &text_run_elem/1)}}
  end

  # Same as `styled_paragraph_block/1`, additionally carrying an explicit
  # `paragraphStyle` and/or `bullet` — for paragraph-style/bullet capture
  # tests, where `styled_paragraph_block/1`'s bare paragraphs only exercise
  # the "everything unset" capture.
  defp paragraph_block(runs, opts) do
    paragraph = %{"elements" => Enum.map(runs, &text_run_elem/1)}

    paragraph =
      case Keyword.get(opts, :paragraph_style) do
        nil -> paragraph
        style -> Map.put(paragraph, "paragraphStyle", style)
      end

    paragraph =
      case Keyword.get(opts, :bullet) do
        nil -> paragraph
        bullet -> Map.put(paragraph, "bullet", bullet)
      end

    %{"paragraph" => paragraph}
  end

  # "updateParagraphStyle" / "updateTextStyle" / "insertText" … — requests
  # are single-key maps, atom-keyed for the two leading inserts and
  # string-keyed for the rest.
  defp request_kind(request), do: request |> Map.keys() |> List.first() |> to_string()

  # Every updateParagraphStyle in `requests` comes before every
  # updateTextStyle — see the "paragraph style is applied before character
  # style" describe block for why the order matters.
  defp assert_paragraph_style_before_text_style(requests) do
    kinds = Enum.map(requests, &request_kind/1)
    paragraph_at = for {"updateParagraphStyle", i} <- Enum.with_index(kinds), do: i
    text_at = for {"updateTextStyle", i} <- Enum.with_index(kinds), do: i

    assert paragraph_at != [] and text_at != [], "fixture must produce both kinds"
    assert Enum.max(paragraph_at) < Enum.min(text_at), inspect(kinds)
  end

  # Runs append_template/3 for a table-free `template` against a minimal
  # target (end index 10) and returns {range, first_batch_requests}.
  defp append_first_batch(template) do
    target = %{"body" => %{"content" => [%{"startIndex" => 1, "endIndex" => 10}]}}
    test_pid = self()

    get_fn = fn
      "template-id" -> {:ok, %{body: template}}
      "target-id" -> {:ok, %{body: target}}
    end

    batch_fn = fn "target-id", requests ->
      send(test_pid, {:batch, requests})
      {:ok, %{}}
    end

    assert {:ok, range} =
             GoogleDocsClient.append_template("target-id", "template-id",
               get_fn: get_fn,
               batch_fn: batch_fn
             )

    assert_received {:batch, requests}
    {range, requests}
  end

  # A Docs API dimension in points.
  defp points(magnitude), do: %{"magnitude" => magnitude, "unit" => "PT"}

  # Table block variant of `table_block/1` that accepts styled runs per cell
  # (a cell is a list of runs, see text_run_elem/1) and an optional
  # `tableStyle.tableColumnProperties` list — for cell-style and
  # column-width capture tests. `table_block/1` itself is left untouched
  # (many existing tests rely on its plain-string-only shape).
  defp styled_table_block(opts) do
    rows = Keyword.fetch!(opts, :rows)
    row_runs = Keyword.fetch!(opts, :row_runs)
    column_properties = Keyword.get(opts, :column_properties)

    table_rows =
      Enum.map(row_runs, fn cell_runs ->
        %{
          "tableCells" =>
            Enum.map(cell_runs, fn
              nil -> %{"content" => []}
              runs -> %{"content" => [styled_paragraph_block(runs)]}
            end)
        }
      end)

    table = %{
      "rows" => rows,
      "columns" => Keyword.fetch!(opts, :columns),
      "tableRows" => table_rows
    }

    table =
      if column_properties do
        Map.put(table, "tableStyle", %{"tableColumnProperties" => column_properties})
      else
        table
      end

    %{"table" => table}
  end

  # Builds a table StructuralElement matching the REAL Docs API response
  # shape, for simulating an already-inserted table in a target document
  # (as opposed to `table_block/1`, which builds a *template's* table for
  # `flatten_template_with_table_markers/1` and doesn't need a position).
  # `startIndex`/`endIndex` are fields of the block itself — siblings of
  # "table" — never nested inside it; see `collect_tables/1`'s comment in
  # the implementation. A single-row table with one bare (empty) cell per
  # entry in `cell_starts`.
  defp skeleton_table_block(start_index, end_index, cell_starts) do
    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "table" => %{
        "tableRows" => [
          %{"tableCells" => Enum.map(cell_starts, &%{"startIndex" => &1, "content" => []})}
        ]
      }
    }
  end

  # Same shape as `skeleton_table_block/3`, but cells carry real text —
  # simulating a table from an earlier section that has already been
  # through the Phase 2 cell fill (`build_table_fill_requests/3`).
  defp filled_table_block(start_index, end_index, cell_start_texts) do
    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "table" => %{
        "tableRows" => [
          %{
            "tableCells" =>
              Enum.map(cell_start_texts, fn {cell_start, text} ->
                %{
                  "startIndex" => cell_start,
                  "content" => [
                    %{
                      "paragraph" => %{
                        "elements" => [%{"textRun" => %{"content" => text <> "\n"}}]
                      }
                    }
                  ]
                }
              end)
          }
        ]
      }
    }
  end

  describe "flatten_template_with_table_markers/1" do
    test "paragraph-only document is unaffected: same join get_document_text/1 does, no markers" do
      doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hello "}}]}},
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "World\n"}}]}}
          ]
        }
      }

      assert {"Hello World\n", []} = GoogleDocsClient.flatten_template_with_table_markers(doc)
    end

    test "a table is replaced by a unique marker and its structure captured" do
      doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Header\n"}}]}},
            table_block(rows: 2, columns: 2, row_texts: [["A1\n", "B1\n"], ["A2\n", "B2\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Footer\n"}}]}}
          ]
        }
      }

      assert {text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)

      # Paragraph text before/after the table is untouched and in order.
      assert String.starts_with?(text, "Header\n")
      assert String.ends_with?(text, "Footer\n")
      # No table content leaked into the flattened text as plain text.
      refute text =~ "A1"
      refute text =~ "B1"

      assert table.marker_index == 1
      assert table.rows == 2
      assert table.columns == 2
      assert table.cell_texts == ["A1", "B1", "A2", "B2"]
    end

    test "multiple tables get distinct, ordered marker indices" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(rows: 1, columns: 1, row_texts: [["First\n"]]),
            table_block(rows: 1, columns: 1, row_texts: [["Second\n"]])
          ]
        }
      }

      assert {_text, [t1, t2]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert t1.marker_index == 1
      assert t1.cell_texts == ["First"]
      assert t2.marker_index == 2
      assert t2.cell_texts == ["Second"]
    end

    test "a multi-paragraph cell keeps internal newlines, drops only the final one" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(
              rows: 1,
              columns: 1,
              row_texts: [
                [
                  # Two paragraphs concatenated inside one cell, exactly how
                  # get_document_text/1 would join them at the top level.
                  "Nimi: {{ customer_name }}\nAadress: {{ customer_address }}\n"
                ]
              ]
            )
          ]
        }
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)

      assert table.cell_texts == [
               "Nimi: {{ customer_name }}\nAadress: {{ customer_address }}"
             ]
    end

    test "an empty cell captures as an empty string" do
      doc = %{
        "body" => %{"content" => [table_block(rows: 1, columns: 2, row_texts: [["Text\n", nil]])]}
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert table.cell_texts == ["Text", ""]
    end

    test "table dimensions fall back to tableRows shape when rows/columns are missing" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "tableRows" => [
                  %{"tableCells" => [%{"content" => []}, %{"content" => []}]}
                ]
              }
            }
          ]
        }
      }

      assert {_text, [table]} = GoogleDocsClient.flatten_template_with_table_markers(doc)
      assert table.rows == 1
      assert table.columns == 2
    end
  end

  describe "flatten_template_with_table_markers_and_styles/1" do
    test "flatten_template_with_table_markers/1 stays a 2-tuple, unaffected by style capture" do
      doc = %{
        "body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]}
      }

      assert {text, tables} = GoogleDocsClient.flatten_template_with_table_markers(doc)

      assert {^text, ^tables, [], []} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)
    end

    test "captures column_properties from tableStyle.tableColumnProperties, FIXED_WIDTH only carries a width" do
      doc = %{
        "body" => %{
          "content" => [
            styled_table_block(
              rows: 1,
              columns: 3,
              row_runs: [[["A"], ["B"], ["C"]]],
              column_properties: [
                %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => 120, "unit" => "PT"}},
                %{"widthType" => "EVENLY_DISTRIBUTED"},
                %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => 80.5, "unit" => "PT"}}
              ]
            )
          ]
        }
      }

      assert {_text, [table], _body_runs, _body_paragraphs} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert table.column_properties == [
               %{width_type: "FIXED_WIDTH", magnitude: 120.0, unit: "PT"},
               %{width_type: "EVENLY_DISTRIBUTED", magnitude: nil, unit: nil},
               %{width_type: "FIXED_WIDTH", magnitude: 80.5, unit: "PT"}
             ]
    end

    test "column_properties is [] when the source table has no tableStyle" do
      doc = %{"body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]}}

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert table.column_properties == []
    end

    # Regression: merged cells make a source row narrower than the declared
    # column count, but insertTable always creates a rectangular table and
    # the fill phase zips captured cells against it positionally — a short
    # row used to shift every later cell's content left by one, silently
    # (row 1's text spilling into the merged header row).
    test "a row shorter than the declared column count is padded so cells stay row-aligned" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(
              rows: 2,
              columns: 3,
              row_texts: [["H\n", "H2\n"], ["a\n", "b\n", "c\n"]]
            )
          ]
        }
      }

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      # Row-major, exactly rows × columns entries; the merged-header row's
      # missing third cell pads as "" (no fill request), row 1 stays in row 1.
      assert table.cell_texts == ["H", "H2", "", "a", "b", "c"]
      assert length(table.cell_runs) == 6
      assert Enum.at(table.cell_runs, 2) == []
      assert length(table.cell_paragraphs) == 6
      assert Enum.at(table.cell_paragraphs, 2) == []
    end

    test "body run offsets count UTF-16 units — diacritics don't shift the following run" do
      doc = %{
        "body" => %{
          "content" => [
            styled_paragraph_block(["õäü ok\n"]),
            styled_paragraph_block([{"Bold\n", %{"bold" => true}}])
          ]
        }
      }

      assert {_text, [], body_runs, _body_paragraphs} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      # "õäü ok\n" is 7 UTF-16 units (each diacritic is one unit) but 10
      # bytes — byte-based offsets would misplace the bold run's style range
      # by three units.
      assert [%{start_offset: 0, length: 7}, %{start_offset: 7, length: 5, bold: true}] =
               body_runs
    end

    test "a row wider than the declared column count is trimmed to it" do
      doc = %{
        "body" => %{
          "content" => [
            table_block(rows: 1, columns: 2, row_texts: [["a\n", "b\n", "c\n"]])
          ]
        }
      }

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert table.cell_texts == ["a", "b"]
      assert length(table.cell_runs) == 2
      assert length(table.cell_paragraphs) == 2
    end

    test "cell_runs captures per-run style and strips only the cell's trailing newline" do
      doc = %{
        "body" => %{
          "content" => [
            styled_table_block(
              rows: 1,
              columns: 1,
              row_runs: [[[{"Bold", %{"bold" => true}}, {" plain\n", %{}}]]]
            )
          ]
        }
      }

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert [[run1, run2]] = table.cell_runs

      assert run1.text == "Bold"
      assert run1.bold == true
      assert run1.start_offset == 0
      assert run1.length == 4

      assert run2.text == " plain"
      assert run2.bold == false
      assert run2.start_offset == 4
      assert run2.length == 6

      # Same underlying data as cell_texts, decomposed into styled runs —
      # concatenating the runs' text must reproduce it exactly.
      assert Enum.map_join([run1, run2], & &1.text) == hd(table.cell_texts)
      assert table.cell_texts == ["Bold plain"]
    end

    test "an empty cell captures as an empty cell_runs list" do
      doc = %{
        "body" => %{"content" => [table_block(rows: 1, columns: 2, row_texts: [["Text\n", nil]])]}
      }

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert [[text_run], []] = table.cell_runs
      assert text_run.text == "Text"
      assert text_run.bold == false
      assert text_run.length == 4
    end

    test "cell_runs threads offsets across multiple paragraph blocks in one cell, keeping internal newlines" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "rows" => 1,
                "columns" => 1,
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [%{"textRun" => %{"content" => "Line1\n"}}]
                            }
                          },
                          %{
                            "paragraph" => %{
                              "elements" => [%{"textRun" => %{"content" => "Line2\n"}}]
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

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert [[run1, run2]] = table.cell_runs
      # Internal newline kept (not the last run) — only the trailing one is dropped.
      assert run1.text == "Line1\n"
      assert run1.start_offset == 0
      assert run1.length == 6

      assert run2.text == "Line2"
      assert run2.start_offset == 6
      assert run2.length == 5
    end

    test "body_runs captures per-run style for non-table paragraphs, offsets skip the table marker" do
      doc = %{
        "body" => %{
          "content" => [
            styled_paragraph_block([{"Heading\n", %{"bold" => true}}]),
            table_block(rows: 1, columns: 1, row_texts: [["x\n"]]),
            styled_paragraph_block(["Body text.\n"])
          ]
        }
      }

      assert {text, [_table], body_runs, _body_paragraphs} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      marker = " __PKDC_TABLE_1__ "
      assert text =~ marker

      assert [heading_run, body_run] = body_runs

      assert heading_run.text == "Heading\n"
      assert heading_run.bold == true
      assert heading_run.start_offset == 0
      assert heading_run.length == String.length("Heading\n")

      assert body_run.text == "Body text.\n"
      assert body_run.bold == false
      assert body_run.start_offset == String.length("Heading\n") + String.length(marker)
      assert body_run.length == String.length("Body text.\n")
    end

    test "paragraph-only document with no styling captures a single plain body run" do
      doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hello "}}]}},
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "World\n"}}]}}
          ]
        }
      }

      assert {"Hello World\n", [], body_runs, body_paragraphs} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert [run1, run2] = body_runs
      assert run1.text == "Hello "
      assert run1.bold == false
      assert run2.text == "World\n"
      assert run2.start_offset == String.length("Hello ")

      # One captured span per structural paragraph block (2 here), regardless
      # of whether the block's own text happens to end in "\n" — this
      # fixture's first block ("Hello ") doesn't, unlike real Docs paragraph
      # content, but flatten_block_with_styles/3 still treats each "paragraph"
      # block as its own paragraph.
      assert [para1, para2] = body_paragraphs
      assert para1.start_offset == 0
      assert para1.length == String.length("Hello ")
      assert para1.style.alignment == nil
      assert para1.style.line_spacing == nil
      assert para1.style.named_style_type == "NORMAL_TEXT"
      assert para1.bullet == nil

      assert para2.start_offset == String.length("Hello ")
      assert para2.length == String.length("World\n")
    end
  end

  describe "find_table_marker_ranges/1" do
    test "locates a single marker and reports its captured index" do
      {marker_text, [%{marker_index: 1}]} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]}
        })

      full_text = "Before " <> marker_text <> " After"
      doc = doc_with_text(full_text, 1)

      assert [range] = GoogleDocsClient.find_table_marker_ranges(doc)
      assert range.marker_index == 1

      # Round-trip: slicing the original text at the reported range yields
      # back exactly the marker substring (proves the byte->UTF-16 index
      # arithmetic is self-consistent, ASCII-only so byte == UTF-16 unit).
      sliced =
        String.slice(full_text, range.start_index - 1, range.end_index - range.start_index)

      assert sliced == marker_text
    end

    test "locates multiple markers in document order" do
      {_t1, [%{marker_index: 1}]} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => [table_block(rows: 1, columns: 1, row_texts: [["a\n"]])]}
        })

      marker1 = " __PKDC_TABLE_1__ "
      marker2 = " __PKDC_TABLE_2__ "
      doc = doc_with_text("X" <> marker1 <> "Y" <> marker2 <> "Z", 1)

      ranges = GoogleDocsClient.find_table_marker_ranges(doc)
      assert Enum.map(ranges, & &1.marker_index) == [1, 2]
      assert Enum.at(ranges, 0).start_index < Enum.at(ranges, 1).start_index
    end

    test "returns [] when no markers are present" do
      doc = doc_with_text("nothing special here", 1)
      assert GoogleDocsClient.find_table_marker_ranges(doc) == []
    end

    # Google Docs indices count UTF-16 code units. The real templates are
    # Estonian — õ/ä/ü are 2 UTF-8 bytes but 1 UTF-16 unit, so byte-based
    # arithmetic would overshoot; these fixtures are the ones that separate
    # utf16_units/1 from byte_size/1 (and, with the emoji below, from
    # String.length/1 too).
    test "preceding BMP diacritics count as one UTF-16 unit each, not their byte width" do
      marker = " __PKDC_TABLE_1__ "
      prefix = "Tähelepanu õäü\n"
      doc = doc_with_text(prefix <> marker, 11)

      assert [range] = GoogleDocsClient.find_table_marker_ranges(doc)

      # 15 codepoints, all BMP → 15 UTF-16 units (byte_size is 19 — ä/õ/ü
      # are 2 bytes each — so byte math would report 30).
      assert range.start_index == 11 + 15
      assert range.end_index == 11 + 15 + String.length(marker)
    end

    test "a preceding emoji counts as two UTF-16 units (surrogate pair), not one grapheme" do
      marker = " __PKDC_TABLE_1__ "
      prefix = "😀 heading\n"
      doc = doc_with_text(prefix <> marker, 11)

      assert [range] = GoogleDocsClient.find_table_marker_ranges(doc)

      # "😀 heading\n" is 10 graphemes (String.length) but 11 UTF-16 units —
      # the emoji is a surrogate pair. Grapheme-based math would land one
      # unit short.
      assert range.start_index == 11 + 11
    end
  end

  describe "table_skeleton_requests/2" do
    test "builds delete + insertTable pairs, descending by start_index" do
      marker_ranges = [
        %{marker_index: 1, start_index: 10, end_index: 28},
        %{marker_index: 2, start_index: 50, end_index: 68}
      ]

      tables_by_index = %{
        1 => %{rows: 2, columns: 2},
        2 => %{rows: 1, columns: 3}
      }

      reqs = GoogleDocsClient.table_skeleton_requests(marker_ranges, tables_by_index)

      assert [
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 50, "endIndex" => 68}}},
               %{"insertTable" => %{"rows" => 1, "columns" => 3, "location" => %{"index" => 50}}},
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 10, "endIndex" => 28}}},
               %{"insertTable" => %{"rows" => 2, "columns" => 2, "location" => %{"index" => 10}}}
             ] = reqs
    end

    test "column_properties present in table_info are NOT applied here even when present" do
      # Column widths are applied in Phase 2 (build_table_fill_requests/3),
      # not this Phase 1b skeleton batch — verified live against the real
      # Docs API that insertTable's own `location` index cannot be trusted
      # as the resulting table's real startIndex (Google inserts an
      # implicit paragraph break ahead of a table landing mid-paragraph),
      # so updateTableColumnProperties needs the confirmed post-insert
      # position from a re-fetch, which this function doesn't have. See
      # table_column_width_requests/2's doc.
      marker_ranges = [%{marker_index: 1, start_index: 10, end_index: 28}]

      tables_by_index = %{
        1 => %{
          rows: 1,
          columns: 2,
          column_properties: [%{width_type: "FIXED_WIDTH", magnitude: 200.0, unit: "PT"}]
        }
      }

      reqs = GoogleDocsClient.table_skeleton_requests(marker_ranges, tables_by_index)

      assert [
               %{"deleteContentRange" => %{"range" => %{"startIndex" => 10, "endIndex" => 28}}},
               %{"insertTable" => %{"rows" => 1, "columns" => 2, "location" => %{"index" => 10}}}
             ] = reqs
    end
  end

  describe "table_column_width_requests/2" do
    test "emits one request per FIXED_WIDTH column, columnIndices aligned to source column position" do
      column_properties = [
        %{width_type: "FIXED_WIDTH", magnitude: 120.0, unit: "PT"},
        %{width_type: "EVENLY_DISTRIBUTED", magnitude: nil, unit: nil},
        %{width_type: "FIXED_WIDTH", magnitude: 80.5, unit: "PT"}
      ]

      assert GoogleDocsClient.table_column_width_requests(50, column_properties) == [
               %{
                 "updateTableColumnProperties" => %{
                   "tableStartLocation" => %{"index" => 50},
                   "columnIndices" => [0],
                   "tableColumnProperties" => %{
                     "widthType" => "FIXED_WIDTH",
                     "width" => %{"magnitude" => 120.0, "unit" => "PT"}
                   },
                   "fields" => "width,widthType"
                 }
               },
               %{
                 "updateTableColumnProperties" => %{
                   "tableStartLocation" => %{"index" => 50},
                   "columnIndices" => [2],
                   "tableColumnProperties" => %{
                     "widthType" => "FIXED_WIDTH",
                     "width" => %{"magnitude" => 80.5, "unit" => "PT"}
                   },
                   "fields" => "width,widthType"
                 }
               }
             ]
    end

    test "empty column_properties produces no requests" do
      assert GoogleDocsClient.table_column_width_requests(50, []) == []
    end

    test "a column with no captured width_type produces no request" do
      assert GoogleDocsClient.table_column_width_requests(50, [
               %{width_type: nil, magnitude: nil, unit: nil}
             ]) == []
    end
  end

  describe "text_style_requests/2" do
    test "builds one updateTextStyle request per run, range anchored at base_index" do
      runs = [
        %{start_offset: 0, length: 5, bold: true, italic: false, font_size: nil, color: nil}
      ]

      assert GoogleDocsClient.text_style_requests(100, runs) == [
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 100, "endIndex" => 105},
                   "textStyle" => %{"bold" => true, "italic" => false},
                   "fields" => "bold,italic"
                 }
               }
             ]
    end

    test "merges adjacent runs sharing identical style into one range" do
      runs = [
        %{start_offset: 0, length: 3, bold: false, italic: false, font_size: nil, color: nil},
        %{start_offset: 3, length: 4, bold: false, italic: false, font_size: nil, color: nil}
      ]

      assert GoogleDocsClient.text_style_requests(10, runs) == [
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 10, "endIndex" => 17},
                   "textStyle" => %{"bold" => false, "italic" => false},
                   "fields" => "bold,italic"
                 }
               }
             ]
    end

    test "does not merge adjacent runs with different style — each gets its own explicit range" do
      runs = [
        %{start_offset: 0, length: 3, bold: true, italic: false, font_size: nil, color: nil},
        %{start_offset: 3, length: 4, bold: false, italic: false, font_size: nil, color: nil}
      ]

      assert GoogleDocsClient.text_style_requests(10, runs) == [
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 10, "endIndex" => 13},
                   "textStyle" => %{"bold" => true, "italic" => false},
                   "fields" => "bold,italic"
                 }
               },
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 13, "endIndex" => 17},
                   "textStyle" => %{"bold" => false, "italic" => false},
                   "fields" => "bold,italic"
                 }
               }
             ]
    end

    test "does not merge non-contiguous runs even when their style matches" do
      runs = [
        %{start_offset: 0, length: 3, bold: false, italic: false, font_size: nil, color: nil},
        %{start_offset: 10, length: 4, bold: false, italic: false, font_size: nil, color: nil}
      ]

      assert length(GoogleDocsClient.text_style_requests(0, runs)) == 2
    end

    test "includes fontSize and foregroundColor in both textStyle and the fields mask when present" do
      runs = [
        %{
          start_offset: 0,
          length: 4,
          bold: true,
          italic: true,
          font_size: 14,
          color: %{"red" => 1.0}
        }
      ]

      assert [%{"updateTextStyle" => req}] = GoogleDocsClient.text_style_requests(0, runs)
      assert req["range"] == %{"startIndex" => 0, "endIndex" => 4}

      assert req["textStyle"] == %{
               "bold" => true,
               "italic" => true,
               "fontSize" => %{"magnitude" => 14.0, "unit" => "PT"},
               "foregroundColor" => %{"color" => %{"rgbColor" => %{"red" => 1.0}}}
             }

      assert req["fields"] == "bold,italic,fontSize,foregroundColor"
    end

    test "an all-zero (black) foregroundColor is still replayed, not treated as absent" do
      runs = [
        %{start_offset: 0, length: 2, bold: false, italic: false, font_size: nil, color: %{}}
      ]

      assert [%{"updateTextStyle" => req}] = GoogleDocsClient.text_style_requests(0, runs)
      assert req["textStyle"]["foregroundColor"] == %{"color" => %{"rgbColor" => %{}}}
      assert req["fields"] == "bold,italic,foregroundColor"
    end

    test "filters out zero-length runs" do
      runs = [
        %{start_offset: 0, length: 0, bold: false, italic: false, font_size: nil, color: nil}
      ]

      assert GoogleDocsClient.text_style_requests(0, runs) == []
    end

    test "empty runs list produces no requests" do
      assert GoogleDocsClient.text_style_requests(0, []) == []
    end
  end

  describe "append_template/3 — no tables (regression: unchanged behaviour)" do
    test "single insertText, no extra Docs API calls, same index math as before" do
      template_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Plain body.\n"}}]}}
          ]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, 23}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      # insert_index=9, content_start=11 (the section break occupies one unit
      # and inserts a newline ahead of itself — see append_template/3's doc
      # for why that fresh paragraph is needed). content_end = 11 +
      # utf16_units("Plain body.\n") = 11+12=23.
      #
      # The plain paragraph has no textStyle/paragraphStyle at all, so it
      # captures as a single bold:false/italic:false run and an
      # all-unset paragraph style (sent first — it resets text style), both
      # spanning the whole insert — the anti-inheritance guarantee
      # (text_style_requests/2, paragraph_style_requests/2) applies even when
      # nothing in the source was actually styled. No createParagraphBullets request — not a list
      # item.
      paragraph_style = unset_paragraph_style_request(11, 23)

      assert_receive {:batch,
                      [
                        %{insertSectionBreak: %{location: %{index: 9}, sectionType: "NEXT_PAGE"}},
                        %{insertText: %{location: %{index: 11}, text: "Plain body.\n"}},
                        ^paragraph_style,
                        %{
                          "updateTextStyle" => %{
                            "range" => %{"startIndex" => 11, "endIndex" => 23},
                            "textStyle" => %{"bold" => false, "italic" => false},
                            "fields" => "bold,italic"
                          }
                        },
                        %{
                          "deleteParagraphBullets" => %{
                            "range" => %{"startIndex" => 11, "endIndex" => 23}
                          }
                        }
                      ]}

      refute_receive {:batch, _}
      # Only the one target-doc fetch used to compute insert_index — no
      # re-fetches for a template with zero tables.
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — with tables (three-phase pipeline)" do
    test "rebuilds the table, fills its cells, and computes content_end from the final doc" do
      template_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hi\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["X\n", "Y\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Bye\n"}}]}}
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      initial_target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      # State after Phase 0's insertText: the marker text now lives at
      # content_start (11 — insert_index 9 + the section break and the
      # newline it inserts ahead of itself, see append_template/3's doc).
      # Real Google Docs would split this across several paragraph
      # structural elements (one per embedded \n) — collapsed to a single
      # textRun here since find_table_marker_ranges/1 only cares about
      # locating the marker substring and its startIndex.
      doc1 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 11, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      # Reuse the real function under test to locate the marker instead of
      # hand-deriving its index — keeps this fixture honest regardless of the
      # marker's exact literal format/length.
      [%{marker_index: 1, start_index: marker_start}] =
        GoogleDocsClient.find_table_marker_ranges(doc1)

      # State after Phase 1's skeleton batch: the marker is gone, replaced by
      # a bare 1x2 table. Cell startIndexes are arbitrary but distinct so
      # last-first fill ordering is observable. `startIndex`/`endIndex` are
      # fields of the block itself (sibling of "table"), matching the real
      # Docs API shape — the "table" object itself has no startIndex of its
      # own (see collect_tables/1's comment).
      doc2 = %{
        "body" => %{
          "content" => [
            %{
              "startIndex" => marker_start,
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{"startIndex" => 100, "content" => []},
                      %{"startIndex" => 103, "content" => []}
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      # State after Phase 2's cell-fill batch: an arbitrary final document
      # length, used only to prove content_end comes from re-fetching the
      # real document rather than the marked-up text's length.
      final_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 500}]}}
          ]
        }
      }

      target_docs = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(target_docs, 1)
          :counters.add(target_docs, 1, 1)

          case call do
            0 -> {:ok, %{body: initial_target_doc}}
            1 -> {:ok, %{body: doc1}}
            2 -> {:ok, %{body: doc2}}
            3 -> {:ok, %{body: final_doc}}
          end
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, 499}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      # Phase 0: section break + the marked-up text (marker included), plus
      # a paragraph-style request per body paragraph either side of the
      # marker ("Hi\n" at 11-14, "Bye\n" at 32-36 — the marker itself gets
      # no style request since it's deleted before Phase 1 finishes), then a
      # char-style request per plain-text run, same ranges — each captured
      # span happens to be a single run here, so char and paragraph ranges
      # coincide.
      hi_paragraph_style = unset_paragraph_style_request(11, 14)
      bye_paragraph_style = unset_paragraph_style_request(32, 36)

      assert_receive {:batch,
                      [
                        %{insertSectionBreak: %{location: %{index: 9}, sectionType: "NEXT_PAGE"}},
                        %{insertText: %{location: %{index: 11}, text: ^text}},
                        ^hi_paragraph_style,
                        ^bye_paragraph_style,
                        %{
                          "updateTextStyle" => %{
                            "range" => %{"startIndex" => 11, "endIndex" => 14},
                            "textStyle" => %{"bold" => false, "italic" => false},
                            "fields" => "bold,italic"
                          }
                        },
                        %{
                          "updateTextStyle" => %{
                            "range" => %{"startIndex" => 32, "endIndex" => 36},
                            "textStyle" => %{"bold" => false, "italic" => false},
                            "fields" => "bold,italic"
                          }
                        },
                        %{
                          "deleteParagraphBullets" => %{
                            "range" => %{"startIndex" => 11, "endIndex" => delete_bullets_end}
                          }
                        }
                      ]}

      # The inherited-bullet sweep covers the whole inserted body — marker
      # text included (ASCII, so String.length == UTF-16 units here).
      assert delete_bullets_end == 11 + String.length(text)

      # Phase 1: skeleton — delete the marker, insert a bare 1x2 table at its
      # position. Neither template table declares tableStyle.tableColumnProperties
      # (table_block/1's fixture doesn't set one), so no updateTableColumnProperties
      # requests are appended — covered separately in the column-widths tests.
      assert_receive {:batch,
                      [
                        %{"deleteContentRange" => %{"range" => %{"startIndex" => ^marker_start}}},
                        %{
                          "insertTable" => %{
                            "rows" => 1,
                            "columns" => 2,
                            "location" => %{"index" => ^marker_start}
                          }
                        }
                      ]}

      # Phase 2: cell fill — captured cell text ("X", "Y"), last-first, each
      # insertText immediately followed by its own paragraph-style request
      # and then its own bold:false/italic:false char-style request (both
      # cells are plain textRuns, same anti-inheritance guarantee as the body
      # text above). The paragraph range uses the cell's
      # *natural* (un-stripped) length ("Y\n"/"X\n", 2 UTF-16 units) rather
      # than the 1-unit stripped text/char-style range — see
      # `cell_paragraph_spans/2`'s doc: the extra unit lands on the
      # pre-existing bare cell's own trailing newline, which the char-style
      # range correctly excludes (nothing to bold/italicize there) but the
      # paragraph range correctly includes (the paragraph boundary is real).
      y_paragraph_style = unset_paragraph_style_request(104, 106)
      x_paragraph_style = unset_paragraph_style_request(101, 103)

      assert_receive {:batch,
                      [
                        %{"insertText" => %{"location" => %{"index" => 104}, "text" => "Y"}},
                        ^y_paragraph_style,
                        %{
                          "updateTextStyle" => %{
                            "range" => %{"startIndex" => 104, "endIndex" => 105},
                            "textStyle" => %{"bold" => false, "italic" => false},
                            "fields" => "bold,italic"
                          }
                        },
                        %{"insertText" => %{"location" => %{"index" => 101}, "text" => "X"}},
                        ^x_paragraph_style,
                        %{
                          "updateTextStyle" => %{
                            "range" => %{"startIndex" => 101, "endIndex" => 102},
                            "textStyle" => %{"bold" => false, "italic" => false},
                            "fields" => "bold,italic"
                          }
                        }
                      ]}

      refute_receive {:batch, _}
      assert :counters.get(target_docs, 1) == 4
    end

    test "an empty styled cell gets its paragraph style replayed with no insertText" do
      template_doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "rows" => 1,
                "columns" => 1,
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [%{"textRun" => %{"content" => "\n"}}],
                              "paragraphStyle" => %{"alignment" => "CENTER"}
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

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      initial_target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      doc1 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 11, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      [%{marker_index: 1, start_index: marker_start}] =
        GoogleDocsClient.find_table_marker_ranges(doc1)

      doc2 = %{
        "body" => %{
          "content" => [
            %{
              "startIndex" => marker_start,
              "table" => %{
                "tableRows" => [
                  %{"tableCells" => [%{"startIndex" => 100, "content" => []}]}
                ]
              }
            }
          ]
        }
      }

      final_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 200}]}}
          ]
        }
      }

      target_docs = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(target_docs, 1)
          :counters.add(target_docs, 1, 1)

          case call do
            0 -> {:ok, %{body: initial_target_doc}}
            1 -> {:ok, %{body: doc1}}
            2 -> {:ok, %{body: doc2}}
            3 -> {:ok, %{body: final_doc}}
          end
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, _phase0}
      assert_receive {:batch, _phase1_skeleton}

      # Phase 2: the cell inserts nothing (text is empty) but its captured
      # CENTER alignment still replays against the new cell's pre-existing
      # bare paragraph — a blank spacer/signature cell must not silently
      # revert to START.
      assert_receive {:batch, phase2}

      refute Enum.any?(phase2, &Map.has_key?(&1, "insertText"))

      assert [
               %{
                 "updateParagraphStyle" => %{
                   "range" => %{"startIndex" => 101, "endIndex" => 102},
                   "paragraphStyle" => %{"alignment" => "CENTER"}
                 }
               }
             ] = phase2

      refute_receive {:batch, _}
    end

    test "returns {:error, :table_marker_count_mismatch} when a marker goes missing" do
      template_doc = %{
        "body" => %{
          "content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      # doc1 (post Phase-0 re-fetch) has NO marker text at all — simulates a
      # marker that failed to round-trip through the Docs API.
      doc1_without_marker = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)
          if call == 0, do: {:ok, %{body: target_doc}}, else: {:ok, %{body: doc1_without_marker}}
      end

      batch_fn = fn _id, _requests -> {:ok, %{}} end

      assert {:error, :table_marker_count_mismatch} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end

    test "returns {:error, :table_match_mismatch} when Phase 1's table can't be relocated" do
      template_doc = %{
        "body" => %{
          "content" => [table_block(rows: 1, columns: 1, row_texts: [["x\n"]])]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      doc1 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      # doc2 (post Phase-1 re-fetch) has NO tables at all — simulates the
      # skeleton insertTable silently failing to materialize.
      doc2_without_table = %{"body" => %{"content" => []}}

      calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc}}
            1 -> {:ok, %{body: doc1}}
            _ -> {:ok, %{body: doc2_without_table}}
          end
      end

      batch_fn = fn _id, _requests -> {:ok, %{}} end

      assert {:error, :table_match_mismatch} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end
  end

  describe "append_template/3 — regression: pre-existing table position must come from the block, not nested under \"table\"" do
    # Root cause this suite guards against: `finish_append_template/6` used
    # to read a pre-existing table's document position as
    # `el["table"]["startIndex"]`. The real Docs API has no such nested
    # field (see `collect_tables/1`'s comment) — that lookup always
    # returned `nil`. `match_new_tables/3` sorts `{start_index, tag}` pairs
    # to reconstruct document order; mixing real integers (this section's
    # new markers) with `nil` (every pre-existing table) doesn't sort by
    # position at all — Erlang term ordering puts every number before every
    # atom, so *every* pre-existing table sorted after *every* new one,
    # regardless of where either actually sat in the document. A second
    # table-bearing section would then have its cell text written into the
    # first section's already-filled tables instead of its own, exactly the
    # "content from many different tables mashed into one" corruption seen
    # in production composed documents.
    #
    # These mocks intentionally use the correct (real) shape everywhere —
    # that's what makes them exercise the bug: fixtures that mirrored the
    # bug (startIndex nested under "table", as the pre-fix version of the
    # happy-path test above did) can't fail on pre-fix code.
    test "a second table-bearing section fills its own new tables, not the first section's already-filled ones" do
      # --- Section 1: template A, two tables, appended into a near-empty doc ---
      template_a = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A1a\n", "A1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Mid\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A2a\n", "A2b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Tail\n"}}]}}
          ]
        }
      }

      {text_a, [_ta1, _ta2]} = GoogleDocsClient.flatten_template_with_table_markers(template_a)

      target_doc_0 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      doc1_1 = %{
        "body" => %{
          "content" =>
            target_doc_0["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 11, "textRun" => %{"content" => text_a}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: ma1}, %{marker_index: 2, start_index: ma2}] =
        GoogleDocsClient.find_table_marker_ranges(doc1_1)

      doc2_1 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            skeleton_table_block(ma1, ma1 + 30, [ma1 + 10, ma1 + 13]),
            skeleton_table_block(ma2, ma2 + 30, [ma2 + 10, ma2 + 13])
          ]
        }
      }

      final_doc_1 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 500}]}}
          ]
        }
      }

      calls_1 = :counters.new(1, [])

      get_fn_1 = fn
        "template-a" ->
          {:ok, %{body: template_a}}

        "target-id" ->
          call = :counters.get(calls_1, 1)
          :counters.add(calls_1, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc_0}}
            1 -> {:ok, %{body: doc1_1}}
            2 -> {:ok, %{body: doc2_1}}
            3 -> {:ok, %{body: final_doc_1}}
          end
      end

      batch_fn_1 = fn "target-id", requests ->
        send(self(), {:call1_batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, 499}} =
               GoogleDocsClient.append_template("target-id", "template-a",
                 get_fn: get_fn_1,
                 batch_fn: batch_fn_1
               )

      # Drain section 1's three batches (section break + text, skeleton, fill) —
      # section 2 is what's under test.
      assert_receive {:call1_batch, _}
      assert_receive {:call1_batch, _}
      assert_receive {:call1_batch, _}
      refute_receive {:call1_batch, _}

      # --- Section 2: template B, two tables, appended into a doc that
      # already has section 1's two REAL, filled tables at ma1/ma2. ---
      template_b = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B1a\n", "B1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Mid\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B2a\n", "B2b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Tail\n"}}]}}
          ]
        }
      }

      {text_b, [_tb1, _tb2]} = GoogleDocsClient.flatten_template_with_table_markers(template_b)

      current_doc_2 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            filled_table_block(ma1, ma1 + 30, [{ma1 + 10, "A1a"}, {ma1 + 13, "A1b"}]),
            filled_table_block(ma2, ma2 + 30, [{ma2 + 10, "A2a"}, {ma2 + 13, "A2b"}]),
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => ma2 + 30,
                    "endIndex" => ma2 + 31,
                    "textRun" => %{"content" => "\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      content_start_2 = ma2 + 32

      doc1_2 = %{
        "body" => %{
          "content" =>
            current_doc_2["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{"startIndex" => content_start_2, "textRun" => %{"content" => text_b}}
                    ]
                  }
                }
              ]
        }
      }

      marker_ranges_2 = GoogleDocsClient.find_table_marker_ranges(doc1_2)

      # Section 2's own markers are found — and ONLY section 2's markers.
      # Section 1's tables are already real content by this point (no
      # marker tokens left behind), so there is no cross-section marker
      # collision even though both templates' markers start numbering at 1.
      assert [%{marker_index: 1, start_index: mb1}, %{marker_index: 2, start_index: mb2}] =
               marker_ranges_2

      doc2_2 = %{
        "body" => %{
          "content" => [
            hd(current_doc_2["body"]["content"]),
            filled_table_block(ma1, ma1 + 30, [{ma1 + 10, "A1a"}, {ma1 + 13, "A1b"}]),
            filled_table_block(ma2, ma2 + 30, [{ma2 + 10, "A2a"}, {ma2 + 13, "A2b"}]),
            skeleton_table_block(mb1, mb1 + 30, [mb1 + 10, mb1 + 13]),
            skeleton_table_block(mb2, mb2 + 30, [mb2 + 10, mb2 + 13])
          ]
        }
      }

      final_doc_2 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 800}]}}
          ]
        }
      }

      calls_2 = :counters.new(1, [])

      get_fn_2 = fn
        "template-b" ->
          {:ok, %{body: template_b}}

        "target-id" ->
          call = :counters.get(calls_2, 1)
          :counters.add(calls_2, 1, 1)

          case call do
            0 -> {:ok, %{body: current_doc_2}}
            1 -> {:ok, %{body: doc1_2}}
            2 -> {:ok, %{body: doc2_2}}
            3 -> {:ok, %{body: final_doc_2}}
          end
      end

      batch_fn_2 = fn "target-id", requests ->
        send(self(), {:call2_batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {^content_start_2, 799}} =
               GoogleDocsClient.append_template("target-id", "template-b",
                 get_fn: get_fn_2,
                 batch_fn: batch_fn_2
               )

      # Phase 0 (section break + marker text) and Phase 1 (skeleton) batches —
      # not under test here.
      assert_receive {:call2_batch, _}
      assert_receive {:call2_batch, _}

      # Phase 2: the regression itself. Section 2's cell text must land in
      # section 2's own (newly-created) tables — mb1/mb2 — never in section
      # 1's already-filled tables at ma1/ma2.
      assert_receive {:call2_batch, fill_requests}
      refute_receive {:call2_batch, _}

      # Each insertText is followed by its own paragraph-style and
      # bold:false/italic:false updateTextStyle requests (anti-inheritance
      # guarantee — see text_style_requests/2), so fill_requests is no
      # longer insertText-only. Filter to insertText before extracting
      # targets; the regression under test (correct table, not cross-section
      # corruption) is about insertText's location, unaffected by styling.
      insert_requests = Enum.filter(fill_requests, &Map.has_key?(&1, "insertText"))

      fill_targets =
        Enum.map(insert_requests, fn %{
                                       "insertText" => %{
                                         "location" => %{"index" => idx},
                                         "text" => text
                                       }
                                     } ->
          {idx, text}
        end)

      # Exact DESCENDING order across tables, not just the right set: an
      # ascending fill would let an earlier insert shift a later table's
      # captured cell indices.
      assert fill_targets == [
               {mb2 + 14, "B2b"},
               {mb2 + 11, "B2a"},
               {mb1 + 14, "B1b"},
               {mb1 + 11, "B1a"}
             ]

      refute Enum.any?(fill_targets, fn {idx, _} ->
               idx in [ma1 + 11, ma1 + 14, ma2 + 11, ma2 + 14]
             end)

      # Style requests ride along with the same guarantee: every one targets
      # section 2's own new cells, never section 1's already-filled ones.
      style_requests = Enum.filter(fill_requests, &Map.has_key?(&1, "updateTextStyle"))
      assert length(style_requests) == length(insert_requests)

      refute Enum.any?(style_requests, fn %{
                                            "updateTextStyle" => %{
                                              "range" => %{"startIndex" => idx}
                                            }
                                          } ->
               idx in [ma1 + 11, ma1 + 14, ma2 + 11, ma2 + 14]
             end)
    end

    test "an interleaved zero-table (image-only) section doesn't perturb a later section's pre-existing-table bookkeeping" do
      # Section 1: one table.
      template_a = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["A1a\n", "A1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "A-Tail\n"}}]}}
          ]
        }
      }

      {text_a, [_ta]} = GoogleDocsClient.flatten_template_with_table_markers(template_a)

      target_doc_0 = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      doc1_1 = %{
        "body" => %{
          "content" =>
            target_doc_0["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 11, "textRun" => %{"content" => text_a}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: ma}] = GoogleDocsClient.find_table_marker_ranges(doc1_1)

      doc2_1 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            skeleton_table_block(ma, ma + 30, [ma + 10, ma + 13])
          ]
        }
      }

      final_doc_1 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 300}]}}
          ]
        }
      }

      calls_1 = :counters.new(1, [])

      get_fn_1 = fn
        "template-a" ->
          {:ok, %{body: template_a}}

        "target-id" ->
          call = :counters.get(calls_1, 1)
          :counters.add(calls_1, 1, 1)

          case call do
            0 -> {:ok, %{body: target_doc_0}}
            1 -> {:ok, %{body: doc1_1}}
            2 -> {:ok, %{body: doc2_1}}
            3 -> {:ok, %{body: final_doc_1}}
          end
      end

      batch_fn_1 = fn "target-id", requests ->
        send(self(), {:batch1, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, 299}} =
               GoogleDocsClient.append_template("target-id", "template-a",
                 get_fn: get_fn_1,
                 batch_fn: batch_fn_1
               )

      assert_receive {:batch1, _}
      assert_receive {:batch1, _}
      assert_receive {:batch1, _}
      refute_receive {:batch1, _}

      # Section 2: image-only, zero tables — mirrors a real template whose
      # body is only inline images with no real text (e.g. an inline image
      # element followed by the paragraph's own trailing newline), which
      # flattens to a near-empty "\n". Exercises the no-tables fast path:
      # single insertText, no extra Docs API calls (see the "no tables"
      # regression test above).
      template_c = %{
        "body" => %{
          "content" => [%{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "\n"}}]}}]
        }
      }

      current_doc_2 = %{
        "body" => %{
          "content" => [
            hd(target_doc_0["body"]["content"]),
            filled_table_block(ma, ma + 30, [{ma + 10, "A1a"}, {ma + 13, "A1b"}]),
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => ma + 30,
                    "endIndex" => ma + 31,
                    "textRun" => %{"content" => "\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn_2 = fn
        "template-c" -> {:ok, %{body: template_c}}
        "target-id" -> {:ok, %{body: current_doc_2}}
      end

      batch_fn_2 = fn "target-id", requests ->
        send(self(), {:batch2, requests})
        {:ok, %{}}
      end

      section2_content_start = ma + 32

      assert {:ok, {^section2_content_start, section2_content_end}} =
               GoogleDocsClient.append_template("target-id", "template-c",
                 get_fn: get_fn_2,
                 batch_fn: batch_fn_2
               )

      assert_receive {:batch2, _}
      refute_receive {:batch2, _}

      # Section 3: another table, appended after the image-only section.
      # Its own new table must be matched correctly — section 1's table (at
      # `ma`) must still be recognized as pre-existing despite the
      # zero-table section 2 sitting between them.
      template_b = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Head\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["B1a\n", "B1b\n"]]),
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "B-Tail\n"}}]}}
          ]
        }
      }

      {text_b, [_tb]} = GoogleDocsClient.flatten_template_with_table_markers(template_b)

      current_doc_3 = %{
        "body" => %{
          "content" =>
            current_doc_2["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{
                        "startIndex" => section2_content_start,
                        "endIndex" => section2_content_end,
                        "textRun" => %{"content" => "\n"}
                      }
                    ]
                  }
                }
              ]
        }
      }

      doc1_3 = %{
        "body" => %{
          "content" =>
            current_doc_3["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [
                      %{"startIndex" => section2_content_end, "textRun" => %{"content" => text_b}}
                    ]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: mb}] = GoogleDocsClient.find_table_marker_ranges(doc1_3)

      doc2_3 = %{
        "body" => %{
          "content" => [
            hd(current_doc_3["body"]["content"]),
            filled_table_block(ma, ma + 30, [{ma + 10, "A1a"}, {ma + 13, "A1b"}]),
            skeleton_table_block(mb, mb + 30, [mb + 10, mb + 13])
          ]
        }
      }

      final_doc_3 = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 900}]}}
          ]
        }
      }

      calls_3 = :counters.new(1, [])

      get_fn_3 = fn
        "template-b" ->
          {:ok, %{body: template_b}}

        "target-id" ->
          call = :counters.get(calls_3, 1)
          :counters.add(calls_3, 1, 1)

          case call do
            0 -> {:ok, %{body: current_doc_3}}
            1 -> {:ok, %{body: doc1_3}}
            2 -> {:ok, %{body: doc2_3}}
            3 -> {:ok, %{body: final_doc_3}}
          end
      end

      batch_fn_3 = fn "target-id", requests ->
        send(self(), {:batch3, requests})
        {:ok, %{}}
      end

      assert {:ok, {_start3, 899}} =
               GoogleDocsClient.append_template("target-id", "template-b",
                 get_fn: get_fn_3,
                 batch_fn: batch_fn_3
               )

      assert_receive {:batch3, _}
      assert_receive {:batch3, _}
      assert_receive {:batch3, fill_requests_3}
      refute_receive {:batch3, _}

      # See the equivalent filter in the two-tables-per-section test above —
      # each insertText now carries its own trailing updateTextStyle request.
      insert_requests_3 = Enum.filter(fill_requests_3, &Map.has_key?(&1, "insertText"))

      fill_targets_3 =
        Enum.map(insert_requests_3, fn %{
                                         "insertText" => %{
                                           "location" => %{"index" => idx},
                                           "text" => text
                                         }
                                       } ->
          {idx, text}
        end)

      assert Enum.sort(fill_targets_3) == Enum.sort([{mb + 11, "B1a"}, {mb + 14, "B1b"}])
      refute Enum.any?(fill_targets_3, fn {idx, _} -> idx in [ma + 11, ma + 14] end)
    end
  end

  describe "append_template/3 — formatting fidelity (mock-based)" do
    test "column widths captured from the template are applied to the new table's real (re-fetched) position in the fill batch" do
      template_doc = %{
        "body" => %{
          "content" => [
            styled_table_block(
              rows: 1,
              columns: 2,
              row_runs: [[["X"], ["Y"]]],
              column_properties: [
                %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => 150, "unit" => "PT"}},
                %{"widthType" => "FIXED_WIDTH", "width" => %{"magnitude" => 250, "unit" => "PT"}}
              ]
            )
          ]
        }
      }

      initial_target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      doc1 = %{
        "body" => %{
          "content" =>
            initial_target_doc["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: marker_start}] =
        GoogleDocsClient.find_table_marker_ranges(doc1)

      # The table's REAL post-insert startIndex is one past the marker's own
      # start_index — reproducing the real Docs API's behavior verified live:
      # insertTable's `location` index cannot be trusted as the resulting
      # table's actual position (Google inserts an implicit paragraph break
      # ahead of a table landing mid-paragraph). If the implementation used
      # marker_start instead of this confirmed value for
      # updateTableColumnProperties's tableStartLocation, this test's
      # `^table_real_start` pin below would fail.
      table_real_start = marker_start + 1

      doc2 = %{
        "body" => %{
          "content" => [
            %{
              "startIndex" => table_real_start,
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{"startIndex" => 100, "content" => []},
                      %{"startIndex" => 103, "content" => []}
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      final_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 300}]}}
          ]
        }
      }

      call_count = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)

          case call do
            0 -> {:ok, %{body: initial_target_doc}}
            1 -> {:ok, %{body: doc1}}
            2 -> {:ok, %{body: doc2}}
            3 -> {:ok, %{body: final_doc}}
          end
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      # Phase 0 and Phase 1 (skeleton) — not under test here. Column widths
      # are NOT in the skeleton batch (see the table_skeleton_requests/2
      # test above) — they ride along with Phase 2's cell fills instead,
      # once the table's real position is known from the re-fetch.
      assert_receive {:batch, _phase0}
      assert_receive {:batch, phase1_requests}
      refute Enum.any?(phase1_requests, &Map.has_key?(&1, "updateTableColumnProperties"))

      assert_receive {:batch, phase2_requests}
      refute_receive {:batch, _}

      column_width_requests =
        Enum.filter(phase2_requests, &Map.has_key?(&1, "updateTableColumnProperties"))

      assert [
               %{
                 "updateTableColumnProperties" => %{
                   "tableStartLocation" => %{"index" => ^table_real_start},
                   "columnIndices" => [0],
                   "tableColumnProperties" => %{
                     "widthType" => "FIXED_WIDTH",
                     "width" => %{"magnitude" => 150.0, "unit" => "PT"}
                   },
                   "fields" => "width,widthType"
                 }
               },
               %{
                 "updateTableColumnProperties" => %{
                   "tableStartLocation" => %{"index" => ^table_real_start},
                   "columnIndices" => [1],
                   "tableColumnProperties" => %{
                     "widthType" => "FIXED_WIDTH",
                     "width" => %{"magnitude" => 250.0, "unit" => "PT"}
                   },
                   "fields" => "width,widthType"
                 }
               }
             ] = column_width_requests
    end

    test "bold cell runs are replayed with the correct base-index-relative offsets" do
      template_doc = %{
        "body" => %{
          "content" => [
            styled_table_block(
              rows: 1,
              columns: 1,
              row_runs: [[[{"Bold", %{"bold" => true}}, " word"]]]
            )
          ]
        }
      }

      initial_target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      doc1 = %{
        "body" => %{
          "content" =>
            initial_target_doc["body"]["content"] ++
              [
                %{
                  "paragraph" => %{
                    "elements" => [%{"startIndex" => 10, "textRun" => %{"content" => text}}]
                  }
                }
              ]
        }
      }

      [%{marker_index: 1, start_index: marker_start}] =
        GoogleDocsClient.find_table_marker_ranges(doc1)

      # Single 1x1 table, one cell starting at 200 — insert_index = 201.
      doc2 = %{
        "body" => %{"content" => [skeleton_table_block(marker_start, marker_start + 30, [200])]}
      }

      final_doc = %{
        "body" => %{
          "content" => [
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 300}]}}
          ]
        }
      }

      call_count = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)

          case call do
            0 -> {:ok, %{body: initial_target_doc}}
            1 -> {:ok, %{body: doc1}}
            2 -> {:ok, %{body: doc2}}
            3 -> {:ok, %{body: final_doc}}
          end
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, _phase0}
      assert_receive {:batch, _phase1}
      assert_receive {:batch, phase2_requests}
      refute_receive {:batch, _}

      # insert_index = cell startIndex (200) + 1 = 201. "Bold" (bold:true,
      # 4 units) then " word" (bold:false, 5 units, no trailing newline to
      # strip) — captured text is "Bold word", replayed as insertText, then
      # one paragraph-style request for the cell's single paragraph, then
      # both runs' own explicit style ranges. No
      # trailing "\n" in this fixture's cell text at all, so the paragraph's
      # natural length (9) equals the inserted text's length exactly — no
      # extra unit for a stripped newline, unlike the other cell-fill tests.
      paragraph_style = unset_paragraph_style_request(201, 210)

      assert phase2_requests == [
               %{"insertText" => %{"location" => %{"index" => 201}, "text" => "Bold word"}},
               paragraph_style,
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 201, "endIndex" => 205},
                   "textStyle" => %{"bold" => true, "italic" => false},
                   "fields" => "bold,italic"
                 }
               },
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 205, "endIndex" => 210},
                   "textStyle" => %{"bold" => false, "italic" => false},
                   "fields" => "bold,italic"
                 }
               }
             ]
    end

    test "body text style (bold heading + plain paragraph) is replayed in the Phase 0 batch" do
      template_doc = %{
        "body" => %{
          "content" => [
            styled_paragraph_block([{"Heading\n", %{"bold" => true}}]),
            styled_paragraph_block(["Plain text.\n"])
          ]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, content_end}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert content_end == 11 + String.length("Heading\nPlain text.\n")

      assert_receive {:batch, requests}
      refute_receive {:batch, _}

      heading_paragraph_style = unset_paragraph_style_request(11, 19)
      plain_paragraph_style = unset_paragraph_style_request(19, 31)

      assert [
               %{insertSectionBreak: %{location: %{index: 9}, sectionType: "NEXT_PAGE"}},
               %{insertText: %{location: %{index: 11}, text: "Heading\nPlain text.\n"}},
               ^heading_paragraph_style,
               ^plain_paragraph_style,
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 11, "endIndex" => 19},
                   "textStyle" => %{"bold" => true, "italic" => false},
                   "fields" => "bold,italic"
                 }
               },
               %{
                 "updateTextStyle" => %{
                   "range" => %{"startIndex" => 19, "endIndex" => 31},
                   "textStyle" => %{"bold" => false, "italic" => false},
                   "fields" => "bold,italic"
                 }
               },
               %{
                 "deleteParagraphBullets" => %{
                   "range" => %{"startIndex" => 11, "endIndex" => 31}
                 }
               }
             ] = requests
    end
  end

  describe "flatten_template_with_table_markers_and_styles/1 — paragraph style + bullet capture" do
    test "captures explicit paragraphStyle fields for a body paragraph, no defaults substituted" do
      doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["Centered heading\n"],
              paragraph_style: %{
                "alignment" => "CENTER",
                "lineSpacing" => 150.0,
                "spaceAbove" => %{"magnitude" => 12, "unit" => "PT"},
                "spaceBelow" => %{"magnitude" => 6, "unit" => "PT"},
                "namedStyleType" => "HEADING_1",
                "indentStart" => %{"magnitude" => 18, "unit" => "PT"},
                "indentFirstLine" => %{"magnitude" => 36, "unit" => "PT"}
              }
            )
          ]
        }
      }

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.style.alignment == "CENTER"
      assert para.style.line_spacing == 150.0
      assert para.style.space_above == %{magnitude: 12.0, unit: "PT"}
      assert para.style.space_below == %{magnitude: 6.0, unit: "PT"}
      assert para.style.named_style_type == "HEADING_1"
      assert para.style.indent_start == %{magnitude: 18.0, unit: "PT"}
      assert para.style.indent_first_line == %{magnitude: 36.0, unit: "PT"}
      assert para.bullet == nil
    end

    test "a paragraph with no paragraphStyle key captures every property as unset (inherits its named style)" do
      doc = %{"body" => %{"content" => [styled_paragraph_block(["Plain\n"])]}}

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.style == unset_span_style()
    end

    test "captures paragraphStyle for a table cell's paragraph, using the cell's natural (un-stripped) length" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "rows" => 1,
                "columns" => 1,
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [%{"textRun" => %{"content" => "Cell\n"}}],
                              "paragraphStyle" => %{"alignment" => "END"}
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

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert [[cell_para]] = table.cell_paragraphs
      assert cell_para.start_offset == 0
      # Natural length ("Cell\n" = 5 units), not the 4-unit stripped length
      # cell_texts/cell_runs use for the actual insertText — see
      # cell_paragraph_spans/2's doc for why the extra unit is correct here.
      assert cell_para.length == 5
      assert cell_para.style.alignment == "END"
      assert table.cell_texts == ["Cell"]
    end

    test "an empty cell still captures its paragraph span so its style can replay" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "rows" => 1,
                "columns" => 1,
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [%{"textRun" => %{"content" => "\n"}}],
                              "paragraphStyle" => %{"alignment" => "CENTER"}
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

      assert {_text, [table], _, _} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      # The cell's text is empty (nothing to insert), but the bare
      # paragraph's span survives with its alignment — cell_fill_requests/4
      # replays it against the new cell's pre-existing paragraph.
      assert table.cell_texts == [""]
      assert [[cell_para]] = table.cell_paragraphs
      assert cell_para.length == 1
      assert cell_para.style.alignment == "CENTER"
    end

    test "resolves a numbered preset from doc[\"lists\"] when the level's nesting has a glyphType" do
      doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["Item one\n"], bullet: %{"listId" => "L1", "nestingLevel" => 0})
          ]
        },
        "lists" => %{
          "L1" => %{"listProperties" => %{"nestingLevels" => [%{"glyphType" => "DECIMAL"}]}}
        }
      }

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.bullet == %{list_id: "L1", preset: "NUMBERED_DECIMAL_ALPHA_ROMAN"}
    end

    test "resolves a bulleted preset from doc[\"lists\"] when the level's nesting has a glyphSymbol" do
      doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["Item one\n"], bullet: %{"listId" => "L2", "nestingLevel" => 0})
          ]
        },
        "lists" => %{
          "L2" => %{"listProperties" => %{"nestingLevels" => [%{"glyphSymbol" => "●"}]}}
        }
      }

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.bullet == %{list_id: "L2", preset: "BULLET_DISC_CIRCLE_SQUARE"}
    end

    test "a bullet whose listId is missing from doc[\"lists\"] falls back to the bulleted preset" do
      doc = %{
        "body" => %{"content" => [paragraph_block(["Item\n"], bullet: %{"listId" => "Unknown"})]}
      }

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.bullet == %{list_id: "Unknown", preset: "BULLET_DISC_CIRCLE_SQUARE"}
    end

    test "a paragraph with no bullet key captures bullet: nil" do
      doc = %{"body" => %{"content" => [styled_paragraph_block(["Plain\n"])]}}

      assert {_text, [], _body_runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.bullet == nil
    end
  end

  describe "paragraph_style_requests/2" do
    test "builds one updateParagraphStyle request per span, anchored at base_index + start_offset" do
      spans = [
        %{start_offset: 0, length: 5, style: unset_span_style()},
        %{start_offset: 5, length: 7, style: unset_span_style()}
      ]

      assert GoogleDocsClient.paragraph_style_requests(100, spans) == [
               unset_paragraph_style_request(100, 105),
               unset_paragraph_style_request(105, 112)
             ]
    end

    test "skips a zero-length span" do
      assert GoogleDocsClient.paragraph_style_requests(100, [
               %{start_offset: 0, length: 0, style: unset_span_style()}
             ]) == []
    end

    test "replays explicit non-default captured style values verbatim" do
      style = %{
        alignment: "JUSTIFIED",
        line_spacing: 200.0,
        space_above: %{magnitude: 24.0, unit: "PT"},
        space_below: %{magnitude: 12.0, unit: "PT"},
        named_style_type: "HEADING_2",
        indent_start: %{magnitude: 36.0, unit: "PT"},
        indent_first_line: %{magnitude: 0.0, unit: "PT"}
      }

      spans = [%{start_offset: 0, length: 3, style: style}]

      assert GoogleDocsClient.paragraph_style_requests(10, spans) == [
               %{
                 "updateParagraphStyle" => %{
                   "range" => %{"startIndex" => 10, "endIndex" => 13},
                   "paragraphStyle" => %{
                     "alignment" => "JUSTIFIED",
                     "lineSpacing" => 200.0,
                     "spaceAbove" => %{"magnitude" => 24.0, "unit" => "PT"},
                     "spaceBelow" => %{"magnitude" => 12.0, "unit" => "PT"},
                     "namedStyleType" => "HEADING_2",
                     "indentStart" => %{"magnitude" => 36.0, "unit" => "PT"},
                     "indentFirstLine" => %{"magnitude" => 0.0, "unit" => "PT"}
                   },
                   "fields" => @paragraph_style_fields
                 }
               }
             ]
    end
  end

  describe "paragraph_style_requests/2 — unset properties inherit the named style" do
    test "an unset property keeps its place in the fields mask but carries no value" do
      style = %{unset_span_style() | named_style_type: "HEADING_1", line_spacing: 150.0}
      spans = [%{start_offset: 0, length: 4, style: style}]

      assert [%{"updateParagraphStyle" => request}] =
               GoogleDocsClient.paragraph_style_requests(1, spans)

      # A template heading that relies on HEADING_1's own spaceAbove/Below
      # must not come out with them forced to zero; a property the template
      # does set (150% here) is still replayed verbatim.
      assert request["paragraphStyle"] == %{
               "namedStyleType" => "HEADING_1",
               "lineSpacing" => 150.0
             }

      assert request["fields"] == @paragraph_style_fields
    end
  end

  describe "paragraph style is applied before character style" do
    # Verified live against the Docs API (2026-09-21): an updateParagraphStyle
    # whose mask includes namedStyleType resets the paragraph's text style,
    # even when the named style doesn't change. With the character styles
    # sent first, every appended section lost its font sizes and bold.
    test "paragraph_then_text_style_requests/3 puts every paragraph request ahead of every text request" do
      paragraphs = [
        %{start_offset: 0, length: 5, style: unset_span_style()},
        %{start_offset: 5, length: 6, style: unset_span_style()}
      ]

      runs = [
        %{start_offset: 0, length: 5, bold: true, italic: false, font_size: 7, color: nil},
        %{start_offset: 5, length: 6, bold: false, italic: false, font_size: nil, color: nil}
      ]

      requests = GoogleDocsClient.paragraph_then_text_style_requests(10, paragraphs, runs)

      assert length(requests) == 4
      assert_paragraph_style_before_text_style(requests)
    end

    test "append_template/3 body batch: both paragraphs are styled before either run" do
      template = %{
        "body" => %{
          "content" => [
            styled_paragraph_block([
              {"Small bold\n", %{"bold" => true, "fontSize" => %{"magnitude" => 7}}}
            ]),
            styled_paragraph_block(["Plain\n"])
          ]
        }
      }

      target = %{"body" => %{"content" => [%{"startIndex" => 1, "endIndex" => 10}]}}
      test_pid = self()

      get_fn = fn
        "template-id" -> {:ok, %{body: template}}
        "target-id" -> {:ok, %{body: target}}
      end

      batch_fn = fn "target-id", requests ->
        send(test_pid, {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_received {:batch, requests}
      assert_paragraph_style_before_text_style(requests)
    end
  end

  describe "flatten_template_with_table_markers_and_styles/1 — explicit zero vs inherited" do
    # The API omits a zero magnitude from its JSON, so an explicit 0pt reads
    # back as `%{"unit" => "PT"}`; an inherited property has no key at all
    # (verified live 2026-09-21).
    test "a unit-only dimension is an explicit zero, an absent key is unset" do
      doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["No space above\n"],
              paragraph_style: %{
                "namedStyleType" => "HEADING_1",
                "spaceAbove" => %{"unit" => "PT"},
                "indentStart" => %{"unit" => "PT"}
              }
            )
          ]
        }
      }

      assert {_text, [], _runs, [para]} =
               GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      assert para.style.space_above == %{magnitude: 0.0, unit: "PT"}
      assert para.style.indent_start == %{magnitude: 0.0, unit: "PT"}
      assert para.style.space_below == nil
      assert para.style.indent_first_line == nil

      assert [%{"updateParagraphStyle" => %{"paragraphStyle" => payload}}] =
               GoogleDocsClient.paragraph_style_requests(1, [para])

      # The heading keeps its removed space above instead of getting
      # HEADING_1's own back.
      assert payload["spaceAbove"] == %{"magnitude" => 0.0, "unit" => "PT"}
      refute Map.has_key?(payload, "spaceBelow")
    end
  end

  describe "flatten_template_with_table_markers_and_styles/1 — dimension shapes" do
    defp captured_space_above(dimension) do
      doc = %{
        "body" => %{
          "content" => [paragraph_block(["x\n"], paragraph_style: %{"spaceAbove" => dimension})]
        }
      }

      {_text, [], _runs, [para]} =
        GoogleDocsClient.flatten_template_with_table_markers_and_styles(doc)

      para.style.space_above
    end

    test "an explicit zero keeps its own unit" do
      assert captured_space_above(%{"unit" => "MM"}) == %{magnitude: 0.0, unit: "MM"}
    end

    test "a dimension with neither a magnitude nor a usable unit is unset" do
      assert captured_space_above(%{}) == nil
      assert captured_space_above(%{"unit" => nil}) == nil
    end
  end

  describe "append_template/3 — each appended template is its own section with its own margins" do
    test "the template's page margins are applied to the new section, after its content is in" do
      template = %{
        "documentStyle" => %{
          "marginTop" => points(72),
          "marginBottom" => points(72),
          "marginLeft" => points(72),
          "marginRight" => points(72),
          "marginHeader" => points(36),
          "marginFooter" => points(36),
          "pageSize" => %{"width" => points(595), "height" => points(842)}
        },
        # A list item, so the batch also carries createParagraphBullets —
        # "last" then means after the bullets too, not merely after the text.
        "body" => %{
          "content" => [
            styled_paragraph_block(["Contract\n"]),
            paragraph_block(["Clause\n"], bullet: %{"listId" => "L1"})
          ]
        }
      }

      {{content_start, _end}, requests} = append_first_batch(template)

      assert Enum.any?(requests, &Map.has_key?(&1, "createParagraphBullets"))

      # A section break inserts its own newline ahead of itself (verified
      # live), so content starts two units past the insertion point — the
      # same offset the old "\n" + page break pair produced.
      assert content_start == 11

      assert [%{insertSectionBreak: %{location: %{index: 9}, sectionType: "NEXT_PAGE"}} | _] =
               requests

      assert %{
               "updateSectionStyle" => %{
                 "range" => %{"startIndex" => 11, "endIndex" => 12},
                 "sectionStyle" => section_style,
                 "fields" => fields
               }
             } = List.last(requests)

      assert section_style == %{
               "marginTop" => points(72.0),
               "marginBottom" => points(72.0),
               "marginLeft" => points(72.0),
               "marginRight" => points(72.0),
               "marginHeader" => points(36.0),
               "marginFooter" => points(36.0)
             }

      assert fields == "marginTop,marginBottom,marginLeft,marginRight,marginHeader,marginFooter"
    end

    test "a zero margin (unit-only in the API's JSON) is applied as an explicit zero" do
      template = %{
        "documentStyle" => %{"marginTop" => %{"unit" => "PT"}, "marginLeft" => points(44)},
        "body" => %{"content" => [styled_paragraph_block(["x\n"])]}
      }

      {_range, requests} = append_first_batch(template)

      assert %{"updateSectionStyle" => %{"sectionStyle" => style, "fields" => fields}} =
               List.last(requests)

      # Only the margins the template states are touched.
      assert style == %{"marginTop" => points(0.0), "marginLeft" => points(44.0)}
      assert fields == "marginTop,marginLeft"
    end

    test "a template without a documentStyle leaves the section's margins alone" do
      template = %{"body" => %{"content" => [styled_paragraph_block(["x\n"])]}}

      {_range, requests} = append_first_batch(template)

      refute Enum.any?(requests, &Map.has_key?(&1, "updateSectionStyle"))
    end
  end

  describe "append_template/3 — section margins with tables and real-shaped section breaks" do
    test "the margin request is sent exactly once — last in the first batch — and section breaks in the body don't disturb the table pipeline" do
      template_doc = %{
        "documentStyle" => %{"marginLeft" => points(72), "marginRight" => points(72)},
        "body" => %{
          "content" => [
            %{
              "sectionBreak" => %{"sectionStyle" => %{"sectionType" => "CONTINUOUS"}},
              "endIndex" => 1
            },
            %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hi\n"}}]}},
            table_block(rows: 1, columns: 2, row_texts: [["X\n", "Y\n"]])
          ]
        }
      }

      {text, _tables} = GoogleDocsClient.flatten_template_with_table_markers(template_doc)

      leading_break = %{
        "sectionBreak" => %{"sectionStyle" => %{"sectionType" => "CONTINUOUS"}},
        "endIndex" => 1
      }

      existing = %{
        "paragraph" => %{
          "elements" => [
            %{"startIndex" => 1, "endIndex" => 10, "textRun" => %{"content" => "Existing\n"}}
          ]
        }
      }

      # What the target really looks like once the append's own section
      # break is in: a sectionBreak structural element between the sections.
      appended_break = %{
        "startIndex" => 10,
        "endIndex" => 11,
        "sectionBreak" => %{"sectionStyle" => %{"sectionType" => "NEXT_PAGE"}}
      }

      doc1 = %{
        "body" => %{
          "content" => [
            leading_break,
            existing,
            appended_break,
            %{
              "paragraph" => %{
                "elements" => [%{"startIndex" => 11, "textRun" => %{"content" => text}}]
              }
            }
          ]
        }
      }

      [%{start_index: marker_start}] = GoogleDocsClient.find_table_marker_ranges(doc1)

      doc2 = %{
        "body" => %{
          "content" => [
            leading_break,
            existing,
            appended_break,
            %{
              "startIndex" => marker_start,
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{"startIndex" => 100, "content" => []},
                      %{"startIndex" => 103, "content" => []}
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      final_doc = %{
        "body" => %{
          "content" => [
            leading_break,
            %{"paragraph" => %{"elements" => [%{"startIndex" => 1, "endIndex" => 500}]}}
          ]
        }
      }

      calls = :counters.new(1, [])
      test_pid = self()

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          call = :counters.get(calls, 1)
          :counters.add(calls, 1, 1)

          {:ok,
           %{
             body:
               Enum.at(
                 [%{"body" => %{"content" => [leading_break, existing]}}, doc1, doc2, final_doc],
                 call
               )
           }}
      end

      batch_fn = fn "target-id", requests ->
        send(test_pid, {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, 499}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_received {:batch, first}
      assert_received {:batch, skeleton}
      assert_received {:batch, fill}
      refute_received {:batch, _}

      assert %{"updateSectionStyle" => %{"range" => %{"startIndex" => 11, "endIndex" => 12}}} =
               List.last(first)

      margin_requests =
        Enum.filter(first ++ skeleton ++ fill, &Map.has_key?(&1, "updateSectionStyle"))

      assert length(margin_requests) == 1
      assert Enum.any?(skeleton, &Map.has_key?(&1, "insertTable"))
      assert Enum.any?(fill, &Map.has_key?(&1, "insertText"))
    end
  end

  describe "section_margin_requests/2" do
    test "a documentStyle with a page size but no margins produces no request" do
      doc = %{"documentStyle" => %{"pageSize" => %{"width" => points(595)}}}

      assert GoogleDocsClient.section_margin_requests(11, doc) == []
      assert GoogleDocsClient.section_margin_requests(11, %{}) == []
      assert GoogleDocsClient.section_margin_requests(11, %{"documentStyle" => nil}) == []
    end

    test "fields follow the canonical margin order whatever the map's own order; units pass through" do
      doc = %{
        "documentStyle" => %{
          "marginFooter" => %{"magnitude" => 10, "unit" => "MM"},
          "marginTop" => %{"unit" => "PT"},
          "marginLeft" => points(44)
        }
      }

      assert [%{"updateSectionStyle" => request}] =
               GoogleDocsClient.section_margin_requests(7, doc)

      assert request["range"] == %{"startIndex" => 7, "endIndex" => 8}
      assert request["fields"] == "marginTop,marginLeft,marginFooter"

      assert request["sectionStyle"] == %{
               "marginTop" => points(0.0),
               "marginLeft" => points(44.0),
               "marginFooter" => %{"magnitude" => 10.0, "unit" => "MM"}
             }
    end

    test "the template's first section margins win over its documentStyle, field by field" do
      doc = %{
        "documentStyle" => %{"marginTop" => points(72), "marginLeft" => points(72)},
        "body" => %{
          "content" => [
            %{
              "endIndex" => 1,
              "sectionBreak" => %{
                "sectionStyle" => %{
                  "columnSeparatorStyle" => "NONE",
                  "marginTop" => points(20),
                  "marginBottom" => %{"unit" => "PT"}
                }
              }
            },
            %{"startIndex" => 1, "endIndex" => 5, "paragraph" => %{"elements" => []}}
          ]
        }
      }

      assert [%{"updateSectionStyle" => request}] =
               GoogleDocsClient.section_margin_requests(3, doc)

      assert request["fields"] == "marginTop,marginBottom,marginLeft"

      assert request["sectionStyle"] == %{
               "marginTop" => points(20.0),
               "marginBottom" => points(0.0),
               "marginLeft" => points(72.0)
             }
    end
  end

  describe "paragraph_bullet_requests/2" do
    test "merges contiguous spans sharing the same listId into one range, using the first span's preset" do
      bullet = %{list_id: "L1", preset: "NUMBERED_DECIMAL_ALPHA_ROMAN"}

      spans = [
        %{start_offset: 0, length: 5, style: unset_span_style(), bullet: bullet},
        %{start_offset: 5, length: 6, style: unset_span_style(), bullet: bullet},
        %{start_offset: 11, length: 4, style: unset_span_style(), bullet: bullet}
      ]

      assert GoogleDocsClient.paragraph_bullet_requests(100, spans) == [
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 100, "endIndex" => 115},
                   "bulletPreset" => "NUMBERED_DECIMAL_ALPHA_ROMAN"
                 }
               }
             ]
    end

    test "does not merge across a different listId — separate ranges/presets" do
      spans = [
        %{
          start_offset: 0,
          length: 5,
          style: unset_span_style(),
          bullet: %{list_id: "L1", preset: "BULLET_DISC_CIRCLE_SQUARE"}
        },
        %{
          start_offset: 5,
          length: 5,
          style: unset_span_style(),
          bullet: %{list_id: "L2", preset: "NUMBERED_DECIMAL_ALPHA_ROMAN"}
        }
      ]

      # Descending range order: createParagraphBullets strips leading tabs,
      # which would shift any later (higher) range — highest goes first.
      assert GoogleDocsClient.paragraph_bullet_requests(0, spans) == [
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 5, "endIndex" => 10},
                   "bulletPreset" => "NUMBERED_DECIMAL_ALPHA_ROMAN"
                 }
               },
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 0, "endIndex" => 5},
                   "bulletPreset" => "BULLET_DISC_CIRCLE_SQUARE"
                 }
               }
             ]
    end

    test "a non-bullet paragraph in between breaks contiguity, even for the same listId on both sides" do
      bullet = %{list_id: "L1", preset: "BULLET_DISC_CIRCLE_SQUARE"}

      spans = [
        %{start_offset: 0, length: 5, style: unset_span_style(), bullet: bullet},
        %{start_offset: 5, length: 5, style: unset_span_style(), bullet: nil},
        %{start_offset: 10, length: 5, style: unset_span_style(), bullet: bullet}
      ]

      assert GoogleDocsClient.paragraph_bullet_requests(0, spans) == [
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 10, "endIndex" => 15},
                   "bulletPreset" => "BULLET_DISC_CIRCLE_SQUARE"
                 }
               },
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 0, "endIndex" => 5},
                   "bulletPreset" => "BULLET_DISC_CIRCLE_SQUARE"
                 }
               }
             ]
    end

    test "excludes non-bullet spans and zero-length spans entirely" do
      spans = [
        %{start_offset: 0, length: 5, style: unset_span_style(), bullet: nil},
        %{
          start_offset: 5,
          length: 0,
          style: unset_span_style(),
          bullet: %{list_id: "L1", preset: "BULLET_DISC_CIRCLE_SQUARE"}
        }
      ]

      assert GoogleDocsClient.paragraph_bullet_requests(0, spans) == []
    end
  end

  describe "append_template/3 — paragraph style + bullet fidelity (mock-based)" do
    test "non-default paragraph style on a body heading is replayed verbatim, plain sibling gets every property unset" do
      template_doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["Heading\n"],
              paragraph_style: %{"alignment" => "CENTER", "namedStyleType" => "HEADING_1"}
            ),
            styled_paragraph_block(["Plain text.\n"])
          ]
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, requests}

      paragraph_style_requests = Enum.filter(requests, &Map.has_key?(&1, "updateParagraphStyle"))

      heading_style = %{
        "updateParagraphStyle" => %{
          "range" => %{"startIndex" => 11, "endIndex" => 19},
          "paragraphStyle" => %{
            "alignment" => "CENTER",
            "namedStyleType" => "HEADING_1"
          },
          "fields" => @paragraph_style_fields
        }
      }

      plain_style = unset_paragraph_style_request(19, 31)

      assert paragraph_style_requests == [heading_style, plain_style]
    end

    test "contiguous numbered-list body paragraphs replay as one merged createParagraphBullets range" do
      template_doc = %{
        "body" => %{
          "content" => [
            paragraph_block(["First\n"], bullet: %{"listId" => "L1", "nestingLevel" => 0}),
            paragraph_block(["Second\n"], bullet: %{"listId" => "L1", "nestingLevel" => 0})
          ]
        },
        "lists" => %{
          "L1" => %{"listProperties" => %{"nestingLevels" => [%{"glyphType" => "DECIMAL"}]}}
        }
      }

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, _} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, requests}

      bullet_requests = Enum.filter(requests, &Map.has_key?(&1, "createParagraphBullets"))

      # content_start = 11, "First\n" = 6 units, "Second\n" = 7 units — one
      # merged range spanning both paragraphs (11 to 11+6+7=24), so the
      # target document gets one continuous numbered list (1, 2) instead of
      # two separate single-item lists (each restarting at 1).
      assert bullet_requests == [
               %{
                 "createParagraphBullets" => %{
                   "range" => %{"startIndex" => 11, "endIndex" => 24},
                   "bulletPreset" => "NUMBERED_DECIMAL_ALPHA_ROMAN"
                 }
               }
             ]

      # The inherited-bullet sweep (deleteParagraphBullets over the whole
      # inserted body) must run BEFORE the section's own creates within the
      # batch: a target document ending in a list item leaks its bullet
      # onto the fresh first paragraph via the section break's paragraph
      # split, and the sweep is what clears it — sweeping after the creates would wipe the
      # section's own lists instead.
      delete_at =
        Enum.find_index(requests, &Map.has_key?(&1, "deleteParagraphBullets"))

      first_create_at =
        Enum.find_index(requests, &Map.has_key?(&1, "createParagraphBullets"))

      assert is_integer(delete_at)
      assert delete_at < first_create_at

      assert %{
               "deleteParagraphBullets" => %{
                 "range" => %{"startIndex" => 11, "endIndex" => 24}
               }
             } = Enum.at(requests, delete_at)
    end
  end

  describe "append_template/3 — the section break guarantees a fresh first paragraph" do
    test "inserts the section break then content, content_start landing two past insert_index" do
      template_doc = %{"body" => %{"content" => [styled_paragraph_block(["Plain\n"])]}}

      target_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "endIndex" => 10,
                    "textRun" => %{"content" => "Existing\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: target_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      # insert_index = document_end_index(target_doc) - 1 = 9. The section
      # break inserts a newline ahead of itself (9) and occupies 10, so
      # content_start = 11 — in the new section's own fresh paragraph rather
      # than one before the target's closing character.
      assert {:ok, {11, 17}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, requests}

      assert [
               %{insertSectionBreak: %{location: %{index: 9}, sectionType: "NEXT_PAGE"}},
               %{insertText: %{location: %{index: 11}, text: "Plain\n"}}
               | _rest
             ] = requests
    end

    test "the appended section's first body paragraph is styled correctly regardless of whether the target's own tail text happens to end in a newline" do
      for target_text <- ["Existing", "Existing\n"] do
        template_doc = %{
          "body" => %{
            "content" => [
              paragraph_block(["Heading\n"], paragraph_style: %{"alignment" => "CENTER"}),
              styled_paragraph_block(["Body.\n"])
            ]
          }
        }

        target_doc = %{
          "body" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => String.length(target_text) + 1,
                      "textRun" => %{"content" => target_text}
                    }
                  ]
                }
              }
            ]
          }
        }

        get_fn = fn
          "template-id" -> {:ok, %{body: template_doc}}
          "target-id" -> {:ok, %{body: target_doc}}
        end

        batch_fn = fn "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
        end

        assert {:ok, {content_start, _}} =
                 GoogleDocsClient.append_template("target-id", "template-id",
                   get_fn: get_fn,
                   batch_fn: batch_fn
                 )

        assert_receive {:batch, requests}

        paragraph_style_requests =
          Enum.filter(requests, &Map.has_key?(&1, "updateParagraphStyle"))

        alignments =
          Enum.map(
            paragraph_style_requests,
            & &1["updateParagraphStyle"]["paragraphStyle"]["alignment"]
          )

        # Both paragraphs get styled, the first ("Heading", CENTER) included
        # — the section break always opens a fresh paragraph, so this does
        # not depend on whether target_text ends in "\n".
        assert alignments == ["CENTER", nil],
               "target_text: #{inspect(target_text)}, got: #{inspect(alignments)}"

        # nil here must mean "unset on purpose": the key is absent from the
        # payload while the mask still names it.
        plain = List.last(paragraph_style_requests)["updateParagraphStyle"]
        refute Map.has_key?(plain["paragraphStyle"], "alignment")
        assert plain["fields"] =~ "alignment"

        assert [heading_range, _body_range] =
                 Enum.map(paragraph_style_requests, & &1["updateParagraphStyle"]["range"])

        assert heading_range == %{"startIndex" => content_start, "endIndex" => content_start + 8}
      end
    end
  end
end
