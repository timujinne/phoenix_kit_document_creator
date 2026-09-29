# Claude Review — PR #60

Template image scope on core's folder hook contract; actor and activity
through core; a standard admin header trail across the Document Creator
pages; edit forms opening on the viewing language. Author: Dmitri Don.
Reviewed the merge diff (`9ed2f7e..88a6b78`) against core 2.40.1 (resolved)
and core's 2.38.0 CHANGELOG (the new floor).

Checked and correct:

- **The 2.38.0 floor matches what the code calls.** `Activity.log/3`,
  `PhoenixKitWeb.Actor`, `Storage.ResourceFolders` and
  `mount_multilang(open_on: :viewing_language)` all ship in core 2.38.0
  (#860), and none is feature-detected any more, so the floor is load-bearing.
  The pin keeps the compound `>= 2.38.0 and < 3.0.0` shape and the
  conformance test moved with it.
- **Dropping the local `rescue` around activity logging is safe.** Core's
  `log/1` and `log/3` rescue and catch `:exit`/`:throw` themselves; the
  removed wrappers only rescued, so nothing is lost.
- **`Attachments.scope_folder/2` keeps its contract.** `ResourceFolders.parent_uuid/4`
  reads the same `:attachments_parent_folder` env key, tries `/3` then `/2`,
  degrades a raise/throw/exit to `nil` with a log line, and now also drops a
  non-uuid answer (new test).
- **Trail assigns.** `page_section` / `page_section_path` / `page_crumbs` are
  read by core's admin layout; every page sets them in `handle_params/3`, so
  the disconnected render has them and no DB work moved into `mount/3`.
  Record crumbs use `Taxonomy.localized_name/2` with the same Gettext locale
  the Categories list uses, so a crumb and the list agree on a name.
- **Test helpers.** `with_request_locale/2` and `put_test_scope/2` both go
  through `Plug.Test.init_test_session/2`, which merges into an existing test
  session, so chaining them keeps both keys. The settings writes in
  `EditViewingLanguageTest` are sandboxed (no settings cache runs in the
  suite), so they don't leak.

## Findings

### IMPROVEMENT - MEDIUM — settings page section path bypasses `Paths`

`GoogleOAuthSettingsLive.handle_params/3` built the Settings crumb path
with a hand-written `Routes.path("/admin/settings")`. AGENTS.md makes
`PhoenixKitDocumentCreator.Paths` the single place paths are spelled, and
`paths_test.exs` pins every helper as prefix-safe. A path spelled inline
escapes that pin.

### NITPICK — stale "core older than 2.23.2" comment in `DocumentsLive`

The `:scope_folder` comment still warned that a core older than 2.23.2
ignores the option. The floor is 2.38.0 now, so the caveat can't happen.

### NITPICK — dead `Code.ensure_loaded?(PhoenixKit.Activity.Entry)` guard in `Taxonomy`

The PR removed the `Code.ensure_loaded?(PhoenixKit.Activity)` guards
because core always carries the module, but `fetch_cascade_uuids/2` kept
the same guard for `Activity.Entry`. The `from(e in PhoenixKit.Activity.Entry, …)`
query already compiles against the struct unconditionally, so the `else`
branch was unreachable.

### NITPICK — browser tab title on form pages is just "Edit" / "New type"

`page_title` now names only the leaf crumb and doubles as the `<title>`, so
two open edit tabs both read "Edit". That's core's trail contract (the bar
draws section + crumbs + title), and other modules' pages do the same. It
belongs in core's `live_title` if anywhere. Not changed.

### NITPICK — `open_on/1` duplicated in the category and type forms

Two identical two-clause functions. They're too small to be worth a shared
helper. Not changed.
