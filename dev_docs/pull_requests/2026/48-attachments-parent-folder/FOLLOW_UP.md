# Follow-up — PR #48

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-15 and released in 0.9.4.

### BUG - MEDIUM — hand-built selector URL

**Resolved.** `open_media_picker` passes the hook's answer to
`media_selector_url/2` as `scope_folder:` and the hand-appended branch and its
misleading comment are gone. Core validates the uuid and builds the query
string; a core older than 2.23.2 ignores the option, exactly as its selector
would have ignored the param. A new LiveView test configures a hook answering
`"x&mode=multiple"` and asserts no `scope_folder` param and `mode=single`.

### IMPROVEMENT - MEDIUM — exits and throws

**Resolved.** `scope_folder/2` gained a `catch kind, reason` clause alongside
the `rescue`, logging and returning `nil`. `attachments_test.exs` covers a hook
that exits and one that throws.

### IMPROVEMENT - MEDIUM — core 2.23.2 requirement undocumented

**Resolved in docs, floor unchanged.** The moduledoc, the 0.9.4 CHANGELOG entry
and `AGENTS.md` (Conventions → host hook, plus the Architecture tree) state
that the hook takes effect only on core 2.23.2+. Raising the `:phoenix_kit`
floor was rejected: the feature is opt-in, a host without the config sees no
change on any core, and the pin conformance test documents why the floor sits
at 2.21.3.

### NITPICK — "picked or uploaded"

**Resolved.** The CHANGELOG entry and moduledoc now say uploads, and state
that picking an existing file does not move it.

### NITPICK — `""` for "no template"

**Resolved.** The hook receives the raw `template_file_id` (possibly `nil`);
only `return_to`'s query encoding defaults it to `""`.

### NITPICK — tests

**Resolved.** `attachments_test.exs` is `async: false`. The LiveView hook sends
its arguments to the registered test process, which asserts the actor uuid
and template id. The shared modal setup moved into `put_scope_folder_hook/1`
and `open_media_picker_query/1`.
