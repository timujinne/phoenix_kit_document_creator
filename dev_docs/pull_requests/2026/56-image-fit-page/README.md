# PR #56: image slots can fill the page

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `ad46815` (merged at `47ee605`)
**Date**: 2026-09-23

## Goal

Image slots in a composed document were sized against the whole document's
content width, so a landscape section got the portrait width, and there was
no way to make an image fill the rest of its page.

## What Was Changed

| File | Change |
|------|--------|
| `google_docs_client.ex` | New `section_boxes/1`: per-section page size (flip-aware), margins, and `body_top_pt`/`body_bottom_pt` estimated from header/footer content (`header_extent_pt/2`, `footer_extent_pt/2`). Image slots read their own section's box. New `fit: "page"` for single-column `image_list` slots, `scale = min(box_w / w_px, avail_h / h_px)`, with a host-tunable `page_fit_safety_pt/0`. |
| `documents.ex`, `variable.ex`, `variable_config_form.ex` | `fit` config whitelist and a "Fit width / Fit page" select. |
| tests + `joonised_preview_headers_footers.json` fixture | Section boxes, header/footer extent (calibrated against a live render), fit=page sizing and scope guards. |

## Post-merge

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
