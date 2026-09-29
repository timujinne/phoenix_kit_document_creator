# Claude Review — PR #59

Image slots with the same name in several sections each get their own
pictures. Reviewed the merge diff (`c1879e2..ebff827`) against
`substitute_all_images/4`, `find_image_tag_ranges/2`,
`resolve_fit_page_keys/4` and the Phase 2 path.

Checked and correct: every lookup that was keyed by slot name
(`fills_map`, the range filter, the fit=page accept set, Phase 2's fill
lookup) now uses `{position, name}`; an occurrence outside every section
range is still dropped; fit=page acceptance is per key, so one section's
acceptance no longer leaks into another's rejected occurrence of the same
name.

## Findings

### BUG - HIGH — a second grid table's images land outside its cells

`build_phase2_requests/5` built the `insertInlineImage` requests table by
table in ascending document order (each table's cells back to front). A
batchUpdate applies requests in order, so the first table's N inserts shift
every later table's cell indices by N, and the later table's precomputed
`startIndex + 1` positions point N characters before its cells — Docs
rejects the batch (or, at best, places images in the wrong cells).

Before this PR a duplicated grid slot name resolved to one section only, so
two grid tables in one document were rare. Now every section that uses the
shared grid slot (the `joonised` case the PR targets) gets its own table,
which makes the multi-table Phase 2 batch the normal path. Neither the unit
test nor the E2E test caught it: both check which URIs reach which indices,
never the order they are applied in.

### NITPICK — `resolve_image_ranges/2` is a linear scan per occurrence

`Enum.find` over every fill for every tag occurrence. Slot counts are in
the tens, so this is left as is.
