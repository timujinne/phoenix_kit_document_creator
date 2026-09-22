# Follow-up — PR #53

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-22.

### IMPROVEMENT - MEDIUM — any 200 accepted as a PDF

**Resolved.** The fallback requires the body to start with `%PDF-`.

### IMPROVEMENT - MEDIUM — 15s receive timeout

**Resolved.** `receive_timeout: 120_000` on the export-link download.

### IMPROVEMENT - MEDIUM — admin UI discards PDFs over 5 MB

**Deferred** to the signed download endpoint TODO in AGENTS.md.

### NITPICK — non-string link crash

**Resolved.** `is_binary(link)` guard.
