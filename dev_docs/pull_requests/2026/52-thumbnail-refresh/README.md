# PR #52: manual thumbnail refresh for documents and templates

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `24a0286`, `03a8eb7`, `c9570a5` (merged at `59a6904`)
**Date**: 2026-09-21

## Goal

Drive renders thumbnails lazily, so a card can keep showing a blank or stale
image after the file's content changed. The PR adds a "Refresh thumbnail"
menu action to document and template cards.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/documents.ex` | `refresh_thumbnail/2` (fetch, persist, activity log) and `refresh_thumbnail_async/3` (supervised task, always notifies the caller). |
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | `refresh_thumbnail` event behind `verify_known_file/2` and the `pending_files` guard; failure message handled via `Errors.message/2`; menu buttons in list and grid views. |
| `priv/gettext/*` | Two new msgids, translated. |
| tests | Context success/failure/crash, LiveView guards and messages. |

## Review

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`.
