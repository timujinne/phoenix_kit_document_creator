# Claude Review — PR #50

Reviewed the merge diff (`79b5449..40d4edc`) against the rest of
`append_template/3`'s pipeline (body batch, table skeleton + fill,
bullet requests).

The two diagnoses are right and the fix is shaped well: one helper owns the
paragraph-then-text ordering, so body text and table cells can no longer
drift apart, and "absent key = inherit from the named style" is the correct
reading of the Docs API. The mask stays complete, so the anti-inheritance
guarantee against the neighbouring paragraph survives the change.

## Findings

### NITPICK — the reset-on-`namedStyleType` fact is unguardable by tests

The doc says so itself ("no mock-based test can guard it"). The ordering test
pins the *order*, which is what can regress locally; the underlying API
behaviour can only be re-verified live. Nothing to change — recorded so a
future reader doesn't try to "simplify" the helper away.

### NITPICK — named styles of later templates are not carried over

An unset property resolves against the *target's* named styles (the first
template's), so a later template whose NORMAL_TEXT differs renders with the
first template's spacing. Documented in `extract_paragraph_style/2`'s
comment; copying named styles across is not possible through `batchUpdate`
(`updateDocumentStyle` has no named-style fields), so this is a real API
limit rather than an omission.

No bugs found.
