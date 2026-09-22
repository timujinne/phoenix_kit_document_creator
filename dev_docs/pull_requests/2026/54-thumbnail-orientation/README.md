# PR #54: thumbnail frames follow the page's orientation

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `e7f5332` (merged at `12f1b95`)
**Date**: 2026-09-22

## Goal

Drive renders a thumbnail in the page's own orientation. The documents /
templates grid and the create-document modal show every thumbnail in a fixed
portrait frame with `object-fit: cover; object-position: top`, so a landscape
document (`documentStyle.flipPageOrientation`) was cropped to its middle strip.

## What Was Changed

| File | Change |
|------|--------|
| `web/components/create_document_modal.ex` | Tile `<img>` gains an `onload` handler; new public `landscape_fit_js/0` returning the handler JS |
| `web/documents_live.ex` | `render_thumbnail/1` `<img>` gains the same `onload` handler |
| two test files | Assert the frame markup and the handler string |

The first commit made the frames themselves follow the orientation; the
second reverted that to keep grid rows even and fit the image instead.

## Post-merge

See `CLAUDE_REVIEW.md` and `FOLLOW_UP.md`: the `onload` handler is replaced by
a server-side header read (`PhoenixKitDocumentCreator.Thumbnail`).
