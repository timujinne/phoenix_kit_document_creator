# Follow-up — PR #59

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-23.

### BUG - HIGH — second grid table's images land outside its cells

**Resolved.** `build_phase2_requests/5` fills the last table first, so the
whole batch's inserts run in strictly descending index order; border
requests stay ahead of every insert. Tests: the unit test "two grid tables:
image inserts run in strictly descending index order across tables" and an
exact-order assertion added to the duplicate-slot-name grid E2E test. Both
fail with the fix reverted.

### NITPICK — linear scan in `resolve_image_ranges/2`

**Not changed.** Negligible at real slot counts.
