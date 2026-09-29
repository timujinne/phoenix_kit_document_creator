# Claude Review — PR #58

Image grids without Docs' default cell borders. Reviewed the merge diff
(`ce87af4..c1879e2`) against `do_fill_table_cells/6`, `match_new_tables/3`
and `fill_table_cells/3`.

Checked and correct: `updateTableCellStyle` is addressed by
`tableStartLocation`, so it does not shift text indices and is safe to batch
ahead of every insert; the span comes from the created table's own
dimensions, so a partly filled last row is covered; `columns: 1` slots never
reach Phase 2 with a border request; an explicit 0pt border (not an unset
one) is what clears Docs' default.

## Findings

### BUG - HIGH — Phase 2 fills tables in ascending order (see PR #59 review)

The new `build_phase2_requests/5` docstring reasons correctly that
`insertInlineImage` shifts the indices of later tables, and orders border
requests accordingly, but the fill requests themselves still ran table by
table in ascending order. The defect predates this PR and only bites with
two or more grid tables in one document, which PR #59 makes the normal case.
Recorded and fixed under PR #59.

### NITPICK — the two-table test only checked sorted URIs

"two grid tables sharing the same slot name…" asserted
`Enum.sort(uris)`, which cannot see the insert order. A new test asserts the
exact index/URI sequence.
