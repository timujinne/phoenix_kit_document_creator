# Follow-up — PR #54

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-22.

### BUG - MEDIUM — JS-set fit undone by the next LiveView patch

**Resolved.** The orientation is read server-side from the image header
(`PhoenixKitDocumentCreator.Thumbnail.img_style/1`) and rendered into the
`style` attribute.

### IMPROVEMENT - MEDIUM — inline event handler

**Resolved** by the same change. The `onload` attribute is gone.

### NITPICK — public `landscape_fit_js/0`

**Resolved.** Removed.

### NITPICK — tests asserted the JS string

**Resolved.** Tests use real headers in both orientations, and there are
unit tests for every parser.
