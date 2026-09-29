defmodule PhoenixKitDocumentCreator.GoogleDocsClientLiveFixtureExtentTest do
  @moduledoc """
  Self-check of `header_extent_pt/2` / `footer_extent_pt/2` against a real
  document: `test/fixtures/joonised_preview_headers_footers.json`, a trimmed
  `get_document` snapshot (headers, footers, inlineObjects, documentStyle,
  and the two `sectionBreak` structural elements only — no body text) of the
  live "Hinnapakkumine + Joonised (tootmine) + Leping" composite preview
  (doc id `1arAQZGlMkuaOU2CFaW9CrxdL9GgHsRQ2qZM6Dy4dHqk`, captured 2026-09-23).
  Section 2 (the landscape "Joonised" section) declares no header/footer of
  its own, so it inherits the document's default — the shared "house"
  header/footer also used by section 1.

  This is the same house header/footer block D's `page_fit_safety_pt`
  moduledoc measurements (§9/§10 of
  `docs/superpowers/specs/2026-09-22-section-orientation-and-page-fit.md`)
  were calibrated against live, on a different template embedding the same
  header/footer.

  Calibration target from the team lead's live-PDF pixel measurement
  (2026-09-23, same fixture document): `header_extent_pt/2` should land in
  `[75, 90]`; `footer_extent_pt/2 + page_fit_safety_pt()` should reach
  `>= 109.2` (so the estimated body bottom stays at/above the last
  confirmed-fit pixel, y≈450.85) while `footer_extent_pt/2` alone should stay
  `<= 125` (not wildly over). Reaching this needed one more fix beyond
  `@font_leading` and `\\u000B` soft-line-break counting: the footer's
  horizontal-rule paragraph (a `horizontalRule` structural element sharing a
  paragraph with a plain `textRun`) was being estimated as a single text
  line instead of the rule PLUS that line — `paragraph_line_count/1` now
  counts one extra line per `horizontalRule` element, and
  `estimate_paragraph_height_pt/1` also adds a paragraph's own
  `paragraphStyle.borderTop`/`borderBottom` (width + padding), for the other
  templates that draw the same rule as a thin bordered paragraph instead of
  a `horizontalRule` element.
  """

  use ExUnit.Case, async: true
  alias PhoenixKitDocumentCreator.GoogleDocsClient

  @fixture_path Path.join(__DIR__, "../fixtures/joonised_preview_headers_footers.json")

  setup_all do
    doc = @fixture_path |> File.read!() |> Jason.decode!()
    [doc: doc]
  end

  describe "header_extent_pt/2 / footer_extent_pt/2 on a live composite-preview fixture" do
    test "the landscape section inherits the document's default header/footer", %{doc: doc} do
      [_section1, section2] = doc["body"]["content"]
      style = get_in(section2, ["sectionBreak", "sectionStyle"])

      refute Map.has_key?(style, "defaultHeaderId")
      refute Map.has_key?(style, "defaultFooterId")
      assert doc["documentStyle"]["defaultHeaderId"]
      assert doc["documentStyle"]["defaultFooterId"]
    end

    test "header_extent_pt/2 lands in the team lead's calibrated [75, 90] range", %{
      doc: doc
    } do
      [_section1, section2] = doc["body"]["content"]
      style = get_in(section2, ["sectionBreak", "sectionStyle"])

      extent = GoogleDocsClient.header_extent_pt(doc, style)

      assert extent >= 75.0
      assert extent <= 90.0
    end

    test "footer_extent_pt/2 + page_fit_safety_pt/0 reaches the calibrated >= 109.2 target", %{
      doc: doc
    } do
      [_section1, section2] = doc["body"]["content"]
      style = get_in(section2, ["sectionBreak", "sectionStyle"])

      extent = GoogleDocsClient.footer_extent_pt(doc, style)
      total = extent + GoogleDocsClient.page_fit_safety_pt()

      assert extent <= 125.0
      assert total >= 109.2
    end

    test "section_boxes/1 folds both extents into body_top_pt / body_bottom_pt", %{doc: doc} do
      [box1, box2] = GoogleDocsClient.section_boxes(doc)

      # Both sections inherit the same house header/footer, so both get the
      # same body_top_pt regardless of the section's own page orientation.
      assert box1.body_top_pt == box2.body_top_pt
      assert box1.body_top_pt > box1.margin_top

      # A footer taller than its margin pulls body_bottom_pt UP (smaller)
      # relative to the nominal margin-only bottom (pageH - margin_bottom,
      # which equals height_pt + margin_top since height_pt = pageH -
      # margin_top - margin_bottom).
      nominal_bottom = box2.height_pt + box2.margin_top
      assert box2.body_bottom_pt < nominal_bottom
    end
  end
end
