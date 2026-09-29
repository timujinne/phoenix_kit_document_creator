defmodule PhoenixKitDocumentCreator.GoogleDocsClient.SegmentReplay do
  @moduledoc """
  Pure helpers behind "give an appended section its own header/footer"
  (`GoogleDocsClient.append_template/3`'s header/footer step): a structural
  fingerprint to decide whether a section even needs its own segment, and
  the request builders that replay a template's header/footer content into
  a freshly created one.

  The Docs API has no "copy this header to that document" primitive — a
  template's header/footer is walked and rebuilt from scratch, the same
  approach proven live 2026-09-21 by a one-off script that rebuilt the
  house header/footer (not shipped in this repo), generalized here into the library: paragraphs (`insertText` + paragraph
  style, then text style), tables (`insertTable` + column widths + cell
  style + cell fill), inline images (`insertInlineImage`, source size and
  URI verbatim — no rescale to the target's own column width; the 2026-09-23
  live check found Docs accepts this).

  Every function here is pure — no `get_fn`/`batch_fn`, no Docs API calls.
  `GoogleDocsClient` owns the multi-round-trip orchestration (create the
  segment, insert a skeleton, re-fetch, fill tables) the same way it already
  splits `flatten_template_with_table_markers_and_styles/1` (pure) from
  `finish_append_template/6` (orchestration) for body content.

  ## Why the fingerprint drops so much

  Three real "home" header/footer pairs (Hinnapakkumine, Leping, Joonised
  (tootmine)) were fetched live 2026-09-23 to calibrate this — they're
  meant to look identical, having all been rebuilt from the same model by
  the 2026-09-21 script, but their JSON differs in ways that carry no visual
  meaning:

    * table column width and inline image size scale with each template's
      own content width (Hinnapakkumine's logo table: 261pt columns / a
      236x46pt logo; Leping/Joonised's: 225.6pt columns / a 215x42pt logo,
      same ~5.13 aspect ratio) — comparing these directly would flag every
      correctly-scaled home header as "different".
    * a cell's `paragraphStyle` carries a different set of explicit-zero
      fields depending on which tool last touched it (Leping/Joonised's
      image-cell paragraph has explicit-zero `indentStart`/`spaceBelow`/...
      that Hinnapakkumine's never had; Joonised's footer table cells lack
      `paddingTop`/etc. entirely where Hinnapakkumine's carry an explicit
      5pt) — none of this changes how the header renders.
    * the footer's divider line is a native `horizontalRule` element in
      Hinnapakkumine (never rebuilt) but a thin bordered paragraph in
      Leping/Joonised (the rebuild script's stand-in, since `horizontalRule`
      can't be inserted via the API) — structurally unrelated shapes that
      must still compare equal.

  So the fingerprint keeps: block shape (paragraph / table / rule),
  paragraph `alignment`, per-run `bold`/`italic`/rounded `fontSize`, raw
  text (including untouched `{{placeholder}}` syntax — substitution runs
  after every section is appended), table `rows`/`columns` and per-cell
  content, and an inline image's rounded aspect ratio. It drops table
  column widths, image absolute size, cell padding/border/alignment,
  paragraph line spacing/indentation, and any URI/id — exactly the fields
  the live comparison above showed vary without a visual difference.
  """

  alias PhoenixKitDocumentCreator.GoogleDocsClient, as: G

  @doc """
  Structural fingerprint of a header/footer segment's `content` (or a table
  cell's `content` — same shape), for comparing "does this look like the
  same header/footer" across documents. Two segments fingerprint equal iff
  `==` on the returned term holds. See the moduledoc for what's kept/dropped
  and why.
  """
  @spec fingerprint([map()], map()) :: term()
  def fingerprint(content, inline_objects) when is_map(inline_objects) do
    content
    |> List.wrap()
    |> Enum.flat_map(&element_fingerprint(&1, inline_objects))
  end

  @doc """
  Whether a header/footer segment's `content` can be rebuilt faithfully by
  the replay. The replay rebuilds text runs, rule paragraphs, and one-row-
  or-more tables whose cells hold text or a single inline image. Anything
  else would be dropped silently or rejected by the API:

    * `autoText` (page numbers / page counts) — the Docs API cannot insert
      it, so a replayed "Page 1 of 3" footer would come out "Page  of ".
    * an inline image outside a table cell, a cell with more than one image
      or an image next to text, or an image with no `contentUri` (drawings,
      charts) — only an image-only cell's single picture is re-inserted.
    * positioned (floating) objects, nested tables, and any other element
      kind (equations, footnote references, …).

  `false` keeps the section on the header/footer it inherits instead of
  replacing it with a lossy copy.
  """
  @spec replayable?([map()], map()) :: boolean()
  def replayable?(content, inline_objects) when is_map(inline_objects) do
    content
    |> List.wrap()
    |> Enum.all?(&replayable_element?(&1, inline_objects))
  end

  defp replayable_element?(%{"paragraph" => paragraph}, _inline_objects),
    do: plain_paragraph?(paragraph, [])

  defp replayable_element?(%{"table" => table}, inline_objects) do
    table
    |> Map.get("tableRows", [])
    |> Enum.flat_map(&Map.get(&1, "tableCells", []))
    |> Enum.all?(&replayable_cell?(Map.get(&1, "content", []), inline_objects))
  end

  defp replayable_element?(_other, _inline_objects), do: false

  defp replayable_cell?(content, inline_objects) do
    paragraphs = Enum.map(content, &Map.get(&1, "paragraph"))
    elements = Enum.flat_map(paragraphs, &(&1 && Map.get(&1, "elements", [])))

    image_ids =
      Enum.flat_map(elements, &List.wrap(get_in(&1, ["inlineObjectElement", "inlineObjectId"])))

    text =
      elements |> Enum.map_join(&(get_in(&1, ["textRun", "content"]) || "")) |> String.trim()

    Enum.all?(paragraphs, &(&1 && plain_paragraph?(&1, ["inlineObjectElement"]))) and
      case image_ids do
        [] -> true
        [id] -> text == "" and image_uri?(inline_objects, id)
        _ -> false
      end
  end

  defp plain_paragraph?(paragraph, extra_kinds) do
    kinds = ["textRun", "horizontalRule" | extra_kinds]

    not Map.has_key?(paragraph, "positionedObjectIds") and
      paragraph
      |> Map.get("elements", [])
      |> Enum.all?(fn element -> Enum.any?(kinds, &Map.has_key?(element, &1)) end)
  end

  defp image_uri?(inline_objects, id) do
    uri =
      get_in(inline_objects, [
        id,
        "inlineObjectProperties",
        "embeddedObject",
        "imageProperties",
        "contentUri"
      ])

    is_binary(uri) and uri != ""
  end

  defp element_fingerprint(%{"paragraph" => paragraph}, inline_objects) do
    if rule_paragraph?(paragraph) do
      [:rule]
    else
      [paragraph_fingerprint(paragraph, inline_objects)]
    end
  end

  defp element_fingerprint(%{"table" => table}, inline_objects),
    do: [table_fingerprint(table, inline_objects)]

  defp element_fingerprint(_other, _inline_objects), do: []

  # A paragraph "is a rule" when it carries no meaningful text and either a
  # native `horizontalRule` element (Hinnapakkumine's un-rebuilt footer) or
  # a bottom border (every rebuilt stand-in) — both read as the single token
  # `:rule`, ignoring color/width/padding/font-size, none of which the
  # rebuild script or the API-native element even agree on having.
  defp rule_paragraph?(paragraph) do
    elements = Map.get(paragraph, "elements", [])
    has_rule_element = Enum.any?(elements, &Map.has_key?(&1, "horizontalRule"))
    text = elements |> Enum.map_join(&(get_in(&1, ["textRun", "content"]) || "")) |> String.trim()
    border = get_in(paragraph, ["paragraphStyle", "borderBottom", "width", "magnitude"])

    has_rule_element or (text == "" and is_number(border) and border > 0)
  end

  defp paragraph_fingerprint(paragraph, inline_objects) do
    alignment = get_in(paragraph, ["paragraphStyle", "alignment"])
    elements = Map.get(paragraph, "elements", [])
    {:paragraph, alignment, Enum.map(elements, &run_fingerprint(&1, inline_objects))}
  end

  defp run_fingerprint(%{"textRun" => %{"content" => content} = run}, _inline_objects) do
    style = Map.get(run, "textStyle", %{})

    {:text, content, Map.get(style, "bold", false), Map.get(style, "italic", false),
     rounded(get_in(style, ["fontSize", "magnitude"]))}
  end

  defp run_fingerprint(%{"inlineObjectElement" => %{"inlineObjectId" => id}}, inline_objects) do
    embedded = get_in(inline_objects, [id, "inlineObjectProperties", "embeddedObject"]) || %{}
    {:image, aspect_ratio(embedded)}
  end

  defp run_fingerprint(_other, _inline_objects), do: :other

  defp aspect_ratio(embedded) do
    w = get_in(embedded, ["size", "width", "magnitude"])
    h = get_in(embedded, ["size", "height", "magnitude"])

    if is_number(w) and is_number(h) and h > 0 do
      rounded(w / h)
    end
  end

  defp rounded(m) when is_number(m), do: Float.round(m * 1.0, 1)
  defp rounded(_), do: nil

  defp table_fingerprint(table, inline_objects) do
    cells =
      table
      |> Map.get("tableRows", [])
      |> Enum.flat_map(&Map.get(&1, "tableCells", []))
      |> Enum.map(fn cell -> fingerprint(Map.get(cell, "content", []), inline_objects) end)

    {:table, Map.get(table, "rows"), Map.get(table, "columns"), cells}
  end

  # ---- create ---------------------------------------------------------

  @doc """
  `createHeader`/`createFooter` request for a fresh `DEFAULT` segment on the
  section whose section break sits at `break_index` — the section break
  element's own `startIndex` (NOT the `insertSectionBreak` request's
  `location.index`, one less — see `append_template/3`'s doc on why the
  break inserts a newline ahead of itself).
  """
  @spec create_segment_request(:header | :footer, non_neg_integer()) :: map()
  def create_segment_request(:header, break_index),
    do: %{
      "createHeader" => %{
        "type" => "DEFAULT",
        "sectionBreakLocation" => %{"index" => break_index}
      }
    }

  def create_segment_request(:footer, break_index),
    do: %{
      "createFooter" => %{
        "type" => "DEFAULT",
        "sectionBreakLocation" => %{"index" => break_index}
      }
    }

  @doc """
  Pulls the new segment's id out of a `createHeader`/`createFooter` batch
  response's `replies`.
  """
  @spec segment_id_from_replies(:header | :footer, [map()]) :: String.t() | nil
  def segment_id_from_replies(:header, replies),
    do: Enum.find_value(replies, &get_in(&1, ["createHeader", "headerId"]))

  def segment_id_from_replies(:footer, replies),
    do: Enum.find_value(replies, &get_in(&1, ["createFooter", "footerId"]))

  # ---- segmentId wrap ---------------------------------------------------

  @doc """
  Wraps already-built, segment-agnostic requests (from
  `GoogleDocsClient.paragraph_style_requests/2`,
  `GoogleDocsClient.text_style_requests/2`,
  `GoogleDocsClient.paragraph_then_text_style_requests/3`,
  `GoogleDocsClient.table_column_width_requests/2`,
  `GoogleDocsClient.table_skeleton_requests/2`, and this module's own
  builders) for a specific header/footer segment: every `location`,
  `range`, and `tableStartLocation` map found anywhere in the request tree
  gets `segmentId` merged in (existing keys win — nothing is overwritten).
  This is deliberately a transform over the *result* of those builders
  rather than a segment-aware copy of each one: the coordinate keys a Docs
  API request can carry are a small, closed set, so one generic walk covers
  every request shape above (and any new one built the same way) instead of
  duplicating each builder with a `segment_id` argument threaded through
  every `range`/`location` it emits.
  """
  @spec with_segment_id([map()], String.t()) :: [map()]
  def with_segment_id(requests, segment_id) when is_list(requests),
    do: Enum.map(requests, &tag(&1, segment_id))

  @segment_location_keys ~w(location range tableStartLocation)

  defp tag(%{} = map, segment_id) do
    map
    |> Map.new(fn {k, v} -> {k, tag(v, segment_id)} end)
    |> tag_own_location_keys(segment_id)
  end

  defp tag(list, segment_id) when is_list(list), do: Enum.map(list, &tag(&1, segment_id))
  defp tag(other, _segment_id), do: other

  defp tag_own_location_keys(map, segment_id) do
    Enum.reduce(@segment_location_keys, map, fn key, acc ->
      case Map.get(acc, key) do
        %{} = inner -> Map.put(acc, key, Map.put_new(inner, "segmentId", segment_id))
        _ -> acc
      end
    end)
  end

  # ---- skeleton ---------------------------------------------------------

  @doc """
  Phase (б) of the replay: insert the flattened text (table markers
  included, see `GoogleDocsClient.flatten_template_with_table_markers_and_styles/1`)
  at the start of a fresh (empty) segment, then its paragraph and text
  style. `text` already has its own final trailing newline stripped by the
  caller when the template ends in a plain paragraph (the Docs API refuses
  to delete a segment's terminal newline, so the segment's own pre-existing
  one serves as that paragraph's terminator instead — see
  `GoogleDocsClient.skeleton_insert_text/2`'s doc); an empty `text` (a
  template that's a single, otherwise-empty paragraph) skips `insertText`
  entirely — the API rejects an empty one, same as body's/a cell's, and the
  paragraph/text style requests below still apply, targeting the segment's
  own pre-existing newline. No `segmentId` yet — wrap the result with
  `with_segment_id/2`.
  """
  @spec skeleton_requests(String.t(), [map()], [map()]) :: [map()]
  def skeleton_requests(text, runs, paragraphs) do
    insert_request(text) ++ G.paragraph_then_text_style_requests(0, paragraphs, runs)
  end

  defp insert_request(""), do: []

  defp insert_request(text),
    do: [%{"insertText" => %{"location" => %{"index" => 0}, "text" => text}}]

  # ---- extra style (fields the shared, narrow body builders don't cover) --

  @doc """
  `updateParagraphStyle` requests for fields
  `GoogleDocsClient.paragraph_style_requests/2` deliberately doesn't
  capture (borders, shading) — a header/footer replay's own pass, kept
  separate from the shared, narrow body builder (which is covered by exact
  batch-content tests body appends rely on) rather than widening it. One
  request per span that has at least one such field; a span with none gets
  none — no anti-inheritance mask needed here, since every field is on a
  brand new, isolated segment with nothing adjacent to inherit from.

  `spans_with_extras` — `[{span, extras}]`, `span` shaped like
  `GoogleDocsClient.paragraph_style_requests/2`'s (`start_offset`,
  `length`), `extras` a map with `border_top`/`border_bottom`/
  `border_left`/`border_right` (each the source's own raw Docs `Border`
  object, or `nil`), `shading` (raw `Shading` object or `nil`), and
  `space_below` (a bare point value or `nil` — the `horizontalRule`
  stand-in's forced 6pt gap, see `paragraph_extras/1`'s caller).
  """
  @spec extra_paragraph_style_requests(integer(), [{map(), map()}]) :: [map()]
  def extra_paragraph_style_requests(base_index, spans_with_extras) do
    spans_with_extras
    |> Enum.filter(fn {span, _extras} -> span.length > 0 end)
    |> Enum.flat_map(fn {span, extras} -> paragraph_extras_request(base_index, span, extras) end)
  end

  defp paragraph_extras_request(base_index, span, extras) do
    payload =
      %{}
      |> maybe_put("borderTop", extras.border_top)
      |> maybe_put("borderBottom", extras.border_bottom)
      |> maybe_put("borderLeft", extras.border_left)
      |> maybe_put("borderRight", extras.border_right)
      |> maybe_put("shading", extras.shading)
      |> maybe_put("spaceBelow", dimension_pt(extras[:space_below]))

    if payload == %{} do
      []
    else
      [
        %{
          "updateParagraphStyle" => %{
            "range" => %{
              "startIndex" => base_index + span.start_offset,
              "endIndex" => base_index + span.start_offset + span.length
            },
            "paragraphStyle" => payload,
            "fields" => payload |> Map.keys() |> Enum.join(",")
          }
        }
      ]
    end
  end

  @doc """
  `updateTextStyle` requests for fields
  `GoogleDocsClient.text_style_requests/2` deliberately doesn't capture
  (`weightedFontFamily`, `underline`, `link`, `baselineOffset`), same
  separate-pass reasoning as `extra_paragraph_style_requests/2`.

  `runs_with_extras` — `[{run, extras}]`, `run` shaped like
  `GoogleDocsClient.text_style_requests/2`'s (`start_offset`, `length`),
  `extras` a map with `weighted_font_family`/`underline`/`link`/
  `baseline_offset` (each the source's own raw value, or `nil`) and
  `font_size` (a bare point value, or `nil` — the `horizontalRule`
  stand-in's forced 4pt, see `text_extras/1`'s caller; NOT the same as the
  shared builder's own captured `font_size`, which this leaves alone
  unless a rule forces an override).
  """
  @spec extra_text_style_requests(integer(), [{map(), map()}]) :: [map()]
  def extra_text_style_requests(base_index, runs_with_extras) do
    runs_with_extras
    |> Enum.filter(fn {run, _extras} -> run.length > 0 end)
    |> Enum.flat_map(fn {run, extras} -> text_extras_request(base_index, run, extras) end)
  end

  defp text_extras_request(base_index, run, extras) do
    payload =
      %{}
      |> maybe_put("weightedFontFamily", extras.weighted_font_family)
      |> maybe_put("underline", extras.underline)
      |> maybe_put("link", extras.link)
      |> maybe_put("baselineOffset", extras.baseline_offset)
      |> maybe_put("fontSize", dimension_pt(extras[:font_size]))

    if payload == %{} do
      []
    else
      [
        %{
          "updateTextStyle" => %{
            "range" => %{
              "startIndex" => base_index + run.start_offset,
              "endIndex" => base_index + run.start_offset + run.length
            },
            "textStyle" => payload,
            "fields" => payload |> Map.keys() |> Enum.join(",")
          }
        }
      ]
    end
  end

  defp dimension_pt(nil), do: nil
  defp dimension_pt(magnitude), do: %{"magnitude" => magnitude * 1.0, "unit" => "PT"}

  # ---- table fill ---------------------------------------------------------

  @doc """
  Phase (в) of the replay: column widths, cell style (padding/alignment
  replayed, borders always cleared — a bare `insertTable` cell renders with
  a visible border every captured home table lacks), cell text/style, and
  inline images (verbatim source size and URI — see the moduledoc).

  `entries` — one map per table, built by the caller from a re-fetched
  document (`GoogleDocsClient.extract_table_cells/1`'s cells matched
  against the captured template table): `%{table_start, columns, cells,
  column_properties, cell_styles, cell_texts, cell_runs, cell_paragraphs,
  cell_image_ids, cell_paragraph_extras, cell_run_extras}`. All the
  `cell_*` lists are row-major and index-aligned with each other (same
  padding-to-column-count — see
  `flatten_template_with_table_markers_and_styles/1`'s `normalize_row/3`).
  `cell_image_ids` entries are `nil` or an `inlineObjects` key.
  `cell_paragraph_extras`/`cell_run_extras` are themselves lists (one per
  cell, parallel to `cell_paragraphs`/`cell_runs`) of `{span, extras}` /
  `{run, extras}` pairs in `extra_paragraph_style_requests/2`'s and
  `extra_text_style_requests/2`'s own shape — a cell's border/font-family/
  underline/link get the same separate-pass treatment as body content.
  `columns` is the table's column count; each row-major `cell_styles`
  entry is addressed at `{div(i, columns), rem(i, columns)}`, so a
  multi-row table's second row lands on row 1 rather than on an
  out-of-range column of row 0.

  No `segmentId` yet — wrap the result with `with_segment_id/2`.
  """
  @spec table_fill_requests([map()], map()) :: [map()]
  def table_fill_requests(entries, inline_objects) do
    Enum.flat_map(entries, fn entry ->
      location = %{"index" => entry.table_start}

      G.table_column_width_requests(entry.table_start, entry.column_properties) ++
        cell_style_requests(location, entry.columns, entry.cell_styles) ++
        cell_fill_and_image_requests(entry, inline_objects)
    end)
  end

  @none_border %{
    "color" => %{"color" => %{"rgbColor" => %{}}},
    "width" => %{"magnitude" => 0.0, "unit" => "PT"},
    "dashStyle" => "SOLID"
  }

  defp cell_style_requests(table_start_location, columns, cell_styles) do
    columns = max(columns, 1)

    cell_styles
    |> Enum.with_index()
    |> Enum.map(fn {style, i} ->
      cell_style_request(table_start_location, div(i, columns), rem(i, columns), style)
    end)
  end

  defp cell_style_request(table_start_location, row, column, style) do
    payload =
      %{
        "borderTop" => @none_border,
        "borderBottom" => @none_border,
        "borderLeft" => @none_border,
        "borderRight" => @none_border
      }
      |> maybe_put("contentAlignment", style[:content_alignment])
      |> maybe_put("paddingTop", style[:padding_top])
      |> maybe_put("paddingBottom", style[:padding_bottom])
      |> maybe_put("paddingLeft", style[:padding_left])
      |> maybe_put("paddingRight", style[:padding_right])

    %{
      "updateTableCellStyle" => %{
        "tableRange" => %{
          "tableCellLocation" => %{
            "tableStartLocation" => table_start_location,
            "rowIndex" => row,
            "columnIndex" => column
          },
          "rowSpan" => 1,
          "columnSpan" => 1
        },
        "tableCellStyle" => payload,
        "fields" => payload |> Map.keys() |> Enum.join(",")
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Per cell: image cells carry no text (every known home header's logo
  # cell is image-only), so `image_id` and `text` are treated as mutually
  # exclusive. Paragraph style is applied BEFORE the image insert (using
  # the pre-insert length-1 range that covers the cell's own pre-existing
  # paragraph) rather than after, so the range unambiguously targets that
  # paragraph's own content and never the image's freshly inserted slot.
  # Sorted descending by index across the whole table (same reasoning as
  # `GoogleDocsClient`'s body table fill): an earlier cell's insert must not
  # shift a later cell's captured index.
  defp cell_fill_and_image_requests(entry, inline_objects) do
    [
      entry.cells,
      entry.cell_texts,
      entry.cell_runs,
      entry.cell_paragraphs,
      entry.cell_image_ids,
      entry.cell_paragraph_extras,
      entry.cell_run_extras
    ]
    |> Enum.zip()
    |> Enum.map(fn {%{insert_index: idx}, text, runs, paragraphs, image_id, para_extras,
                    run_extras} ->
      requests =
        cell_requests(idx, text, runs, paragraphs, image_id, inline_objects) ++
          extra_paragraph_style_requests(idx, para_extras) ++
          extra_text_style_requests(idx, run_extras)

      {idx, requests}
    end)
    |> Enum.sort_by(fn {idx, _requests} -> idx end, :desc)
    |> Enum.flat_map(fn {_idx, requests} -> requests end)
  end

  defp cell_requests(idx, _text, _runs, paragraphs, image_id, inline_objects)
       when is_binary(image_id) do
    case get_in(inline_objects, [image_id, "inlineObjectProperties", "embeddedObject"]) do
      nil ->
        G.paragraph_style_requests(idx, paragraphs)

      embedded ->
        G.paragraph_style_requests(idx, paragraphs) ++ [image_insert_request(idx, embedded)]
    end
  end

  defp cell_requests(idx, "", _runs, paragraphs, _image_id, _inline_objects),
    do: G.paragraph_style_requests(idx, paragraphs)

  defp cell_requests(idx, text, runs, paragraphs, _image_id, _inline_objects) do
    [%{"insertText" => %{"location" => %{"index" => idx}, "text" => text}}] ++
      G.paragraph_then_text_style_requests(idx, paragraphs, runs)
  end

  # Source size/URI verbatim, no rescale to the target's own column width —
  # see the moduledoc's live-check note.
  defp image_insert_request(index, embedded) do
    %{
      "insertInlineImage" => %{
        "location" => %{"index" => index},
        "uri" => get_in(embedded, ["imageProperties", "contentUri"]),
        "objectSize" => %{
          "width" => size_dimension(embedded, "width"),
          "height" => size_dimension(embedded, "height")
        }
      }
    }
  end

  defp size_dimension(embedded, axis) do
    case get_in(embedded, ["size", axis]) do
      %{"magnitude" => m} = dim when is_number(m) ->
        %{"magnitude" => m * 1.0, "unit" => Map.get(dim, "unit", "PT")}

      _ ->
        %{"magnitude" => 0.0, "unit" => "PT"}
    end
  end
end
