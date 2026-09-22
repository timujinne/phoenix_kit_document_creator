# Claude Review — PR #53

Reviewed the merge diff (`f924e75..691dc1d`) against core's
`PhoenixKit.Integrations.authenticated_request/4` (which the fallback
download goes through), Req's redirect handling, and `export_pdf/1`'s only
UI caller, `DocumentsLive`'s `export_pdf` event.

The image change is sound: `=s4096` caps the long side, so the area stays
below `insertInlineImage`'s 25 MP limit for every aspect ratio (the worst
case, a square, is 16.8 MP). The fallback's token handling holds up: the
link must be `https://docs.google.com`, and if that host redirects
elsewhere Req strips the `authorization` header (`redirect_trusted`
defaults to false), so the bearer token cannot leak off Google either way.

## Findings

### IMPROVEMENT - MEDIUM — any 200 from the export link is accepted as a PDF

The fallback took `{:ok, %{status: 200, body: pdf}} when is_binary(pdf)`
as success. `docs.google.com` is a browser-facing host, not an API
endpoint, and answers some auth and interstitial failures with a 200 HTML
page. Req leaves a `text/html` body as a binary, so that page would reach
the caller as `{:ok, pdf}` and be downloaded as a broken `.pdf`.

**Fixed.** The match now requires the `%PDF-` magic. Test: a 200 HTML
answer from the export link yields `{:error, :drive_export_too_large}`.

### IMPROVEMENT - MEDIUM — Req's default 15s receive timeout on the largest exports

Every document that reaches the fallback renders to more than 10 MB of
PDF, generated on request by `docs.google.com`. That is exactly the
request most likely to outlast Req's 15s `receive_timeout`, and a timeout
came back as `:drive_export_too_large`, which reads as a permanent
refusal.

**Fixed.** The fallback download passes `receive_timeout: 120_000`
(`@export_link_receive_timeout`). The success test asserts the option is
sent.

### IMPROVEMENT - MEDIUM — the admin UI can't deliver what the fallback fetches

`DocumentsLive` refuses to push any PDF over `@max_pdf_push_bytes`
(5 MB). The fallback runs only for PDFs over ~10 MB, so from the admin
page it now downloads the whole file and throws it away, then shows "PDF
is too large to download directly" where it used to show the
`:drive_export_too_large` message. The user-facing result is the same;
the cost is one extra large download per click. The fallback does help
API callers of `Documents.export_pdf/2` that don't go through the socket.

**Not fixed.** The real fix is the signed download endpoint already listed
in AGENTS.md's TODOs, whose trigger ("admins needing exports above the
cap") this PR now meets. A cheaper stopgap that skips the fallback for UI
callers would add an option to `export_pdf/1` just to be removed later.

### NITPICK — a non-string `exportLinks` value would crash

`URI.parse/1` raises `FunctionClauseError` on anything but a binary or a
`%URI{}`, so a `null` link from Drive would have crashed the caller
instead of falling to the `else`.

**Fixed.** `when is_binary(link)` on the first `with` clause. Test: a
`nil` link yields `{:error, :drive_export_too_large}`.
