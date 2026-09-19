# PR #49: `export_pdf/1` reports why a Drive export failed

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `63e138e`, `c5277fc` (merged at `76ea0b8`)
**Date**: 2026-09-17

## Goal

`GoogleDocsClient.export_pdf/1` collapsed every non-200 Drive response into
`{:error, :pdf_export_failed}`, and `DocumentsLive` rendered one fixed string
for it. An admin could not tell "the file is gone" from "this connection
can't read it" from "you are being rate limited" — three failures with three
different remedies. The PR splits Drive's 404 and 403 into named reasons and
routes them through `Errors.message/1`.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `export_pdf/1` matches 404 → `:drive_file_not_found` and 403 → `classify_403/2`; new `classify_403/2` + `drive_403_reason/1` read `error.errors[].reason` (or `error.reason`) and split permission reasons from rate/quota reasons from the caller's fallback. |
| `lib/phoenix_kit_document_creator/errors.ex` | New atoms `:drive_forbidden`, `:drive_rate_limited`, `:drive_export_too_large`; `:drive_file_not_found` reworded to read correctly in both the restore and the export flow; new `message/2` with a caller-supplied fallback. |
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | `export_pdf`'s failure branch renders the specific reason via `Errors.message/2`; the restore flow appends its own "You can permanently delete this record." hint. |
| `priv/gettext/*` | The new and reworded msgids, translated into `en` / `et` / `ru`. |
| `test/errors_test.exs`, `test/integration/google_docs_client_http_test.exs`, `test/phoenix_kit_document_creator/web/documents_live_test.exs` | 404, the three 403 buckets, both 403 body shapes, the unmapped-term fallback, and the LiveView flash. |

### API Changes

| Function | Change |
|----------|--------|
| `GoogleDocsClient.export_pdf/1` | Error reason widened from `:invalid_file_id \| :pdf_export_failed \| term()` to add `:drive_file_not_found`, `:drive_forbidden`, `:drive_rate_limited`, `:drive_export_too_large`. Callers matching on `:pdf_export_failed` alone now fall into their own catch-all for those four. |
| `Errors.message/2` | New. `message(reason, fallback)` — like `message/1` but returns `fallback` instead of the `inspect/1` catch-all for an unmapped term. |

## Review

See `CLAUDE_REVIEW.md` for findings and `FOLLOW_UP.md` for how each was
resolved.

## Testing

- [x] Unit tests added/updated
- [x] Integration tests pass
- [ ] Migration tested on staging — no migration
- [x] Backward compatibility verified (the widened error union is additive;
      `Errors.message/1` is unchanged for every other atom)
- [x] Documentation updated (`@doc`/`@spec` on `export_pdf/1`, `Errors`
      moduledoc, CHANGELOG)

## Related

- Previous PR: [#48](/dev_docs/pull_requests/2026/48-attachments-parent-folder/)
