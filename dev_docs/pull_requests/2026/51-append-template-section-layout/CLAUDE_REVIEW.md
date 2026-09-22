# Claude Review — PR #51

Reviewed the merge diff (`40d4edc..a7c9c00`) against the Docs API's
`SectionStyle` resolution rules and the downstream table pipeline, which
re-fetches the target and so is unaffected by the switch from a page break to
a section break.

The section break is a genuinely better primitive than the old `"\n"` +
page-break pair: it produces the fresh first paragraph by itself, and the
returned `{start, end}` range (`insert_index + 2`) is unchanged, so
section-scoped substitution in `Documents` needs nothing. Keeping the margin
request in the content batch — fail loudly rather than leave a mis-laid-out
document — is the right call and is documented as deliberate.

## Findings

### IMPROVEMENT - MEDIUM — margins are read from `documentStyle` only

`section_margin_requests/2` took the margins from the template's
`documentStyle`. The API resolves a section's margin from its own
`sectionStyle` first and falls back to `documentStyle` only when unset. Now
that this module *writes* section margins, a template that is itself a
composed document (or any doc whose first section overrides its margins) has
first-page margins that live in `body.content[0].sectionBreak.sectionStyle`,
and the appended section got the document-level ones instead — the same
"wrong margins" defect the PR exists to prevent, one level down.

**Fixed.** The template's first section's `sectionStyle.margin*` win field by
field, `documentStyle.margin*` is the fallback, matching the API's own order.
Test added in `section_margin_requests/2`'s describe block.

### NITPICK — a template stating no margins inherits the previous section's

A section created by `insertSectionBreak` copies the style of the section it
splits from, so if a template's styles state no margin at all, the appended
section keeps the *previous appended template's* margins rather than the
document default. Google always returns all four page margins in
`documentStyle`, so this is theoretical; not changed.
