# PR #64: Use neutral host-application wording in comments, docs and two UI strings

**Author**: @timujinne
**Reviewer**: @claude
**Status**: Merged
**Commit**: `ca35dae..310a618` (`c66c5ff`, `db283f9`)
**Date**: 2026-10-22

## Goal

Remove the name of one specific consuming application from comments, docs,
CHANGELOG/README prose, the database `COMMENT` on the deprecated template
columns, test comments and two admin UI strings, so the package reads as a
generic Hex module.

## What Was Changed

| File | Change |
|------|--------|
| `categories_live.ex` | Two gettext msgids reworded ("standard ANDI groups" → "standard groups", "Seed the standard ANDI group order" → "Seed the standard group order") plus one comment |
| `priv/gettext/{default.pot,*/default.po}` | The same two msgids renamed in the template and all three catalogues |
| `migrations/schema.ex` | V2 comment prose and the `COMMENT ON COLUMN` note text |
| `taxonomy.ex`, `schemas/template*.ex`, `documents/composer.ex`, `google_docs_client.ex` | Comment/doc-only |
| `CHANGELOG.md`, `README.md`, `dev_docs/.../38-.../CLAUDE_REVIEW.md`, `21-.../README.md`, two tests | Prose only |

No behaviour change. The only runtime-visible effects are the two UI strings
and the text of the DB column comment.

## Verification

- Repo-wide grep for `andi` (case-insensitive, word match) finds nothing left
  in `lib/`, `test/`, `priv/`, `README.md`, `CHANGELOG.md` or `dev_docs/`.
- The gettext msgids are literal arguments in `categories_live.ex` and match
  the renamed entries in all four catalogue files. The old msgids had empty
  `msgstr` in `en`/`et`/`ru`, so no existing translation was orphaned.
- The `COMMENT ON COLUMN ... IS '#{note}'` string is single-quote-interpolated;
  the new note contains no `'`, so the DDL stays valid.

## Findings

### NITPICK — V2 `COMMENT` text changed without a chain bump (not fixed, by design)

`v2_deprecate_legacy_template_columns/1` now writes different text, but V2 is
already applied (marker `dcr_schema:2`) on existing databases, so they keep the
old wording and only fresh installs get the new one. Both texts carry the
"deprecated … do not drop" warning, which is the part that matters, and the
statement is idempotent. Bumping to a V3 just to rewrite a comment would
violate the "bump only for a real shape change" intent of the chain. If V3 is
cut for the pending `inserted_at DESC` indexes (see AGENTS.md TODOs), restating
the comment there is free; otherwise leave it.

### IMPROVEMENT - MEDIUM — The deprecation comment safeguard had no test (fixed)

The comment is described in code as an "owner-mandated safeguard" against
dropping the legacy `category_uuid` / `type_uuid` mirror columns, yet nothing
asserted it exists — a PR that edits that very string (this one) could have
broken or removed it unnoticed. Added a test in
`migrations/schema_v2_test.exs` that reads `col_description` for both columns
and asserts the text contains `deprecated` and `do not drop`. It deliberately
does not pin the full wording, so future rewording (like this PR's) stays free,
and it passes against both old-text and new-text databases.

### NITPICK — Consumer-specific data remains (not changed)

The wording is neutral, but `Taxonomy.@default_group_order` still hardcodes the
nine Estonian group names (`Hinnapakkumine … Hooldusjuhend`), the confirm
dialog still lists the first and last of them, and a calibration comment in
`google_docs_client.ex` cites a specific "Joonised (tootmine)" template. The
"Standard groups" button therefore remains a seed for one consumer's taxonomy
presented as generic. Making the group set host-configurable is a feature, not
a fix for this PR; recorded so the neutral UI wording is not mistaken for
neutral behaviour.

## Testing

- [x] Unit/integration tests: new deprecation-comment test passes against the live test DB
- [x] No code paths changed; existing suite unaffected (see FOLLOW_UP / gate result in the commit)
- [x] Documentation updated (the PR itself)
