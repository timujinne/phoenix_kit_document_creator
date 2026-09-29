# Follow-up — PR #61

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-28.

### IMPROVEMENT - MEDIUM — no catch-all `handle_info/2`

**Resolved.** `CategoriesLive` ignores unknown messages with a debug log;
`categories_live_test.exs` covers a stray broadcast on the files topic.

### IMPROVEMENT - MEDIUM — Drive-sync status changes not live

**Not changed.** Needs change detection in the sync layer; see the review.

### NITPICK — docstring overstated the shared rule

**Resolved.** `count_published_templates_by_type/1` doc reworded.

### NITPICK — `role="img"` on a text badge

**Not changed.**
