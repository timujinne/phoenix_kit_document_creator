# Follow-up — PR #57

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-23.

### BUG - HIGH — multi-row tables

**Resolved.** Table-fill entries carry `columns`; each cell style is
addressed at `{div(i, columns), rem(i, columns)}`. Test: "a multi-row
table's cell styles are addressed row-major, never past the last column".

### BUG - MEDIUM — unreplayable content

**Resolved.** New `SegmentReplay.replayable?/2`. When the template's segment
holds `autoText`, a non-cell or floating image, a cell image without a
`contentUri` or next to text, or any other element kind, the section keeps
its inherited header/footer and a warning is logged instead of a lossy copy
going out. Tests in `segment_replay_test.exs` plus an end-to-end
page-number footer case.

### BUG - MEDIUM — internal links

**Resolved.** Only `link.url` is replayed; other link kinds are dropped.

### Header-less template, first-page headers, fingerprint tolerance, call count

**Not changed.** Giving a header-less template an empty header changes what
every existing composition looks like (today the first template's header
runs through). First-page headers need a live check of how
`useFirstPageHeaderFooter` inherits per section. The fingerprint tolerance
was calibrated live on purpose. The call count only matters for speed.
These are left for a product decision or a live check.

### NITPICK — error tuples

**Resolved.** Both are now plain atoms, `:segment_not_created` and
`:segment_shape_mismatch`, with the shape counts logged. Each has an
`Errors.message/1` clause, and the et/ru translations are added.

### NITPICK — dangling file reference

**Resolved.** Both references now describe the one-off script instead.
