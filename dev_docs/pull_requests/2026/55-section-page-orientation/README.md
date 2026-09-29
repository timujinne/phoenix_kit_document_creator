# PR #55: appended sections keep the template's own page orientation

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `8b8f5f2` (merged at `629ac3a`)
**Date**: 2026-09-23

## Goal

A composed document is a copy of its first template plus one section per
further template. Margins were already per section (PR #52), but orientation
was not, so a landscape template appended after a portrait one came out
portrait, and a portrait one after a landscape one inherited the flip.

## What Was Changed

| File | Change |
|------|--------|
| `google_docs_client.ex` | New `section_layout_requests/3`: one `updateSectionStyle` carrying the template's margins plus an always-explicit `flipPageOrientation`, computed as `template_landscape? XOR target_landscape_shaped?`. `append_template/3` sends it in place of `section_margin_requests/2`. |
| `google_docs_client_append_tables_test.exs` | Unit tests for every orientation combination; the `append_template/3` batch assertions now expect the flip field. |

## Post-merge

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
