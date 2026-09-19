# Claude Review — PR #49

Reviewed the merge diff (`f8db35b..c5277fc`, merged at `76ea0b8`) against
`PhoenixKit.Integrations.authenticated_request/4` in core 2.28.2, Google's
Drive v3 403 reason vocabulary, and this repo's `AGENTS.md`, following
`elixir:phoenix-thinking`.

The shape of the PR is right: splitting Drive's 404 from its 403, and 403's
permission reasons from its rate-limit reasons, is exactly the distinction an
admin needs, and the follow-up commit's instinct — that the atom's message has
to read correctly in *both* the restore flow and the export flow — was the
right call. The findings below are about the edges around that core.

## Findings

### BUG - MEDIUM — the export flash now renders internal terms through `inspect/1`

`DocumentsLive`'s `export_pdf` error branch became
`assign(socket, error: Errors.message(reason))`. `Errors.message/1`'s
catch-all is `inspect/1` — deliberately, its moduledoc calls it
"useful-if-ugly" — and the reason on this path does not only come from
`export_pdf/1`'s own `{:error, atom}` returns. `export_pdf/1` re-emits
whatever `authenticated_request/4` hands it:

- `{:error, :not_configured}` from `get_credentials/1` — no Google
  connection selected, the single most likely failure on a fresh install
- `{:error, :token_refresh_failed}` / `{:error, :unauthorized}` from
  core's 401 retry
- a raw `Req` result: `{:error, %Req.TransportError{reason: :timeout}}`,
  `%Mint.TransportError{}`, …

Before the PR all of those rendered "PDF export failed. Please try again.".
After it, an admin whose Drive call times out sees
`%Req.TransportError{reason: :timeout}` in the error banner. The PR traded a
generic-but-human message for a specific-but-inhuman one on precisely the
cases it did *not* set out to name.

**Fixed.** `Errors.message/2` returns the caller's fallback for any term the
module has no clause for, and the LiveView passes its old generic string.
The mapped atoms — including the three this PR added — still render their own
message, so nothing the PR aimed at is lost.

### BUG - MEDIUM — `:drive_file_not_found`'s message asserts a deletion the code says it cannot conclude

The follow-up commit reworded the atom to "The file no longer exists in
Google Drive (it was deleted)", and `export_pdf/1`'s new `@doc` says the same:
"Drive returned 404 (the file was deleted)".

`Documents.move_to_deleted_folder/3` documents the opposite, at length:

> Gated on the row already being "lost" because Drive answers 404 (not 403)
> for a live file the current connection merely can't read — e.g. after
> re-pointing the Google connection or an unshare […]

So a 404 is *not* proof of deletion, and the module already relies on that
being true — it refuses to trash a row on a 404 unless an independent sync
pass confirmed the file is gone. The restore flow then appends "You can
permanently delete this record.", so the combined message tells an admin
whose connection was re-pointed that a file which still exists was deleted
and can be purged. The message the PR replaced ("File is missing in Google
Drive") was vague, but it was at least not making that claim.

**Fixed.** The message names both possibilities — "it was deleted, or this
Google connection cannot see it" — and `export_pdf/1`'s `@doc` carries the
same caveat, so the next caller to pattern-match `:drive_file_not_found`
reads it before assuming.

### IMPROVEMENT - HIGH — `classify_403/1`'s fallback is PDF-specific, but its comment advertises it as shared

The helper's own comment says it is "Shared by any caller that needs to tell
'the service account can't read this file' apart from 'try again later'",
while its `_other` clause returns `:pdf_export_failed`. The first caller to
take that invitation — `move_file/2`, `copy_file/2`, `fetch_thumbnail/1` all
have the same 403 problem — gets "Failed to export PDF from Drive" on a
failed move, with nothing in the diff to catch it. Two lists that must agree
(the whitelists and the fallback's meaning) with only a comment holding them
together.

**Fixed.** `classify_403/2` takes the caller's own generic reason;
`export_pdf/1` passes `:pdf_export_failed`. Unrecognized 403s now name the
operation that actually failed, whoever calls it.

### IMPROVEMENT - MEDIUM — "service account" is the wrong term for how this module authenticates

`:drive_forbidden` rendered "the service account cannot read it", and
`export_pdf/1`'s `@doc` said the same. This module has no service account:
credentials live in `PhoenixKit.Integrations` under the `"google"` provider as
an **OAuth connection**, selected by uuid in `document_creator_settings →
google_connection`, and refreshed through core's `refresh_access_token/1`.
"service account" was the only occurrence of the phrase in `lib/`. An admin
following that message goes looking in the Google Cloud console for an
IAM principal that does not exist, instead of at the connection picker in
`/admin/settings/document-creator`.

**Fixed.** "the connected Google account cannot read it", in the message, the
`@doc` and the helper comment.

### IMPROVEMENT - MEDIUM — the 403 whitelist drops two reasons that matter here

Checked `@drive_permission_403_reasons` against Drive v3's documented 403
reasons. Two gaps:

- `teamDriveMembershipRequired` — a plain permission failure on a shared
  drive, which is where a "documents" tree shared with a team normally
  lives. It fell through to the generic reason.
- `exportSizeLimitExceeded` — Drive's 403 for a Doc past its export size
  cap. This is an *export-specific* failure, so of every reason in the
  vocabulary it is the one `export_pdf/1` most needs to name, and the PR's
  stated goal is naming export failures. It fell through too, and the admin
  got "Failed to export PDF from Drive" with no hint that retrying or fixing
  sharing will never help.

**Fixed.** `teamDriveMembershipRequired` joins the permission list;
`exportSizeLimitExceeded` gets its own atom, `:drive_export_too_large`,
messaged as "The document is too large for Google Drive to export as PDF".
It sits next to the existing "PDF is too large to download directly" cap in
`DocumentsLive`, so the two size limits now read as a pair.

### NITPICK — the catalogues were hand-edited rather than extracted

The four new msgids were appended by hand: `default.pot` still pointed the
generic "PDF export failed. Please try again." at `documents_live.ex:688`,
a line whose `gettext/1` call the PR had removed. Harmless at runtime, but it
means `mix gettext.extract --merge priv/gettext` was not run.

Running it surfaced a larger, **pre-existing** problem that this PR did not
cause and that this review deliberately did not fix: the catalogues are 17
msgids behind `lib/`, so seventeen strings from earlier PRs are untranslated
in `et` and `ru` today, and the extractor fuzzy-matches wrong translations
onto twelve of them ("Refresh" → "Värskendamine…" / "Refreshing…",
"Failed to read the Google Doc" → "…dokumendi **loomine** ebaõnnestus" /
"…**creating** … failed"). Regenerating here would have shipped those as a
~2,000-line diff of wrong Estonian and Russian inside a release whose scope is
one error path. It needs a dedicated translation pass, on its own commit.

**Fixed only in scope:** the stale `:688` reference is corrected, and this
review's own msgids are hand-edited the same way the PR's were, with `en`,
`et` and `ru` filled in. The 17-msgid gap is recorded in `FOLLOW_UP.md` as
the next translation task.

### NITPICK — only the first `error.errors[]` entry is read, and only the classic error shape

`drive_403_reason/1` matches `error.errors[0].reason` and `error.reason`.
Two shapes it does not read: further entries in `errors[]` (Drive can return
several; in practice the first is the operative one), and Google's newer
envelope, `%{"error" => %{"status" => "PERMISSION_DENIED", "details" =>
[%{"reason" => …}]}}`.

**Not fixed.** Drive v3's REST endpoints emit the classic `errors[]` shape,
and the one newer-envelope case that matters here — insufficient OAuth scope —
arrives as `insufficientPermissions` in that classic shape, which is already
whitelisted. Adding speculative parsing for an envelope I cannot observe from
this repo would be guesswork in the one function whose whole job is being
precise. The fallback is correct and tested for anything it does not
recognise; if a real `PERMISSION_DENIED`-shaped body ever shows up in
`log_drive_error`'s output, add the clause then.

## Tests added

| File | Coverage |
|------|----------|
| `test/errors_test.exs` | `:drive_export_too_large` and the reworded atoms pinned by content; `message/2` returns the fallback for an unmapped atom, an `{:error, term}` wrapper, a struct and a tuple, and still prefers a mapped atom's message and a free-text upstream string. |
| `test/integration/google_docs_client_http_test.exs` | 403 `teamDriveMembershipRequired` → `:drive_forbidden`; 403 `exportSizeLimitExceeded` → `:drive_export_too_large`; the single-error `error.reason` shape → `:drive_rate_limited` (the PR added the clause but only tested the `errors[]` shape). |
| `test/phoenix_kit_document_creator/web/documents_live_test.exs` | `export_pdf` with a transport-level `{:error, term}` renders the generic message and never the raw term. |
