# Follow-up — PR #49

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-17 and released in 0.9.5.

### BUG - MEDIUM — `inspect/1` terms in the export flash

**Resolved.** `Errors.message/2` returns the caller's fallback for any term
the module has no clause for; `DocumentsLive`'s `export_pdf` branch passes
`gettext("PDF export failed. Please try again.")`, the string the PR removed,
whose `et` / `ru` translations were still in the catalogues. The fallback is
decided by comparing `message/1`'s answer with `inspect/1`'s, so there is no
second list of atoms to keep in sync with the clauses — a term that maps
never renders as its own inspect form. `{:error, reason}` is unwrapped first,
so `{:error, :token_refresh_failed}` reaches the fallback rather than
rendering as `":token_refresh_failed"`.

### BUG - MEDIUM — "(it was deleted)" overclaims a Drive 404

**Resolved.** The atom now reads "The file is not available in Google Drive —
it was deleted, or this Google connection cannot see it", and `export_pdf/1`'s
`@doc` spells out why (Drive answers 404, not 403, for a live file the current
connection is not allowed to see — the same fact
`Documents.move_to_deleted_folder/3` already gates its soft-delete on). The
restore flow's "You can permanently delete this record." hint is unchanged;
against the new wording it now reads as one of two possibilities rather than a
conclusion.

### IMPROVEMENT - HIGH — PDF-specific fallback in a helper documented as shared

**Resolved.** `classify_403/2` takes the caller's generic reason;
`export_pdf/1` passes `:pdf_export_failed`. The comment no longer promises
sharing it can't deliver.

### IMPROVEMENT - MEDIUM — "service account"

**Resolved.** The message, the `@doc` and the helper comment say "the
connected Google account". The phrase no longer appears in `lib/`.

### IMPROVEMENT - MEDIUM — missing 403 reasons

**Resolved.** `teamDriveMembershipRequired` added to the permission list;
`exportSizeLimitExceeded` gets `:drive_export_too_large` with its own message.
Both covered by HTTP tests.

### NITPICK — hand-edited catalogues

**Resolved in scope.** The stale `documents_live.ex:688` reference is
corrected and this review's msgids are filled in for `en` / `et` / `ru`.

**Left open — next translation task.** `mix gettext.extract --merge
priv/gettext` reports **17 new messages, 3 removed, 12 reworded (fuzzy)**
against `main`. The 17 are strings from earlier PRs that never reached the
catalogues, so they render in English under `et` and `ru` today. The 12 fuzzy
matches are wrong and must not be committed as-is — the extractor pairs
"Refresh" with "Värskendamine…" ("Refreshing…"), "All Languages" with "Keel"
("Language"), and "Failed to read the Google Doc" with the Estonian for
"Failed to *create* the Google Doc". Regenerating inside this release would
have meant a ~2,000-line diff of wrong Estonian and Russian, so:

1. run `mix gettext.extract --merge priv/gettext` on its own branch,
2. clear every `#, fuzzy` flag and translate those msgids properly,
3. land it as a translations-only commit, with no `lib/` changes in the diff.

Until then, hand-edit catalogue entries the way this PR and this follow-up
did, and keep the `#:` reference lines honest.

### NITPICK — first `errors[]` entry only, classic shape only

**Not fixed, deliberately.** Drive v3 emits the classic `error.errors[]`
shape, and the newer-envelope case that would matter here (insufficient OAuth
scope) arrives as `insufficientPermissions` inside it, already whitelisted.
An unrecognised body falls back correctly and is tested. Add the clause when
`log_drive_error` actually shows a `%{"error" => %{"status" => …}}` body.
