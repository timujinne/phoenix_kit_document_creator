# PR #48: Template image picker uploads into a host-configured folder

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `6c66d21` (merged at `464fca8`)
**Date**: 2026-09-15

## Goal

Core 2.23.2 (#813) lets the standalone media selector file uploads under a
folder passed as `?scope_folder=<uuid>`, and lets hosts choose that folder
through a `{Mod, :fun}` hook. The PR adds the same hook for the template image
picker in `DocumentsLive`, so hosts can keep document images out of the
storage root.

## What Was Changed

### Files Added / Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/attachments.ex` | `Attachments.scope_folder/2` reads `:attachments_parent_folder`, calls the hook as `fun(:document_image, actor_uuid, %{template_file_id: id})` or `/2`, and returns the folder uuid or `nil`. |
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | `open_media_picker` asks the hook and appends `scope_folder=` to the selector URL. |
| `test/phoenix_kit_document_creator/attachments_test.exs` | Unit coverage: no config, 3-arg hook, 2-arg fallback, `nil` answer, raising hook. |
| `test/phoenix_kit_document_creator/web/documents_live_test.exs` | The redirect URL carries `scope_folder` when a hook is configured and omits it otherwise. |
| `CHANGELOG.md` | `Unreleased` entry. |

## Review

See `CLAUDE_REVIEW.md`; resolutions in `FOLLOW_UP.md`. Released as 0.9.4.
