# Claude Review — PR #55

Reviewed the merge diff (`335a8b0..629ac3a`) against its caller chain:
`Composer.compose/2` copies the first template (so the target's
`documentStyle.pageSize` and flip are the first template's) and then calls
`append_template/3` once per further section, which already holds the
freshly fetched target as `current_doc`.

The model is right. `SectionStyle.flipPageOrientation` is documented as
flipping `DocumentStyle.pageSize` for that section, and it only falls back
to the document's flip when unset. Since this PR always sets it, the
target's own document-level flip correctly plays no part, and XOR against
the target's raw page shape is the whole calculation. Always sending a
concrete boolean also closes the inheritance hole for a portrait section
that follows a landscape one.

## Findings

### IMPROVEMENT - MEDIUM — a non-boolean document-level flip reads as a flip

`template_flip?/1` guarded the section-level value with `is_boolean/1` but
returned the document-level value unguarded
(`Map.get(document_style, "flipPageOrientation", false)`). A `null` there
reached `section_flip?/2`'s `!=` XOR as `nil`, and `false != nil` is `true`,
so a portrait template would have been appended as landscape. The Docs API
does not normally emit `null` for this field, but the section level was
already defended against exactly that, and the two levels should agree.

### NITPICK — `section_margin_requests/2` doc names a caller it no longer has

Its `@doc` said `append_template/3` passes it `content_start`. After this PR
the function has no production caller. It is public and documented, so it
stays for API compatibility in a patch release, but the doc should point at
`section_layout_requests/3`.

### Not changed — only the template's first section decides

A template that is itself a mixed-orientation composed document is appended
as a single section with its first section's orientation and margins. This
matches the existing margin behaviour and the existing "known limitations"
paragraph; splitting a template back into its sections is out of scope.
