# Follow-up — PR #56

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-23.

### BUG - MEDIUM — zero Dimension reads as missing

**Resolved.** `magnitude/1` returns `0.0` for a Dimension carrying only a
`unit`; only an absent Dimension is `nil`. Test: "a zero margin (proto3
drops the magnitude) is 0pt, not the 72pt default".

### BUG - MEDIUM — reserve ignores tables and image paragraphs

**Resolved.** The reserve now includes tables and sizes every element with
`element_extent_pt/2`, the same estimator the header/footer extent uses.
Test: "a table ahead of the slot counts toward the reserve at its
estimated height" (fails on the merged code).

### Reserve assumes a fresh page / first-page headers / `fit` contract

**Not changed.** Each needs either a live layout measurement (CONTINUOUS
sections, first-page headers) or a decision about merging saved config into
host-supplied fills. The fresh-page blind spots are now listed in
`paragraphs_reserve_before_slot/3`'s comment.

### NITPICK — `page_fit_safety_pt/0`

**Resolved.** A non-numeric or negative value falls back to `8.0`; the
function has a `@doc`; AGENTS.md lists the key. Test added.

### NITPICK — form atom `fit`

**Resolved.** `current_fit` is `to_string`'d.

### NITPICK — doc drift

**Resolved.** Both trailing-line comments corrected; `segment_extent_pt/2`
and the reserve reduce from `0.0`.

### NITPICK — side-by-side images summed

**Not changed.** It errs in the safe direction.
