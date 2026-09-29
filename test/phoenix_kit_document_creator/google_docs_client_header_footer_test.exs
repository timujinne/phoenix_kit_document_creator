defmodule PhoenixKitDocumentCreator.GoogleDocsClientHeaderFooterTest do
  @moduledoc """
  Coverage for Block C: an appended section gets its OWN header/footer
  (`GoogleDocsClient.append_template/3`'s header/footer step, built on
  `SegmentReplay` — see its own test file for the fingerprint/request-shape
  unit coverage). Mock style matches
  `google_docs_client_append_tables_test.exs` (`:get_fn`/`:batch_fn`
  injection, `:counters` for a stateful re-fetch sequence).

  Also covers `header_footer_owners/3` — which section's `variable_values`
  a header/footer `{{key}}` placeholder resolves against once a document
  can hold more than one header/footer segment; the end-to-end
  `substitute_all_sections/3` case lives in
  `test/integration/google_docs_client_http_test.exs` alongside its
  existing header/footer substitution coverage (it needs the HTTP stub,
  since `substitute_all_sections/3` has no `:get_fn`/`:batch_fn` opts).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Regression guard for a real Docs API rule (verified live 2026-09-23,
  # fe631e3): a `deleteContentRange` reaching a segment's own terminal
  # newline is rejected outright — "Invalid requests[N].deleteContentRange:
  # The range cannot include the newline character at the end of the
  # segment" — failing the WHOLE batch and leaving the append half-done.
  # Mocks accept any range unconditionally, so nothing else here would
  # catch a regression back to that shape. `terminal_index` is the
  # segment's own known length at that point in the test's fixture (its
  # length never changes here — nothing after this point inserts/deletes
  # segment-scoped content in the batches this checks).
  defp refute_terminal_newline_delete!(requests, terminal_index) do
    refute Enum.any?(requests, fn
             %{"deleteContentRange" => %{"range" => %{"endIndex" => ^terminal_index}}} -> true
             _ -> false
           end),
           "deleteContentRange must never reach a segment's own terminal newline " <>
             "(index #{terminal_index}) — the Docs API rejects it"
  end

  defp text_paragraph(text),
    do: %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => text}}]}}

  defp table_header_content do
    [
      %{
        "table" => %{
          "rows" => 1,
          "columns" => 1,
          "tableRows" => [
            %{
              "tableCells" => [
                %{
                  "content" => [
                    %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Reg\n"}}]}}
                  ]
                }
              ]
            }
          ]
        }
      }
    ]
  end

  # Body content shared by most tests below: one existing paragraph ending
  # at index 10 (same numbers as google_docs_client_append_tables_test.exs's
  # fixtures) so insert_index=9, content_start=11, break_index=10 — no
  # table in the BODY, so `finish_append_template/6` never re-fetches,
  # keeping the `:counters` sequence in every test about the HEADER/FOOTER
  # re-fetches only.
  defp target_body do
    %{
      "content" => [
        %{
          "paragraph" => %{
            "elements" => [
              %{"startIndex" => 1, "endIndex" => 10, "textRun" => %{"content" => "Existing\n"}}
            ]
          }
        }
      ]
    }
  end

  describe "append_template/3 — template has no header/footer at all (regression)" do
    test "no createHeader/createFooter, no extra get_fn calls" do
      template_doc = %{"body" => %{"content" => [text_paragraph("Body\n")]}}
      current_doc = %{"body" => target_body()}

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: current_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      refute_receive {:batch, _}
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — template's header fingerprints the same as what the section would inherit" do
    test "no createHeader, no extra get_fn calls" do
      shared_header_content = [text_paragraph("Hi\n")]

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => shared_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => shared_header_content}},
        "body" => target_body()
      }

      get_calls = :counters.new(1, [])

      get_fn = fn
        "template-id" ->
          {:ok, %{body: template_doc}}

        "target-id" ->
          :counters.add(get_calls, 1, 1)
          {:ok, %{body: current_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      refute_receive {:batch, _}
      assert :counters.get(get_calls, 1) == 1
    end
  end

  describe "append_template/3 — template's header differs from what the section would inherit" do
    test "creates the header at the section's own break and replays its (table-free) content" do
      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => [text_paragraph("Hi\n")]}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Bye\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}

      assert_receive {:batch,
                      [
                        %{
                          "createHeader" => %{
                            "type" => "DEFAULT",
                            "sectionBreakLocation" => %{"index" => 10}
                          }
                        }
                      ]}

      assert_receive {:batch, [insert_req, para_req, text_req]}

      # "Hi\n"'s own trailing newline is stripped before insertion — the
      # fresh segment's pre-existing one serves as its terminator instead
      # (the Docs API refuses to delete a segment's terminal newline). The
      # style requests still target the FULL, un-stripped span [0, 3) —
      # covering "Hi" plus that pre-existing newline landing right after it.
      assert insert_req == %{
               "insertText" => %{
                 "location" => %{"index" => 0, "segmentId" => "kix.new_header"},
                 "text" => "Hi"
               }
             }

      assert para_req["updateParagraphStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 3,
               "segmentId" => "kix.new_header"
             }

      assert text_req["updateTextStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 3,
               "segmentId" => "kix.new_header"
             }

      # no footer in the template — nothing else follows.
      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — template's footer differs but can't be replayed faithfully" do
    @tag :capture_log
    test "a page-number (autoText) footer keeps the inherited footer instead of a lossy copy" do
      page_number_footer = [
        %{
          "paragraph" => %{
            "elements" => [
              %{"textRun" => %{"content" => "Page "}},
              %{"autoText" => %{"type" => "PAGE_NUMBER"}},
              %{"textRun" => %{"content" => "\n"}}
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "footers" => %{"kix.tpl_footer" => %{"content" => page_number_footer}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Bye\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn "target-id", requests ->
        send(self(), {:batch, requests})
        {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — a section's own header shadows what its trailing section would otherwise chain-inherit" do
    test "the target's LAST section's own header wins over documentStyle's, even when the template matches documentStyle's" do
      # current_doc already has two sections (as if a prior append already
      # gave section 1 its own, different header) — section 0 (and
      # documentStyle) carry "kix.home", section 1 carries its own
      # "kix.landscape_header". A new section whose template's header
      # fingerprints the same as "kix.home" must still get its own replayed
      # copy, because what it'd actually inherit is section 1's, not
      # documentStyle's.
      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => [text_paragraph("Hi\n")]}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home"},
        "headers" => %{
          "kix.home" => %{"content" => [text_paragraph("Hi\n")]},
          "kix.landscape_header" => %{"content" => [text_paragraph("Landscape\n")]}
        },
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "endIndex" => 5, "textRun" => %{"content" => "Sec0\n"}}
                ]
              }
            },
            %{
              "startIndex" => 5,
              "sectionBreak" => %{
                "sectionStyle" => %{"defaultHeaderId" => "kix.landscape_header"}
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 6, "endIndex" => 10, "textRun" => %{"content" => "Sec1\n"}}
                ]
              }
            }
          ]
        }
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}

      assert_receive {:batch,
                      [%{"createHeader" => %{"sectionBreakLocation" => %{"index" => 10}}}]}

      # "Hi\n"'s own trailing newline is stripped — the fresh segment's
      # pre-existing one serves as its terminator (the Docs API refuses to
      # delete a segment's terminal newline).
      assert_receive {:batch, [%{"insertText" => %{"text" => "Hi"}} | _]}
      refute_receive {:batch, _}
    end
  end

  describe "append_template/3 — replays a table inside the new header" do
    test "creates the header, inserts the skeleton, then styles every element at its real post-table index" do
      # [P, TABLE, P] — the shape verified live 2026-09-23 against a real
      # header: both spacer paragraphs are trivially empty ("\n" only), so
      # neither contributes anything to the skeleton text once its trailing
      # newline is stripped (see `table_bearing_skeleton_text/2`'s doc) —
      # the skeleton insert is the table marker alone, same as before.
      template_header_content =
        [text_paragraph("\n")] ++ table_header_content() ++ [text_paragraph("\n")]

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      # The marker alone — NOT derived from `template_header_content` (which
      # still carries both spacer paragraphs' own "\n"s): the skeleton
      # insert strips both, since each is either immediately before the
      # table or the template's own last block (see
      # `table_bearing_skeleton_text/2`'s doc), so only the bare marker
      # from the table alone (nothing to strip around it) matches.
      {marker_text, _tables} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => table_header_content()}
        })

      # State after the skeleton insertText: the header segment holds only
      # the marker text (merged with the segment's own pre-existing
      # newline, since nothing separates them). No `startIndex` on the
      # element at all — proto3 JSON omits a zero-valued field, and a
      # segment's own index space starts at 0 (verified live 2026-09-23:
      # this is EXACTLY the shape that broke `segment_marker_ranges/3`
      # before it defaulted a missing `startIndex` to 0).
      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [%{"textRun" => %{"content" => marker_text}}]
                }
              }
            ]
          }
        }
      }

      # State after the table-skeleton batch: `insertTable` landing where
      # the marker was splits the paragraph that absorbed it into a
      # "before" half (an empty paragraph — nothing preceded the marker,
      # since the first spacer's own text was never inserted) and an
      # "after" half (the segment's own pre-existing newline, likewise
      # never re-inserted for the second spacer) — exactly [P, TABLE, P],
      # matching the template 1:1. Neither half is deleted (verified live
      # 2026-09-23: the API refuses "Cannot delete the requested range"
      # for the paragraph immediately before a table) — both are styled
      # in place instead.
      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "startIndex" => 0,
                "endIndex" => 1,
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 0, "endIndex" => 1, "textRun" => %{"content" => "\n"}}
                  ]
                }
              },
              %{
                "startIndex" => 1,
                "endIndex" => 4,
                "table" => %{
                  "tableRows" => [
                    %{"tableCells" => [%{"startIndex" => 2, "endIndex" => 3, "content" => []}]}
                  ]
                }
              },
              %{
                "startIndex" => 4,
                "endIndex" => 5,
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 4, "endIndex" => 5, "textRun" => %{"content" => "\n"}}
                  ]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createHeader" => _}]}

      # skeleton batch: ONLY the insertText — no style requests yet, since
      # a table-bearing segment's real positions aren't known until after
      # the table exists.
      assert_receive {:batch,
                      [
                        %{
                          "insertText" => %{
                            "location" => %{"segmentId" => "kix.new_header"},
                            "text" => ^marker_text
                          }
                        }
                      ]}

      assert_receive {:batch, table_skeleton_batch}

      assert Enum.any?(
               table_skeleton_batch,
               &match?(%{"insertTable" => %{"rows" => 1, "columns" => 1}}, &1)
             )

      assert Enum.all?(table_skeleton_batch, fn
               %{"deleteContentRange" => %{"range" => range}} ->
                 range["segmentId"] == "kix.new_header"

               %{"insertTable" => %{"location" => loc}} ->
                 loc["segmentId"] == "kix.new_header"
             end)

      # invariant: the only delete here is the marker's own (pre-table)
      # range — never a range reaching the table's own real startIndex
      # (1) — the API refuses that too (verified live 2026-09-23).
      refute Enum.any?(table_skeleton_batch, fn
               %{"deleteContentRange" => %{"range" => %{"endIndex" => 1}}} -> true
               _ -> false
             end)

      assert_receive {:batch, style_batch}
      refute_receive {:batch, _}

      # both spacer paragraphs get their (empty, unstyled) paragraph/text
      # style applied at their REAL post-split index — [0, 1) for the
      # "before" half, [4, 5) for the "after" half — never an analytical
      # offset.
      paragraph_style_ranges =
        style_batch
        |> Enum.filter(&Map.has_key?(&1, "updateParagraphStyle"))
        |> Enum.map(& &1["updateParagraphStyle"]["range"])

      assert %{"startIndex" => 0, "endIndex" => 1, "segmentId" => "kix.new_header"} in paragraph_style_ranges

      assert %{"startIndex" => 4, "endIndex" => 5, "segmentId" => "kix.new_header"} in paragraph_style_ranges

      insert_text = Enum.find(style_batch, &Map.has_key?(&1, "insertText"))
      # trailing newline stripped — the target's own pre-existing bare cell
      # already supplies it structurally (same convention as the body table
      # fill's `cell_fill_requests/4`, see `cell_text/1`'s doc). Index 3 =
      # the cell's real startIndex (2) + 1, read from doc_after_table_skeleton.
      assert insert_text["insertText"]["text"] == "Reg"
      assert insert_text["insertText"]["location"]["index"] == 3
      assert insert_text["insertText"]["location"]["segmentId"] == "kix.new_header"

      cell_style = Enum.find(style_batch, &Map.has_key?(&1, "updateTableCellStyle"))

      assert cell_style["updateTableCellStyle"]["tableRange"]["tableCellLocation"][
               "tableStartLocation"
             ] ==
               %{"index" => 1, "segmentId" => "kix.new_header"}
    end

    test "finds the table marker even when the segment's own re-fetch omits startIndex (proto3 zero)" do
      # Exact shape reported live 2026-09-23: a header whose only content is
      # a table, re-fetched right after the skeleton insert — Google's own
      # JSON gives the sole element (and its sole textRun) no `startIndex`
      # key at all, since a segment's index space starts at 0 and proto3
      # omits zero-valued fields. `find_table_marker_ranges/1`'s own filter
      # (built for the body, where a real textRun's `startIndex` is
      # practically never 0) requires the key present and would silently
      # find nothing here — this fixture pins that the segment-scoped
      # lookup doesn't share that blind spot.
      template_header_content = table_header_content()

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      {marker_text, _tables} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => template_header_content}
        })

      # No `startIndex` anywhere — matching the live report's exact shape
      # (there, `"endIndex" => 19` on both the block and its textRun; the
      # marker's own length varies with the template so this fixture just
      # keeps whatever `flatten_template_with_table_markers/1` produces).
      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => marker_text}}]}}
            ]
          }
        }
      }

      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 1, "content" => []}]}]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      # The bug returned {:error, :table_marker_count_mismatch} before
      # ever reaching insertTable — this must now succeed.
      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end

    test "keeps a cell's font-family style even when its only content is an empty, but styled, run" do
      # Verified live 2026-09-23 (segment_compare.exs structural diff): a
      # Leping-style header's signature cell holds one paragraph whose
      # sole textRun content is exactly "\n" — no visible text, since it's
      # left over after real text was once typed and then deleted — but
      # still carries `weightedFontFamily: Calibri`. `info.cell_runs` (fed
      # to `insertText`/base style) correctly drops this run: there's
      # nothing to insert. But the extra-style pass was zipping its raw
      # style list against that SAME (now empty) run list, so the style
      # silently vanished instead of landing on the cell's own
      # pre-existing terminal newline (`cell_run_extra_specs/1` fixes
      # this).
      styled_empty_cell_content = [
        %{
          "paragraph" => %{
            "elements" => [
              %{
                "textRun" => %{
                  "content" => "\n",
                  "textStyle" => %{
                    "weightedFontFamily" => %{"fontFamily" => "Calibri", "weight" => 400}
                  }
                }
              }
            ]
          }
        }
      ]

      template_header_content = [
        %{
          "table" => %{
            "rows" => 1,
            "columns" => 1,
            "tableRows" => [
              %{"tableCells" => [%{"content" => styled_empty_cell_content}]}
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      {marker_text, _tables} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => template_header_content}
        })

      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => marker_text}}]}}
            ]
          }
        }
      }

      # The cell stays empty (nothing to insert — the styled run reduces
      # to nothing but its own pre-existing terminal newline), so its
      # bare startIndex/content (no endIndex needed — `extract_table_cells/1`
      # only reads startIndex) is enough.
      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 1, "content" => []}]}]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createHeader" => _}]}
      assert_receive {:batch, _skeleton_insert_batch}
      assert_receive {:batch, _table_skeleton_batch}
      assert_receive {:batch, style_batch}
      refute_receive {:batch, _}

      font_family_request =
        Enum.find(style_batch, fn
          %{"updateTextStyle" => %{"textStyle" => %{"weightedFontFamily" => _}}} -> true
          _ -> false
        end)

      assert font_family_request,
             "expected a weightedFontFamily updateTextStyle request for the cell's " <>
               "empty-but-styled run, got: #{inspect(style_batch)}"

      # The cell's real insert_index is startIndex(1) + 1 = 2 — the range
      # covers exactly the cell's own pre-existing terminal newline (a
      # real 1-character range, never zero-width or analytically shifted).
      assert font_family_request["updateTextStyle"]["range"] == %{
               "startIndex" => 2,
               "endIndex" => 3,
               "segmentId" => "kix.new_header"
             }

      assert font_family_request["updateTextStyle"]["textStyle"]["weightedFontFamily"] == %{
               "fontFamily" => "Calibri",
               "weight" => 400
             }
    end

    test "replays a segment with two tables ([P, TABLE, P, TABLE, P])" do
      # Every other table test here has exactly one table; the whole
      # table-bearing pipeline (`table_bearing_skeleton_text/2`'s
      # newline-stripping, `table_skeleton_requests/2`'s per-marker
      # delete+insertTable, `match_segment_elements/2`'s pairing) is
      # generic over N tables but had never actually been run with N=2
      # even at the mock level (review recommendation, 2026-09-23).
      one_cell_table = fn cell_text ->
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
                          "elements" => [%{"textRun" => %{"content" => cell_text}}]
                        }
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
      end

      template_header_content = [
        text_paragraph("a\n"),
        one_cell_table.("X\n"),
        text_paragraph("b\n"),
        one_cell_table.("Y\n"),
        text_paragraph("c\n")
      ]

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      # Derived by hand from `table_bearing_skeleton_text/2`'s own rule: a
      # paragraph immediately before a table marker (or the template's
      # last block) never gets its own trailing "\n" inserted — "a\n" and
      # "b\n" both precede a table marker, "c\n" is the last block — so
      # all three strip to their bare letter and the markers (18 chars
      # each, single-digit marker index) are the only thing separating
      # them.
      expected_skeleton_text = "a __PKDC_TABLE_1__ b __PKDC_TABLE_2__ c"

      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [%{"textRun" => %{"content" => expected_skeleton_text}}]
                }
              }
            ]
          }
        }
      }

      # Freely chosen, self-consistent positions: `table_start`/paragraph
      # `startIndex` are read directly off each segment element here
      # (`table_info_to_entry/2`, `paragraph_element_requests/2`'s
      # `base_index`), not derived analytically from the skeleton batch —
      # any non-overlapping ascending set exercises the same code a real
      # re-fetch would.
      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "startIndex" => 0,
                "paragraph" => %{
                  "elements" => [%{"startIndex" => 0, "textRun" => %{"content" => "a\n"}}]
                }
              },
              %{
                "startIndex" => 2,
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 3, "content" => []}]}]
                }
              },
              %{
                "startIndex" => 6,
                "paragraph" => %{
                  "elements" => [%{"startIndex" => 6, "textRun" => %{"content" => "b\n"}}]
                }
              },
              %{
                "startIndex" => 8,
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 9, "content" => []}]}]
                }
              },
              %{
                "startIndex" => 12,
                "paragraph" => %{
                  "elements" => [%{"startIndex" => 12, "textRun" => %{"content" => "c\n"}}]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createHeader" => _}]}

      assert_receive {:batch,
                      [
                        %{
                          "insertText" => %{
                            "location" => %{"segmentId" => "kix.new_header"},
                            "text" => ^expected_skeleton_text
                          }
                        }
                      ]}

      assert_receive {:batch, table_skeleton_batch}

      insert_tables = Enum.filter(table_skeleton_batch, &Map.has_key?(&1, "insertTable"))
      assert length(insert_tables) == 2

      assert Enum.all?(table_skeleton_batch, fn
               %{"deleteContentRange" => %{"range" => range}} ->
                 range["segmentId"] == "kix.new_header"

               %{"insertTable" => %{"location" => loc}} ->
                 loc["segmentId"] == "kix.new_header"
             end)

      assert_receive {:batch, style_batch}
      refute_receive {:batch, _}

      paragraph_style_ranges =
        style_batch
        |> Enum.filter(&Map.has_key?(&1, "updateParagraphStyle"))
        |> Enum.map(& &1["updateParagraphStyle"]["range"])
        |> Enum.uniq()

      # all three paragraphs styled at their own real post-split index —
      # never an analytical shift.
      assert %{"startIndex" => 0, "endIndex" => 2, "segmentId" => "kix.new_header"} in paragraph_style_ranges

      assert %{"startIndex" => 6, "endIndex" => 8, "segmentId" => "kix.new_header"} in paragraph_style_ranges

      assert %{"startIndex" => 12, "endIndex" => 14, "segmentId" => "kix.new_header"} in paragraph_style_ranges

      table_starts =
        style_batch
        |> Enum.filter(&Map.has_key?(&1, "updateTableCellStyle"))
        |> Enum.map(fn req ->
          get_in(req, [
            "updateTableCellStyle",
            "tableRange",
            "tableCellLocation",
            "tableStartLocation",
            "index"
          ])
        end)
        |> Enum.uniq()

      # both tables got their own fill/style requests, at their own real
      # (not the other table's) startIndex.
      assert Enum.sort(table_starts) == [2, 8]

      # …and each table got its OWN template's content: "X" lands inside the
      # first table (2..6), "Y" inside the second (8..12). Pairing every
      # segment table with the first template table would still style both
      # startIndexes above, but fill both cells with "X" (review, 2026-09-23).
      cell_texts =
        for %{"insertText" => %{"text" => text, "location" => %{"index" => index}}} <-
              style_batch,
            do: {String.trim(text), index}

      assert [{"X", x_index}] = Enum.filter(cell_texts, &(elem(&1, 0) == "X"))
      assert [{"Y", y_index}] = Enum.filter(cell_texts, &(elem(&1, 0) == "Y"))
      assert x_index in 2..6
      assert y_index in 8..12
    end

    test "a segment element count mismatch fails loudly instead of guessing a pairing" do
      template_header_content = [text_paragraph("\n")] ++ table_header_content()

      template_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.tpl_header"},
        "headers" => %{"kix.tpl_header" => %{"content" => template_header_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.cur_header"},
        "headers" => %{"kix.cur_header" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      # The marker alone — see the previous test's comment on why.
      {marker_text, _tables} =
        GoogleDocsClient.flatten_template_with_table_markers(%{
          "body" => %{"content" => table_header_content()}
        })

      # No `startIndex` on the sole element — see the previous test's
      # comment on why this specific omission is the realistic shape.
      doc_after_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [%{"textRun" => %{"content" => marker_text}}]
                }
              }
            ]
          }
        }
      }

      # Only 1 element (the table) where the template — [P, TABLE] — has 2:
      # an unexpected shape `match_segment_elements/2` must reject rather
      # than pair up wrongly.
      doc_after_table_skeleton = %{
        "headers" => %{
          "kix.new_header" => %{
            "content" => [
              %{
                "startIndex" => 0,
                "table" => %{
                  "tableRows" => [%{"tableCells" => [%{"startIndex" => 1, "content" => []}]}]
                }
              }
            ]
          }
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
            0 -> {:ok, %{body: current_doc}}
            1 -> {:ok, %{body: doc_after_skeleton}}
            2 -> {:ok, %{body: doc_after_table_skeleton}}
          end
      end

      batch_fn = fn
        "target-id", [%{"createHeader" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createHeader" => %{"headerId" => "kix.new_header"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:error, :segment_shape_mismatch} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )
    end
  end

  describe "append_template/3 — extra style pass (border/font-family/underline/link)" do
    test "reproduces a rebuilt rule paragraph's border and a link run's font-family/underline/link" do
      rule_border = %{
        "color" => %{"color" => %{"rgbColor" => %{"red" => 0.45}}},
        "dashStyle" => "SOLID",
        "padding" => %{"magnitude" => 1, "unit" => "PT"},
        "width" => %{"magnitude" => 0.75, "unit" => "PT"}
      }

      template_footer_content = [
        %{
          "paragraph" => %{
            "elements" => [%{"textRun" => %{"content" => "\n"}}],
            "paragraphStyle" => %{"borderBottom" => rule_border}
          }
        },
        %{
          "paragraph" => %{
            "elements" => [
              %{
                "textRun" => %{
                  "content" => "Link\n",
                  "textStyle" => %{
                    "weightedFontFamily" => %{"fontFamily" => "Calibri", "weight" => 400},
                    "underline" => true,
                    "link" => %{"url" => "http://example.test"}
                  }
                }
              }
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "headers" => %{},
        "footers" => %{"kix.tpl_footer" => %{"content" => template_footer_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createFooter" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createFooter" => %{"footerId" => "kix.new_footer"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createFooter" => _}]}
      assert_receive {:batch, skeleton_batch}
      refute_receive {:batch, _}

      # "Link\n"'s own trailing newline is stripped — the fresh segment's
      # pre-existing one serves as its terminator (the Docs API refuses to
      # delete a segment's terminal newline).
      assert Enum.any?(
               skeleton_batch,
               &match?(
                 %{"insertText" => %{"location" => %{"index" => 0}, "text" => "\nLink"}},
                 &1
               )
             )

      border_request =
        Enum.find(skeleton_batch, fn
          %{"updateParagraphStyle" => %{"paragraphStyle" => %{"borderBottom" => _}}} -> true
          _ -> false
        end)

      assert border_request["updateParagraphStyle"]["range"] == %{
               "startIndex" => 0,
               "endIndex" => 1,
               "segmentId" => "kix.new_footer"
             }

      assert border_request["updateParagraphStyle"]["paragraphStyle"] == %{
               "borderBottom" => rule_border
             }

      assert border_request["updateParagraphStyle"]["fields"] == "borderBottom"

      link_request =
        Enum.find(skeleton_batch, fn
          %{"updateTextStyle" => %{"textStyle" => %{"link" => _}}} -> true
          _ -> false
        end)

      assert link_request["updateTextStyle"]["range"] == %{
               "startIndex" => 1,
               "endIndex" => 6,
               "segmentId" => "kix.new_footer"
             }

      assert link_request["updateTextStyle"]["textStyle"] == %{
               "weightedFontFamily" => %{"fontFamily" => "Calibri", "weight" => 400},
               "underline" => true,
               "link" => %{"url" => "http://example.test"}
             }

      # last block is a plain paragraph, and its own trailing newline was
      # never inserted — the segment's own pre-existing terminal newline
      # (now at index 6: 5 inserted chars + the 1 pre-existing) is never
      # targeted by a delete.
      refute_terminal_newline_delete!(skeleton_batch, 6)
    end

    test "a border with no explicit width magnitude is never sent (explicit-zero, not \"no border\")" do
      # `border_or_nil/2`'s own convention: a border whose `width` carries
      # no `magnitude` at all is the API's spelling for "explicitly no
      # line" (elsewhere a bare missing key means "unset", but not here —
      # sending it back verbatim would draw a border Google renders as
      # invisible-but-present). Mutating `border_or_nil/2` to send ANY
      # border regardless of magnitude passed every other test in this
      # file — this one pins the negative case specifically. `borderTop`
      # carries a real width on the SAME paragraph so the extra-style pass
      # is proven to still run, not just accidentally emit nothing.
      real_border = %{
        "color" => %{"color" => %{"rgbColor" => %{"red" => 0.2}}},
        "width" => %{"magnitude" => 1.0, "unit" => "PT"},
        "dashStyle" => "SOLID"
      }

      template_footer_content = [
        %{
          "paragraph" => %{
            "elements" => [%{"textRun" => %{"content" => "Text\n"}}],
            "paragraphStyle" => %{
              "borderTop" => real_border,
              "borderBottom" => %{"width" => %{"unit" => "PT"}}
            }
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "footers" => %{"kix.tpl_footer" => %{"content" => template_footer_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createFooter" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createFooter" => %{"footerId" => "kix.new_footer"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createFooter" => _}]}
      assert_receive {:batch, skeleton_batch}
      refute_receive {:batch, _}

      border_request =
        Enum.find(skeleton_batch, fn
          %{"updateParagraphStyle" => %{"fields" => fields}} ->
            String.contains?(fields, "border")

          _ ->
            false
        end)

      assert border_request, "expected an extra-style border request for borderTop"
      assert border_request["updateParagraphStyle"]["fields"] == "borderTop"

      assert border_request["updateParagraphStyle"]["paragraphStyle"] == %{
               "borderTop" => real_border
             }

      refute Map.has_key?(
               border_request["updateParagraphStyle"]["paragraphStyle"],
               "borderBottom"
             )
    end

    test "a native horizontalRule replays as a forced 4pt/6pt-spaceBelow bordered paragraph" do
      template_footer_content = [
        %{
          "paragraph" => %{
            "elements" => [
              %{
                "horizontalRule" => %{
                  "textStyle" => %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}}
                }
              },
              %{
                "textRun" => %{
                  "content" => "\n",
                  "textStyle" => %{"fontSize" => %{"magnitude" => 9.5, "unit" => "PT"}}
                }
              }
            ]
          }
        }
      ]

      template_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.tpl_footer"},
        "footers" => %{"kix.tpl_footer" => %{"content" => template_footer_content}},
        "body" => %{"content" => [text_paragraph("Body\n")]}
      }

      current_doc = %{
        "documentStyle" => %{"defaultFooterId" => "kix.cur_footer"},
        "footers" => %{"kix.cur_footer" => %{"content" => [text_paragraph("Plain\n")]}},
        "body" => target_body()
      }

      get_fn = fn
        "template-id" -> {:ok, %{body: template_doc}}
        "target-id" -> {:ok, %{body: current_doc}}
      end

      batch_fn = fn
        "target-id", [%{"createFooter" => _}] = requests ->
          send(self(), {:batch, requests})
          {:ok, %{body: %{"replies" => [%{"createFooter" => %{"footerId" => "kix.new_footer"}}]}}}

        "target-id", requests ->
          send(self(), {:batch, requests})
          {:ok, %{}}
      end

      assert {:ok, {11, _}} =
               GoogleDocsClient.append_template("target-id", "template-id",
                 get_fn: get_fn,
                 batch_fn: batch_fn
               )

      assert_receive {:batch, [%{insertSectionBreak: %{}} | _]}
      assert_receive {:batch, [%{"createFooter" => _}]}
      assert_receive {:batch, skeleton_batch}
      refute_receive {:batch, _}

      border_request =
        Enum.find(skeleton_batch, fn
          %{"updateParagraphStyle" => %{"paragraphStyle" => %{"borderBottom" => _}}} -> true
          _ -> false
        end)

      assert border_request["updateParagraphStyle"]["paragraphStyle"]["borderBottom"]["width"] ==
               %{"magnitude" => 0.75, "unit" => "PT"}

      assert border_request["updateParagraphStyle"]["paragraphStyle"]["spaceBelow"] ==
               %{"magnitude" => 6.0, "unit" => "PT"}

      font_size_requests =
        Enum.filter(skeleton_batch, fn
          %{"updateTextStyle" => %{"textStyle" => %{"fontSize" => _}}} -> true
          _ -> false
        end)

      # the run's own fontSize is ALSO captured by the shared narrow pass
      # (9.5pt, its own request earlier in the batch) — the extra pass's
      # own request, LAST in the batch, overrides it to the forced 4pt.
      assert List.last(font_size_requests)["updateTextStyle"]["textStyle"]["fontSize"] ==
               %{"magnitude" => 4.0, "unit" => "PT"}
    end
  end

  describe "header_footer_owners/3" do
    defp section(position, values),
      do: %{position: position, variable_values: values, image_params: %{}}

    test "every section sharing the one original segment owns it via the lowest position (regression)" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home", "defaultFooterId" => "kix.foot"},
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}},
            %{"startIndex" => 5, "sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}}
          ]
        }
      }

      sections = [section(0, %{"a" => "A"}), section(1, %{"a" => "should-not-win"})]
      ranges = %{0 => {1, 5}, 1 => {6, 10}}

      owners = GoogleDocsClient.header_footer_owners(doc, sections, ranges)

      assert owners["kix.home"] == section(0, %{"a" => "A"})
      assert owners["kix.foot"] == section(0, %{"a" => "A"})
    end

    test "a section that creates its own header/footer owns that segment id" do
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home"},
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{"paragraph" => %{}},
            %{
              "startIndex" => 5,
              "sectionBreak" => %{"sectionStyle" => %{"defaultHeaderId" => "kix.own"}}
            },
            %{"paragraph" => %{}}
          ]
        }
      }

      sections = [section(0, %{"title" => "Home"}), section(1, %{"title" => "Section 1"})]
      ranges = %{0 => {1, 5}, 1 => {6, 10}}

      owners = GoogleDocsClient.header_footer_owners(doc, sections, ranges)

      assert owners["kix.home"] == section(0, %{"title" => "Home"})
      assert owners["kix.own"] == section(1, %{"title" => "Section 1"})
    end
  end
end
