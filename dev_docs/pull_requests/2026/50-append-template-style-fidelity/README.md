# PR #50: append_template keeps font sizes, bold and spacing

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `8980c0e`, `bc05b58`, `29a926e` (merged at `40d4edc`)
**Date**: 2026-09-21

## Goal

Appended template sections lost their font sizes, bold and paragraph spacing.
Two causes: `updateParagraphStyle` with `namedStyleType` in its mask resets
text style, and it ran *after* `updateTextStyle`; and absent paragraph-style
keys were pinned to concrete defaults (START / 100% / 0pt) instead of being
left to inherit from the named style.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | New `paragraph_then_text_style_requests/3` owns the order (paragraph first) for body and table cells; absent style keys captured as `nil` and sent as an explicit unset (in the mask, absent from the payload); a unit-only dimension reads as an explicit zero. |
| `test/phoenix_kit_document_creator/google_docs_client_append_tables_test.exs` | Order, unset-vs-zero and dimension-shape tests. |

## Review

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
