# Claude Review — PR #48

Reviewed the merge diff (`2cc9794..6c66d21`, merged at `464fca8`) against
core 2.23.2's `MediaSelectorHelper.media_selector_url/2`,
`PhoenixKitWeb.Live.Users.MediaSelector` and core's sibling
`:uploads_parent_folder` hook, following `elixir:phoenix-thinking` and this
repo's `AGENTS.md`.

## Findings

### BUG - MEDIUM — the selector URL is built by hand, bypassing core's validation and encoding

`open_media_picker` called `media_selector_url/2` without `:scope_folder`, then
appended `"&scope_folder=" <> scope_folder` itself when the URL did not already
contain `scope_folder=`. The comment said core's helper "already adds it once
core supports it". That is wrong: the helper adds the param only when the
caller passes the option, so the `String.contains?/2` guard could never be
true and the hand-built branch always ran.

Core's helper has taken `:scope_folder` since 2.23.2, the version locked here.
It runs the value through `valid_uuid/1` before appending. The hand-built
branch skipped that check and did no URL encoding. A hook answer such as
`{:ok, "x&mode=multiple"}` was spliced into the query string raw and overrode
the selector's `mode`. The hook is host code, so this is not an attacker path,
but a hook returning a folder *name* or a struct id would quietly produce a
malformed URL.

The fallback is also pointless on an older core: the selector reads
`scope_folder` only from 2.23.2, so appending the param for an older core
changes nothing.

### IMPROVEMENT - MEDIUM — a hook that exits or throws crashes the LiveView

`scope_folder/2` had `rescue` but no `catch`. A host hook that does a
`GenServer.call` which times out, or that lazily creates a folder through a
process that is down, exits. That took the admin `DocumentsLive` down while an
admin was in the middle of filling in the create-document modal. Core's own
`:uploads_parent_folder` hook, which this one copies, treats "raises or exits"
as a fallback to the root.

### IMPROVEMENT - MEDIUM — the feature silently needs core 2.23.2; the docs didn't say so

The `:phoenix_kit` floor is `>= 2.21.3`. On any core below 2.23.2 the selector
ignores `scope_folder`, so the hook is called and its answer thrown away, with
no warning. The floor should not be raised for this one opt-in feature: the
pin conformance test keeps `>= 2.21.3` deliberately, and a host without the
config is unaffected. The requirement belongs in the moduledoc and the
CHANGELOG.

### NITPICK — "picked or uploaded" overstates the behaviour

The CHANGELOG and moduledoc said images "picked or uploaded" are filed into
the folder. Core attaches the folder only in the selector's upload path
(`maybe_attach_to_scope_folder/2`). Picking an existing file leaves it where it
is.

### NITPICK — the hook receives `""` rather than `nil` for "no template"

`template_file_id` was defaulted to `""` for `return_to`'s query encoding, and
the same value went into the hook's subject, although `scope_folder/2`'s spec
says `String.t() | nil`.

### NITPICK — tests

- `attachments_test.exs` was `async: true` while `put_env`-ing global
  application config, which any other async module reading that key would race
  on.
- The LiveView test's hook ignored its arguments, so actor uuid and template id
  threading was not checked end to end. The two LiveView tests also duplicated
  a 15-line `:sys.replace_state` setup.

## Checked and fine

- **Not in `mount/3`.** The hook runs only in the `open_media_picker` event,
  matching core's fix for its own pickers.
- **Arity dispatch.** The 3-arg form wins when both are exported;
  `Code.ensure_loaded?/1` precedes `function_exported?/3`, so a not-yet-loaded
  host module is not treated as missing.
- **Trashed / missing folders.** Core's `parse_scope_folder/1` re-validates the
  param against `Storage.get_folder/1` and ignores a trashed folder, so a stale
  hook answer degrades to the root instead of crashing the upload.
- **No other picker call sites.** `open_media_picker` is the only
  `media_selector_url/2` caller in the package.
