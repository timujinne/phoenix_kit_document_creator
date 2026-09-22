# PR #53: embedded images at full size, and PDF export past Drive's 10 MB cap

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `78cdd55` (merged at `691dc1d`)
**Date**: 2026-09-22

## Goal

Images inserted into a Google Doc came out at 1600px on the long side,
because a bare `lh3.googleusercontent.com/d/<id>` URL serves a downscaled
copy. With full-size images, documents can then push their PDF past the
~10 MB cap of Drive's `files.export`, which answers 403
`exportSizeLimitExceeded`.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `upload_image_for_embedding/3` returns `…/d/<id>=s4096`; `export_pdf/1` falls back to the file's `exportLinks` PDF URL (restricted to `https://docs.google.com`) on `exportSizeLimitExceeded`. |
| `test/integration/google_docs_client_http_test.exs` | lh3 URL shape; fallback success, failure, and off-host link refusal. |

## Review

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
