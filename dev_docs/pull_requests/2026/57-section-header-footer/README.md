# PR #57: appended sections keep their template's own header and footer

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `f81d792` (merged at `f6b0de4`)
**Date**: 2026-09-23

## Goal

Every appended section inherited the first template's header and footer. A
section's `defaultHeaderId`/`defaultFooterId` are read-only and inherit from
the previous section, and the Docs API cannot point a section at an existing
segment, so the template's header/footer has to be rebuilt in a fresh one.

## What Was Changed

| File | Change |
|------|--------|
| `google_docs_client.ex` | After `append_template/3` places the body, it fingerprints the template's default header/footer against the one the new section would inherit. If they differ, it runs `createHeader`/`createFooter` at the section's own break and replays the content (paragraphs in one batch; table-bearing content through skeleton, re-fetch, match, style). `substitute_all_sections/3` resolves a header/footer placeholder against the section that owns the segment (`header_footer_owners/3`). |
| `google_docs_client/segment_replay.ex` | New pure module: the fingerprint and the request builders for the replay. |
| tests | Replay request shapes, fingerprint tolerance, terminal-newline and table-split regressions, owner resolution. |

## Post-merge

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
