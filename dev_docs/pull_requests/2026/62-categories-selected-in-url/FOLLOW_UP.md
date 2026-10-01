# Follow-up — PR #62

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-29.

### NITPICK — restoring the selected category leaves `?category=` in the URL

**Not changed.** Cosmetic; a reload opens the restored category.

### NITPICK — the Trash tab is not part of the URL

**Not changed.** Documented in `put_selected/2`; a second param for a rarely
reloaded state.

### NITPICK — one extra categories query per click

**Not changed.** One code path for click, link, Back and reload is worth it.
