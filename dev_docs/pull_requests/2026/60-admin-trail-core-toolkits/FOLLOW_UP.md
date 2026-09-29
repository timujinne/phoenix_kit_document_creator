# Follow-up — PR #60

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-25.

### IMPROVEMENT - MEDIUM — settings page section path bypasses `Paths`

**Resolved.** New `Paths.admin_settings/0`. The settings LiveView uses it and
no longer aliases `Routes`. `paths_test.exs` covers it and adds it to the
prefix-safety list.

### NITPICK — stale 2.23.2 comment in `DocumentsLive`

**Resolved.** Trimmed to "`:scope_folder` is validated and encoded by core."

### NITPICK — dead `Activity.Entry` guard in `Taxonomy`

**Resolved.** `fetch_cascade_uuids/2` queries the activity log directly; the
comment no longer mentions an unloaded schema.

### NITPICK — tab title "Edit"

**Not changed.** Core's trail contract; see the review.

### NITPICK — duplicated `open_on/1`

**Not changed.** Too small to share.
