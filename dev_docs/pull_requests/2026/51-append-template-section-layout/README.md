# PR #51: each appended template is its own section with its own margins

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `a6f3a5a`, `cb89458`, `391ecce` (merged at `a7c9c00`)
**Date**: 2026-09-21

## Goal

Page margins are document-level, so every appended template was laid out in
the first template's margins. The PR replaces the `"\n"` + `insertPageBreak`
pair with `insertSectionBreak(NEXT_PAGE)` and sends an `updateSectionStyle`
carrying the template's margins in the same atomic batch.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `append_template/3` opens with a section break (`content_start` stays `insert_index + 2`); new public `section_margin_requests/2`. |
| `lib/phoenix_kit_document_creator/documents.ex` | `compose` doc mentions the per-section margins. |
| `test/phoenix_kit_document_creator/google_docs_client_append_tables_test.exs` | Section-break shape, margin request, tables + real-shaped section breaks. |

## Review

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
