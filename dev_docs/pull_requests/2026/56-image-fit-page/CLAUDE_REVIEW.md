# Claude Review — PR #56

Reviewed the merge diff (`9ffc3b1..47ee605`). The header/footer chain walk
(own id, then the previous section's resolved id, then `documentStyle`), the
missing-`startIndex` first section break, and the pt units are right. The
tests pin exact heights from the formula and are not tautological.

## Findings

### BUG - MEDIUM — a zero Dimension reads as "missing"

proto3 JSON drops a zero magnitude, so a margin or cell padding explicitly
set to 0 arrives as `%{"unit" => "PT"}`. That map wins the section-vs-document
`||`, then `magnitude/1` returns `nil` and the estimator falls back to the
72pt margin / 36pt header margin / 5pt cell and image padding. A full-bleed
template came out 144pt too narrow; a zero-padded header table was
overestimated by 10pt per row. (`content_width_pt/1` had the same pattern
before this PR.)

### BUG - MEDIUM — the text reserve ignores tables and image paragraphs

`paragraphs_reserve_before_slot/3` kept only `"paragraph"` elements and sized
them with the text-line formula. A table before a fit=page slot counted as
0pt and an inline-image paragraph as one text line, so the image overflowed
and Docs pushed it onto the next page, leaving a near-blank one.

### IMPROVEMENT - MEDIUM — reserve assumes a fresh page

The reserve sums the section's content from its break onward. A CONTINUOUS
section's text above it on the same page is not counted, and an earlier image
slot in the same section is measured as its placeholder text.

### IMPROVEMENT - MEDIUM — first-page / even-page headers are ignored

`header_footer_extent_pt/4` reads only `defaultHeaderId`/`defaultFooterId`.
With "different first page" on, the first image is sized against the
default header.

### IMPROVEMENT - MEDIUM — `fit` reaches the library only through `image_params`

`fit` is read in the compose path (`substitute_all_sections/3`) from the
host's `image_params`, same contract as `columns`. The saved variable config
is not merged in, and `create_document_from_template/3` does not use it.

### NITPICK — `page_fit_safety_pt/0` raises on a non-numeric config

`get_env(...) * 1.0` raised `ArithmeticError` mid-compose for a string or
`nil` value. The function was a public `def` with a `@spec` but no `@doc`, and
the new app-env key was missing from AGENTS.md.

### NITPICK — form shows "Fit width" for an atom `:page` config

`current_columns` is `to_string`'d, `current_fit` was not.

### NITPICK — doc drift

`@page_fit_trailing_line_pt`'s comment (and the test module's) said the
trailing line applies to every image; it applies only to the image that
renders last. `segment_extent_pt/2` returned integer `0` for an empty
segment against a `float()` spec.

### NITPICK — side-by-side inline images are summed

`paragraph_extent_pt/2` sums the heights of several images in one paragraph
where the max would be exact. This errs toward a smaller image, the safe
direction.
