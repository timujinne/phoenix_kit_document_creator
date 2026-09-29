defmodule PhoenixKitDocumentCreator.Integration.GoogleDocsClientImageFitTest do
  @moduledoc """
  Coverage for the `fit: "page"` image sizing path and the box-width fix
  (`apply_image_fills/3` reading each slot's own section's `section_boxes/1`
  box instead of the whole document's `content_width_pt/1`) — driven
  end-to-end through `substitute_all_sections/3` the same way the existing
  blank-value / section-shift tests in `google_docs_client_http_test.exs`
  are, so the assertions read off the real `insertInlineImage` request the
  library would send.
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  # A default-style (11pt / 115% lineSpacing) line's height, including the
  # @font_leading (1.22) multiplier `estimate_paragraph_height_pt/1` applies
  # — used both for a preceding body paragraph's reserve and for
  # `page_fit_trailing_line_pt` (one such line, applied only to the image
  # that renders last in a fit=page slot — see
  # `page_fit_image_list_inserts/4`'s doc).
  @default_line_pt 11.0 * 1.15 * 1.22

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()
    StubIntegrations.connected!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  # A4-shaped page, portrait: 595.28 x 841.89pt, default 72pt margins on
  # every side → content box 451.28 x 697.89pt.
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

  defp para(start_index, text) do
    end_index = start_index + String.length(text)

    %{
      "startIndex" => start_index,
      "endIndex" => end_index,
      "paragraph" => %{
        "elements" => [
          %{
            "startIndex" => start_index,
            "endIndex" => end_index,
            "textRun" => %{"content" => text}
          }
        ]
      }
    }
  end

  defp stub_doc_and_batch(doc) do
    StubIntegrations.stub_request(:get, "/v1/documents/fit-doc", {:ok, %{status: 200, body: doc}})

    StubIntegrations.stub_request(
      :post,
      ":batchUpdate",
      {:ok, %{status: 200, body: %{"replies" => []}}}
    )
  end

  defp image_list_slot(overrides) do
    Map.merge(
      %{
        "kind" => "image_list",
        "columns" => 1,
        "media" => [
          %{"uri" => "https://example.test/a.png", "width_px" => 800, "height_px" => 600}
        ]
      },
      overrides
    )
  end

  defp insert_inline_image_requests do
    for {:post, url, opts} <- StubIntegrations.recorded_requests(),
        String.contains?(url, ":batchUpdate"),
        request <- opts[:json].requests,
        Map.has_key?(request, :insertInlineImage),
        do: request
  end

  # Every request across every recorded :batchUpdate call, in call order —
  # unlike `insert_inline_image_requests/0`, this doesn't filter by key
  # shape, so it also picks up Phase 2's string-keyed requests
  # (`"insertInlineImage"`, `"updateTableCellStyle"`) that a columns >= 2
  # slot goes through.
  defp all_batch_requests do
    for {:post, url, opts} <- StubIntegrations.recorded_requests(),
        String.contains?(url, ":batchUpdate"),
        request <- opts[:json].requests,
        do: request
  end

  # A table element shaped like `collect_tables/1`'s output
  # (`%{"startIndex" => _, "table" => %{"rows" => _, "columns" => _,
  # "tableRows" => [...]}}`), with `rows * columns` cells laid out
  # left-to-right, top-to-bottom, each cell's own startIndex spaced 20
  # apart starting at `base_cell_start` — enough for
  # `extract_table_cells/1` to compute distinct insert indices per cell.
  defp grid_table_block(start_index, rows, columns, base_cell_start) do
    cell_starts =
      for r <- 0..(rows - 1), c <- 0..(columns - 1) do
        base_cell_start + (r * columns + c) * 20
      end

    table_rows =
      cell_starts
      |> Enum.chunk_every(columns)
      |> Enum.map(fn row_starts ->
        %{"tableCells" => Enum.map(row_starts, &%{"startIndex" => &1, "content" => []})}
      end)

    %{
      "startIndex" => start_index,
      "endIndex" => start_index + 100,
      "table" => %{"rows" => rows, "columns" => columns, "tableRows" => table_rows}
    }
  end

  describe "box-width fix — image_list columns=1, fit: \"width\" (default)" do
    test "uses the LANDSCAPE section's own box width, not the (portrait) document's" do
      doc = %{
        "documentStyle" => Map.put(doc_style(), "flipPageOrientation", true),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => image_list_slot(%{})}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])

      # 841.89 - 72 - 72 (the flipped/landscape box), not 595.28 - 144.
      assert_in_delta width, 697.89, 0.01
    end

    test "in a 2-section document, a slot in section 2 gets section 2's box, not section 1's" do
      # Section 1: portrait, no flip. Section 2: landscape via its own
      # sectionStyle.flipPageOrientation (doc-level flip stays false).
      # The image tag's textRun starts EXACTLY at section 2's sectionBreak
      # startIndex (3) — the boundary `box_for_index/2` has to get right:
      # box1 is [0, 3), box2 is [3, 25). A `<` → `<=` mutation on
      # box_for_index's end-index check would make box1 ALSO match index 3
      # (and, since boxes are tried in order, win), picking the wrong
      # (portrait) box — this test fails under that mutation (verified
      # manually before committing).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            %{
              "startIndex" => 1,
              "endIndex" => 3,
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "endIndex" => 3, "textRun" => %{"content" => "x\n"}}
                ]
              }
            },
            section_break(3, %{"flipPageOrientation" => true}),
            %{
              "startIndex" => 3,
              "endIndex" => 25,
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 3,
                    "endIndex" => 25,
                    "textRun" => %{"content" => "{{ images: photos }}\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      stub_doc_and_batch(doc)

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => image_list_slot(%{})}}
      ]

      ranges = %{0 => {1, 25}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # Section 2's (landscape) box: 841.89 - 144 wide, 595.28 - 144 tall —
      # NOT section 1's (portrait) 451.28 x 697.89. Height follows the
      # slot's default media aspect (800x600 — see image_list_slot/1),
      # scaled from the section-2 width; scale_height/3 rounds to an
      # integer PT value, hence the wider delta.
      assert_in_delta width, 697.89, 0.01
      assert_in_delta height, 697.89 * 600 / 800, 1.0
    end
  end

  describe "fit: \"page\" — scale = min(box_w / w_px, avail_h / h_px)" do
    test "a horizontal image is bound by width" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 1600, "height_px" => 900}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # box_w = 451.28pt; no header/footer content → body_top_pt = marginTop
      # (72), body_bottom_pt = pageH - marginBottom (841.89 - 72 = 769.89).
      # avail_h = 769.89 - 72 - @default_line_pt (trailing line) - 8.0
      # (default safety, no preceding paragraphs).
      # scale = min(451.28/1600, avail_h/900) → width wins.
      avail_h = 769.89 - 72 - @default_line_pt - 8.0
      assert_in_delta width, 451.28, 0.01
      assert_in_delta height, 900 * (451.28 / 1600), 0.01
      assert height < avail_h
    end

    test "a vertical image is bound by height" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 900, "height_px" => 1600}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])
      # See the horizontal-image test above for the avail_h derivation.
      avail_h = 769.89 - 72 - @default_line_pt - 8.0

      assert_in_delta height, avail_h, 0.01
      assert width < 451.28
    end

    test "reserve is the estimated height of the section's 3 preceding paragraphs, plus the safety margin" do
      # 3 empty (default-style) paragraphs before the slot: each contributes
      # @default_line_pt → 3 * @default_line_pt total. No header content, so
      # body_top_pt = marginTop (72); the paragraphs push the first image's
      # start to marginTop + 3 * @default_line_pt (> body_top_pt, so it wins
      # the `max`). avail_h = body_bottom_pt (769.89) - that start -
      # @default_line_pt (trailing line) - 8.0 (default safety).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "\n"),
            para(3, "\n"),
            para(4, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      # Extreme aspect ratio so the fit is unambiguously height-bound —
      # the resulting height pins down avail_h (and thus the reserve).
      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 27}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      expected_avail_h = 769.89 - (72 + 3 * @default_line_pt) - @default_line_pt - 8.0
      assert_in_delta height, expected_avail_h, 0.01
    end

    test "a table ahead of the slot counts toward the reserve at its estimated height" do
      # A 2-row, 1-column table of empty cells: each row is one default line
      # plus the 5pt default top and bottom cell padding.
      cell = %{"content" => [para(2, "\n")]}

      table = %{
        "startIndex" => 1,
        "endIndex" => 8,
        "table" => %{
          "tableRows" => [%{"tableCells" => [cell]}, %{"tableCells" => [cell]}]
        }
      }

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [section_break(0), table, para(8, "{{ images: photos }}\n")]
        }
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [%{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}]

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, %{0 => {1, 30}})

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      table_pt = 2 * (@default_line_pt + 10.0)
      expected_avail_h = 769.89 - (72 + table_pt) - @default_line_pt - 8.0
      assert_in_delta height, expected_avail_h, 0.01
    end

    test "two images in one fit=page slot: safety applies to BOTH, paragraphs-reserve only to the first" do
      # One preceding paragraph (@default_line_pt) before the slot. First
      # (topmost, rendered-order) image loses safety AND the paragraph
      # reserve, but NOT the trailing line (it isn't the section's last
      # image — another image follows it, not the terminal paragraph);
      # second (last-rendered) image loses safety AND the trailing line, but
      # not the paragraph reserve — see page_fit_image_list_inserts/4's doc.
      # A regression to "safety only for the first image" (the pre-4ea345b
      # behavior) would give the second image the full box height instead,
      # failing the second assertion below (verified by hand against that
      # mutation before committing).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      # Extreme aspect ratio (both images) so the fit is unambiguously
      # height-bound — the resulting height pins down each image's avail_h.
      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [
            %{"uri" => "a", "width_px" => 100, "height_px" => 1000},
            %{"uri" => "b", "width_px" => 100, "height_px" => 1000}
          ]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 24}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      first_height = get_in(by_uri["a"], [:insertInlineImage, :objectSize, :height, :magnitude])
      second_height = get_in(by_uri["b"], [:insertInlineImage, :objectSize, :height, :magnitude])

      # First (uri "a", first rendered, NOT the section's last image): no
      # trailing line, start = max(body_top_pt=72, marginTop + reserve).
      first_start = max(72, 72 + @default_line_pt)
      expected_first = 769.89 - first_start - 8.0
      # Second (uri "b", the section's LAST image): starts at body_top_pt
      # (72), loses the trailing line — NOT the full box height.
      expected_second = 769.89 - 72 - @default_line_pt - 8.0

      assert_in_delta first_height, expected_first, 0.01
      assert_in_delta second_height, expected_second, 0.01
      assert second_height < 697.89
    end

    test "the trailing line is subtracted only from the section's LAST image, not every image" do
      # 3 images, no header/footer, no preceding paragraphs — every image
      # starts at the same body_top_pt (72), isolating the trailing-line
      # effect: the first two (topmost, rendered-order — i.e. NOT the
      # section's last image) are immediately followed by another image, not
      # the terminal paragraph, so they should NOT lose the trailing line;
      # only the third (last-rendered) should. A `trailing applied to every
      # image` regression would make all three come out the same (smaller)
      # height instead — this test fails under that mutation (verified by
      # hand before committing).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [
            %{"uri" => "a", "width_px" => 100, "height_px" => 1000},
            %{"uri" => "b", "width_px" => 100, "height_px" => 1000},
            %{"uri" => "c", "width_px" => 100, "height_px" => 1000}
          ]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      height_a = get_in(by_uri["a"], [:insertInlineImage, :objectSize, :height, :magnitude])
      height_b = get_in(by_uri["b"], [:insertInlineImage, :objectSize, :height, :magnitude])
      height_c = get_in(by_uri["c"], [:insertInlineImage, :objectSize, :height, :magnitude])

      no_trailing = 769.89 - 72 - 8.0
      with_trailing = 769.89 - 72 - @default_line_pt - 8.0

      # "a" (first rendered) and "b" (middle) both start a fresh page and are
      # followed by another image — no trailing line.
      assert_in_delta height_a, no_trailing, 0.01
      assert_in_delta height_b, no_trailing, 0.01
      # "c" (last rendered, the section's actual last image) is followed by
      # the terminal paragraph — loses the trailing line.
      assert_in_delta height_c, with_trailing, 0.01
      assert height_c < height_a
    end

    test "a header taller than its margin wins the max() against a small paragraphs-reserve — not their sum" do
      # Header extent: 6 default-style lines (6 * @default_line_pt) +
      # marginHeader (36, default) — comfortably over marginTop + the one
      # preceding body paragraph's reserve (72 + @default_line_pt).
      # body_top_pt should win the `max`. A `max` → `+` mutation on the first
      # image's start would SUM body_top_pt and (marginTop + reserve) instead
      # of taking the larger one, badly undersizing avail_h — this test fails
      # under that mutation (verified by hand before committing).
      header_lines =
        for _ <- 1..6,
            do: %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "\n"}}]}}

      doc = %{
        "documentStyle" => Map.merge(doc_style(), %{"defaultHeaderId" => "h1"}),
        "headers" => %{"h1" => %{"content" => header_lines}},
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "\n"),
            para(2, "{{ images: photos }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 24}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # body_top_pt = max(72, 36 + 6 * @default_line_pt) — the header wins.
      # marginTop + paragraphs_reserve (72 + @default_line_pt) is smaller,
      # loses the max(). start = body_top_pt (NOT their sum).
      body_top_pt = 36.0 + 6 * @default_line_pt
      expected_avail_h = 769.89 - body_top_pt - @default_line_pt - 8.0

      assert_in_delta height, expected_avail_h, 0.01
    end
  end

  describe "fit=page scope guards — fall back to fit=width and warn" do
    test "columns >= 2 is out of scope" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "columns" => 2,
          "media" => [%{"uri" => "a"}, %{"uri" => "b"}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"photos\""
      assert log =~ "columns >= 2 is out of scope"

      table_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            Map.has_key?(request, "insertTable"),
            do: request

      assert [_] = table_requests
    end

    test "a slot inside a table cell is out of scope" do
      # The tag lives inside a pre-existing table cell in the template's own
      # content (not one this library creates for a columns >= 2 slot).
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            %{
              "startIndex" => 1,
              "endIndex" => 60,
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "startIndex" => 3,
                        "content" => [para(4, "{{ images: photos }}\n")]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      stub_doc_and_batch(doc)

      slot = image_list_slot(%{"fit" => "page"})

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {0, 60}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"photos\""
      assert log =~ "sits inside a table cell"

      # No explicit sectionBreak → section_boxes/1 falls back to a single
      # box for the whole body, still using documentStyle's own pageSize —
      # confirms the plain fit: "width" path ran, not the page-fit scale
      # formula (which would have been height-bound and much narrower).
      [insert] = insert_inline_image_requests()
      width = get_in(insert, [:insertInlineImage, :objectSize, :width, :magnitude])
      assert_in_delta width, 451.28, 0.01
    end

    test "a second fit: \"page\" slot in the same section falls back to width" do
      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para(1, "{{ images: first }}\n"),
            para(22, "{{ images: second }}\n")
          ]
        }
      }

      stub_doc_and_batch(doc)

      first_slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "a", "width_px" => 900, "height_px" => 1600}]
        })

      second_slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "b", "width_px" => 900, "height_px" => 1600}]
        })

      sections = [
        %{
          position: 0,
          variable_values: %{},
          image_params: %{"first" => first_slot, "second" => second_slot}
        }
      ]

      ranges = %{0 => {1, 43}}

      log =
        capture_log(fn ->
          assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)
        end)

      assert log =~ "fit=page ignored for image slot \"second\""
      assert log =~ "already has a fit=page slot"

      inserts = insert_inline_image_requests()
      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      first_height = get_in(by_uri["a"], [:insertInlineImage, :objectSize, :height, :magnitude])
      second_width = get_in(by_uri["b"], [:insertInlineImage, :objectSize, :width, :magnitude])

      # First slot got the real page-fit treatment (height-bound, < full box).
      assert first_height < 697.89
      # Second slot fell back to fit: "width" — full box width.
      assert_in_delta second_width, 451.28, 0.01
    end
  end

  describe "page_fit_safety_pt/0 — host-tunable via config" do
    setup do
      previous = Application.get_env(:phoenix_kit_document_creator, :page_fit_safety_pt)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_document_creator, :page_fit_safety_pt, previous),
          else: Application.delete_env(:phoenix_kit_document_creator, :page_fit_safety_pt)
      end)

      :ok
    end

    test "a non-numeric or negative override falls back to the 8.0 default" do
      for bad <- ["12", nil, -5] do
        Application.put_env(:phoenix_kit_document_creator, :page_fit_safety_pt, bad)
        assert GoogleDocsClient.page_fit_safety_pt() == 8.0
      end
    end

    test "an env override changes the reserve applied to a fit: \"page\" image" do
      Application.put_env(:phoenix_kit_document_creator, :page_fit_safety_pt, 200.0)

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para(1, "{{ images: photos }}\n")]}
      }

      stub_doc_and_batch(doc)

      slot =
        image_list_slot(%{
          "fit" => "page",
          "media" => [%{"uri" => "u", "width_px" => 100, "height_px" => 1000}]
        })

      sections = [
        %{position: 0, variable_values: %{}, image_params: %{"photos" => slot}}
      ]

      ranges = %{0 => {1, 23}}

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      [insert] = insert_inline_image_requests()
      height = get_in(insert, [:insertInlineImage, :objectSize, :height, :magnitude])

      # avail_h = 769.89 (body_bottom_pt) - 72 (start) - @default_line_pt
      # (trailing line) - 200.0 (overridden safety, no preceding paragraphs).
      assert_in_delta height, 769.89 - 72 - @default_line_pt - 200.0, 0.01
    end
  end

  describe "duplicate slot names across sections (Block H regression)" do
    # A composed document where more than one section uses the SAME image
    # slot name — the real case: an image-grid template and its
    # per-orientation twin both render `{{ images: joonised }}`. Before this
    # fix, `apply_image_fills/3` keyed its fills/ranges map by name alone,
    # so whichever section's fill entered the map last silently won every
    # occurrence of that name; every earlier section's placeholder was
    # filtered out of `filtered_ranges` (its start_index never fell inside
    # the one surviving range) and never substituted at all — no delete, no
    # insert, the raw `{{ images: ... }}` text left behind (later stripped
    # as dead markup by cleanup, leaving that page with no photo).
    defp shared_slot_doc(count) do
      tag_text = "{{ images: photos }}\n"

      {paragraphs, _next} =
        Enum.map_reduce(1..count, 1, fn _, start ->
          {para(start, tag_text), start + String.length(tag_text)}
        end)

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0) | paragraphs]}
      }

      ranges =
        paragraphs
        |> Enum.with_index()
        |> Map.new(fn {p, i} -> {i, {p["startIndex"], p["endIndex"]}} end)

      {doc, ranges}
    end

    test "two sections share a slot name: each keeps its own image, not the other's" do
      {doc, ranges} = shared_slot_doc(2)
      stub_doc_and_batch(doc)

      sections = [
        %{
          position: 0,
          variable_values: %{},
          image_params: %{
            "photos" => image_list_slot(%{"media" => [%{"uri" => "section0.png"}]})
          }
        },
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" => image_list_slot(%{"media" => [%{"uri" => "section1.png"}]})
          }
        }
      ]

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      assert length(inserts) == 2, "expected one image per section, got #{length(inserts)}"

      by_index =
        Map.new(inserts, fn req ->
          {req.insertInlineImage.location.index, req.insertInlineImage.uri}
        end)

      {s0, _} = ranges[0]
      {s1, _} = ranges[1]
      assert by_index[s0] == "section0.png"
      assert by_index[s1] == "section1.png"
    end

    test "three sections share a slot name: each resolves in document order, none lost" do
      {doc, ranges} = shared_slot_doc(3)
      stub_doc_and_batch(doc)

      sections =
        for i <- 0..2 do
          %{
            position: i,
            variable_values: %{},
            image_params: %{
              "photos" => image_list_slot(%{"media" => [%{"uri" => "section#{i}.png"}]})
            }
          }
        end

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      assert length(inserts) == 3

      by_index =
        Map.new(inserts, fn req ->
          {req.insertInlineImage.location.index, req.insertInlineImage.uri}
        end)

      for i <- 0..2 do
        {s, _} = ranges[i]
        assert by_index[s] == "section#{i}.png"
      end
    end

    test "duplicate slot name with fit: \"page\": each section keeps its own image and its own sizing" do
      # Two Docs sections (not just two app-level sections sharing one Docs
      # section, as `shared_slot_doc/1` builds) — the real scenario: an
      # orientation twin pair each has its own `flipPageOrientation`, so
      # each occurrence sits in its own Docs section and legitimately
      # qualifies for its own fit=page slot (fit=page is capped at one
      # PER DOCS SECTION, a separate, intentional rule unrelated to this
      # fix — sharing one Docs section here would make the second
      # occurrence fall back to fit=width and weaken the assertion below).
      tag_text = "{{ images: photos }}\n"
      para1 = para(1, tag_text)
      para2 = para(para1["endIndex"], tag_text)

      doc = %{
        "documentStyle" => doc_style(),
        "body" => %{
          "content" => [
            section_break(0),
            para1,
            section_break(para1["endIndex"]),
            para2
          ]
        }
      }

      ranges = %{
        0 => {para1["startIndex"], para1["endIndex"]},
        1 => {para2["startIndex"], para2["endIndex"]}
      }

      stub_doc_and_batch(doc)

      sections = [
        %{
          position: 0,
          variable_values: %{},
          image_params: %{
            "photos" =>
              image_list_slot(%{
                "fit" => "page",
                "media" => [%{"uri" => "section0.png", "width_px" => 1600, "height_px" => 900}]
              })
          }
        },
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" =>
              image_list_slot(%{
                "fit" => "page",
                "media" => [%{"uri" => "section1.png", "width_px" => 900, "height_px" => 1600}]
              })
          }
        }
      ]

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      inserts = insert_inline_image_requests()
      assert length(inserts) == 2

      by_uri = Map.new(inserts, fn req -> {req.insertInlineImage.uri, req} end)

      width0 =
        get_in(by_uri["section0.png"], [:insertInlineImage, :objectSize, :width, :magnitude])

      height0 =
        get_in(by_uri["section0.png"], [:insertInlineImage, :objectSize, :height, :magnitude])

      width1 =
        get_in(by_uri["section1.png"], [:insertInlineImage, :objectSize, :width, :magnitude])

      height1 =
        get_in(by_uri["section1.png"], [:insertInlineImage, :objectSize, :height, :magnitude])

      # section0's media is 16:9 (wider than tall), section1's is 9:16
      # (taller than wide) — the rendered aspect must follow, proving each
      # section resolved to its OWN media rather than both ending up with
      # whichever section's fill won the old name-keyed collision (which
      # would give both images the same aspect).
      assert width0 > height0, "section0's 16:9 image should render wider than tall"
      assert height1 > width1, "section1's 9:16 image should render taller than wide"
    end

    test "duplicate slot name with columns >= 2: each section's grid gets its own images, own cells, own border request" do
      # A grid slot (columns >= 2) goes through Phase 1 (insertTable) and
      # Phase 2 (re-fetch, then fill_matched_tables — see
      # build_phase2_requests/5). Phase 2 needs a POST-insertTable document
      # to find the new tables in, so `get_document` is stubbed with a
      # counter: the first two GETs (text phase, then image phase) see the
      # placeholder-only document; the third (Phase 2's re-fetch) sees the
      # two tables Phase 1 would have created.
      tag_text = "{{ images: photos }}\n"
      para1 = para(1, tag_text)
      para2 = para(para1["endIndex"], tag_text)

      doc_before_tables = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), para1, para2]}
      }

      table0 = grid_table_block(10, 1, 2, 20)
      table1 = grid_table_block(200, 1, 2, 220)

      doc_after_tables = %{
        "documentStyle" => doc_style(),
        "body" => %{"content" => [section_break(0), table0, table1]}
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      get_response = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        body = if n < 2, do: doc_before_tables, else: doc_after_tables
        {:ok, %{status: 200, body: body}}
      end

      StubIntegrations.stub_request(:get, "/v1/documents/fit-doc", get_response)

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{
          position: 0,
          variable_values: %{},
          image_params: %{
            "photos" =>
              image_list_slot(%{
                "columns" => 2,
                "media" => [%{"uri" => "s0-a"}, %{"uri" => "s0-b"}]
              })
          }
        },
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" =>
              image_list_slot(%{
                "columns" => 2,
                "media" => [%{"uri" => "s1-a"}, %{"uri" => "s1-b"}]
              })
          }
        }
      ]

      ranges = %{
        0 => {para1["startIndex"], para1["endIndex"]},
        1 => {para2["startIndex"], para2["endIndex"]}
      }

      assert :ok = GoogleDocsClient.substitute_all_sections("fit-doc", sections, ranges)

      requests = all_batch_requests()

      insert_table_reqs = Enum.filter(requests, &Map.has_key?(&1, "insertTable"))
      assert length(insert_table_reqs) == 2, "expected one insertTable per section"

      assert Enum.all?(insert_table_reqs, fn r ->
               match?(%{"insertTable" => %{"rows" => 1, "columns" => 2}}, r)
             end)

      border_reqs = Enum.filter(requests, &Map.has_key?(&1, "updateTableCellStyle"))

      assert length(border_reqs) == 2,
             "expected one border-clearing request per grid table (Block E)"

      border_starts =
        Enum.map(border_reqs, fn r ->
          get_in(r, [
            "updateTableCellStyle",
            "tableRange",
            "tableCellLocation",
            "tableStartLocation",
            "index"
          ])
        end)

      assert Enum.sort(border_starts) == [10, 200],
             "each grid keeps its own tableStartLocation"

      # Phase 2's own insertInlineImage requests are string-keyed (distinct
      # from Phase 1's atom-keyed inline path, which columns >= 2 never uses).
      fill_reqs = Enum.filter(requests, &Map.has_key?(&1, "insertInlineImage"))
      assert length(fill_reqs) == 4, "2 cells per table x 2 tables"

      by_index =
        Map.new(fill_reqs, fn r ->
          {get_in(r, ["insertInlineImage", "location", "index"]),
           get_in(r, ["insertInlineImage", "uri"])}
        end)

      # table0's cells (startIndex 20, 40 -> insert index 21, 41) get
      # section 0's media; table1's cells (220, 240 -> 221, 241) get
      # section 1's — never swapped, and never both landing on one table.
      assert Enum.sort(Enum.map([by_index[21], by_index[41]], & &1)) == ["s0-a", "s0-b"]
      assert Enum.sort(Enum.map([by_index[221], by_index[241]], & &1)) == ["s1-a", "s1-b"]

      # The later table is filled first, so no insert shifts a cell index
      # another insert in the same batch still relies on.
      fill_indices = Enum.map(fill_reqs, &get_in(&1, ["insertInlineImage", "location", "index"]))
      assert fill_indices == [241, 221, 41, 21]

      # Every border request precedes every Phase 2 image insert (Block E's
      # ordering guarantee, re-checked here through the real pipeline).
      border_positions =
        for {r, i} <- Enum.with_index(requests), Map.has_key?(r, "updateTableCellStyle"), do: i

      fill_positions =
        for {r, i} <- Enum.with_index(requests), Map.has_key?(r, "insertInlineImage"), do: i

      assert Enum.max(border_positions) < Enum.min(fill_positions)
    end
  end
end
