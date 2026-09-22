# Follow-up — PR #52

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-21 and released in 0.9.6.

### BUG - MEDIUM — background thumbnail clears another action's spinner

**Resolved.** Distinct success message `{:thumbnail_refreshed, id, uri}` from
`refresh_thumbnail_async/3`; `DocumentsLive` clears `pending_files` only on
that message (and on `:thumbnail_refresh_failed`). The `@doc` explains why the
two messages must stay distinct.

### IMPROVEMENT - MEDIUM — exits and throws not caught

**Resolved.** `catch kind, reason` added alongside the `rescue`; both notify
the caller with `:internal_error`.

### NITPICK — whole card greyed out

**Not changed.**
