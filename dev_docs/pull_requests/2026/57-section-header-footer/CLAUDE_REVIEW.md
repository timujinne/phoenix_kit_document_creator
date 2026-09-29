# Claude Review — PR #57

Reviewed the merge diff (`47ee605..f6b0de4`) against `Composer.compose/2`,
which calls `append_template/3` per section and deletes the half-built
document on any error. Checked and correct: `break_index = content_start - 1`
is the new section's break, `with_segment_id/2` tags nested
`tableStartLocation`s, table fills run back to front, and a re-fetched
segment's missing `startIndex` (proto3 zero) is handled.

## Findings

### BUG - HIGH — multi-row header/footer tables fail the whole compose

`cell_style_requests/2` numbered the row-major `cell_styles` with
`Enum.with_index` and sent that as `columnIndex`, always with `rowIndex: 0`.
A 2×2 header table produced `{row 0, column 2}` and `{row 0, column 3}`,
the batch got a 400, `append_template/3` returned an error, and the
composed document was deleted. Before this PR the same compose succeeded
(with the inherited header). The single-row limitation was documented but
nothing enforced it.

### BUG - MEDIUM — content the replay can't rebuild is dropped silently

The replay reads only `textRun`s, rules, and image-only table cells. A
footer with page numbers (`autoText`, which the API cannot insert) came
out "Page  of ". A logo outside a table, a floating (positioned) object,
or a cell image next to text was lost, and a cell image with no
`contentUri` (a drawing or chart) sent `uri: null` and failed the batch.

### BUG - MEDIUM — internal links are copied verbatim

`text_extras/1` replayed the whole `link`, including `bookmarkId`/
`headingId`/`tabId`, which point into the template document and don't
exist in the target.

### IMPROVEMENT - MEDIUM — a header-less template inherits the previous section's header

`maybe_replay_segment/5` does nothing when the template has no header of
its own. With T1 (header A), T2 (header B), T3 (none), section 3 shows B.

### IMPROVEMENT - MEDIUM — first-page / even-page headers are not replayed

Only `DEFAULT` segments are compared and created; `useFirstPageHeaderFooter`
and `firstPageHeaderId` are ignored.

### IMPROVEMENT - MEDIUM — fingerprint ignores image identity and font

Two different logos with the same rounded aspect ratio compare equal, as do
runs differing only in font family or colour. The tolerance is deliberate
(see the `SegmentReplay` moduledoc), but it can keep a wrong logo.

### IMPROVEMENT - MEDIUM — up to six API calls per replayed segment

create, skeleton, get, batch, get, batch, per segment. `createHeader` and
`createFooter` could share a batch.

### NITPICK — error tuples outside the error-atom convention

`{:segment_not_created, kind}` and `{:segment_shape_mismatch, expected:,
actual:}` bypass `Errors.message/1`, so the admin UI would show an
`inspect/1` dump.

### NITPICK — moduledoc points at a file not in the repo

`docs/superpowers/template-header-footer-backup-2026-09-21/house_header_footer.ex`
is referenced twice and does not exist.
