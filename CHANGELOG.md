## Unreleased

### Added

- Image placeholders in templates: `{{ image: name }}` for single images and `{{ images: name }}` for ordered lists. Variables detected via forked `extract_variables/1` returning `%{text: [...], image: [...]}`. Filled via PhoenixKit `MediaBrowser` selector in the create-document modal. Per-variable config (`default_width_px`, `separator`, `max_count`) editable via the `VariableConfigForm` component (read-only in v1; admin persistence is a follow-up). Substitution is a two-pass batchUpdate: text-first via `replaceAllText`, then images via `documents.get` + `DeleteContentRange` + `InsertInlineImage`. `find_image_tag_ranges/2` correctly handles multi-byte (UTF-16) prefix text via codepoint counting.
- `Variable.extract_string_variables/1` and `Variable.extract_image_variables/1` — public leaf detectors; `extract_variables/1` now returns `%{text: [...], image: [...]}` (breaking change within this module's public API).
- `Variable` struct gains a `config` field: `%{default_width_px: 400}` for `:image`, plus `separator` and `max_count` for `:image_list`. Stored in the existing `variables` jsonb column.
- `GoogleDocsClient.substitute_images/2` — walks `documents.get` content, finds every image tag occurrence by UTF-16 code unit offset, then issues a single `batchUpdate` with `DeleteContentRange` + `InsertInlineImage` per occurrence. Handles both single and list cases; inserts are ordered from last to first occurrence to preserve indices.
- `Errors` atoms: `:image_not_found`, `:image_url_not_public`, `:image_too_large`, `:image_insert_failed`, `:image_tag_not_found`.
- Admin fill form: `:image` variables render a "Choose image" button; `:image_list` variables render "Choose images" (multi-select). Sequential media picks accumulate via `picking_existing` URL param so earlier selections are not lost when returning from the `MediaBrowser`.

### Changed

- `Documents.detect_variables/1` now returns `{:ok, %{text: [...], image: [...]}}` — callers that expected a flat list must be updated.
- `Documents.create_document_from_template/3` orchestrates two ordered `batchUpdate` passes: text substitution first, image substitution second.
- Text-variable regex gains explicit negative-lookahead `(?!images?\s*:)` to encode the invariant that `{{ image: x }}` tags are never captured as text variables.

### Fixed

- UTF-16 code unit offset bug in `match_to_range/4`: `Regex.scan` returns byte offsets; all arithmetic now uses `binary_part/3` + `String.length/1` to convert to codepoint offsets, ensuring correct `startIndex`/`endIndex` values in documents containing multi-byte characters (e.g. Cyrillic).

### Known limitations (deferred to follow-ups)

- `VariableConfigForm` renders inline in `CreateDocumentModal` but has no `phx-change` persistence path — config edits don't write back to `Template.variables`. Operators get the defaults from `Variable.build_definitions/1` (400px width, newline separator, no max_count) and can override per-document but not per-template.
- `find_image_tag_ranges/2` uses Unicode codepoint counting (`String.length`) — correct for BMP characters including all Cyrillic / Latin extended / common CJK. Off-by-N for supplementary-plane codepoints (most emoji, rare CJK extensions) because UTF-16 represents them as surrogate pairs (2 code units per codepoint). Document authors typing emoji as prefix-to-tag may see shifted insertion offsets.
- No telemetry / observability around the image batch operations.
- E2E integration test (`test/integration/image_substitution_integration_test.exs`) requires `PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH` and a real dev Google account to run.
- The image-variable regex `~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/` is intentionally duplicated between `Variable` and `GoogleDocsClient` — each module owns its own parsing to avoid a shared dependency.

## 0.2.10 - 2026-05-05

### Added
- Per-template `:language` field — admins tag each template with a locale so parent apps can fill template variables in the matching language regardless of the admin's UI locale. Stored as a full BCP-47 code (e.g. `"en-US"`, `"et-EE"`, `"ja"`) — what `PhoenixKit.Modules.Languages.get_enabled_languages/0` returns; consumers wanting bare base codes can derive via `DialectMapper.dialect_to_base/1`. Documents intentionally don't store a language; they inherit from `template_uuid → templates.language` at fill time. Requires phoenix_kit core ≥ 1.7.105 (V110 column).
- `Documents.update_template_language/3` — set/clear a template's locale by `google_doc_id`. Pass `nil` or `""` to clear; otherwise a full locale code. Logs `template.language_updated` with `language_from`/`language_to` metadata; broadcasts `:files_changed` so connected admin LiveViews resync. Failure-side audit row written on `:not_found` so the activity feed reflects the attempt.
- `Documents.list_enabled_languages/0` — returns `[%{code, name}]` sorted by configured position, or `[]` when `PhoenixKit.Modules.Languages` is disabled or unreachable. Safe to call from LiveView mount — failure swallowed via narrow rescue clauses.
- `Documents.create_template/2` `:language` opt — defaults to the project's primary language from `PhoenixKit.Modules.Languages.get_default_language/0`; pass `nil` to leave unset; pass an explicit code to override. Lookup is guarded with `rescue` + `catch :exit` so a disabled Languages module never crashes template creation.
- `Schemas.Template.language_changeset/2` — focused single-field changeset honouring `validate_length(:language, max: 10)`. Used by both the create-time language stamp (`Documents.create_template/2`) and the post-create updater (`Documents.update_template_language/3`) so both write paths produce a clean `{:error, %Ecto.Changeset{}}` on oversized codes instead of a Postgrex `value too long` exception.
- Per-card popover language picker on the templates LV (card + list views). Native HTML `popover` API + CSS Anchor Positioning so the menu escapes the card's `overflow: hidden` clipping container without bespoke JS. Gated on templates tab + non-trash status + Languages module enabled. Documents tab and trash view do not render the picker.
- `Web.Helpers` module — `actor_opts/1` and `actor_uuid/1` lifted out of duplicated LV-private helpers. Canonical home for future LV cross-cutting helpers.
- `AGENTS.md` "Per-template locale" subsection under `Public API Layers` documenting the V110 schema, the new opts, and the doc-vs-template inheritance rule.

### Changed
- Both admin LiveViews cut over to mount→handle_info. Disconnected mount returns an empty shell with no DB / Settings / Integrations calls; the connected mount subscribes to PubSub (BEFORE the read, closing the broadcast-arrives-between-read-and-subscribe window) then triggers `:load_initial`/`:load_settings` to do the file-list reads and the initial Drive sync. Pre-fix the four-call burst per page load (folder_config + active_integration_uuid + list_connections + get_integration + connected? on the settings side; list_*_from_db ×4 + load_cached_thumbnails on the main LV) ran twice per session.
- `discover_folders/0` swapped from bare `Task.async/1` ×4 + `Task.await_many/2` to `Task.Supervisor.async_stream_nolink(PhoenixKit.TaskSupervisor, ...)`. Caller-LV exit now lets the supervisor clean the children automatically; per-task failure surfaces as `{:exit, reason}` in the stream so the explicit `catch :exit, _` block is gone.
- `verify_known_file/2` is O(1) via `MapSet.member?/2` on a `known_file_ids` assign rebuilt on `mount` + `:sync_complete`. Replaces the prior 4× `Enum.any?/2` shape (O(N) per event) that was noticeable on folders with thousands of files.
- Symmetric boot vs lazy legacy-migration paths. Removed the lazy on-read path's silent "any connected row of this provider" fallback that picked between multi-account installs (a user with `google:work` AND `google:personal` who had `"google"` in settings would have one of those chosen arbitrarily). Both paths now require an exact `provider:name` match; on no match the setting is cleared and the admin sees a clean "not configured" prompt. Both paths log a warning + activity row on failure so the audit trail covers both outcomes.
- `already_migrated?/0` prefers `Integrations.find_uuid_by_provider_name/1` (core 1.7.105+) via a `function_exported?/3` runtime guard + `apply/3` (the apply/3 dodges the compile-time "undefined function" warning on older cores). Falls back to the legacy `provider:name` lookup. The fallback can be deleted once `~> 1.7.105` is the floor in `mix.exs`.
- `Test.StubIntegrations` claim/release ownership. Concurrent calls from different live pids raise loudly with `:concurrent_stub_use` instead of silently racing the named ETS table. Test files using the stub MUST declare `async: false`. The named ETS table stays (cross-process LV→test boundary requires it) but `claim!/0` enforces async-false at runtime.
- `Documents.create_template/2`'s create-time language stamp now routes through `Template.language_changeset/2` instead of `update_all` — the V110 `max: 10` validation runs on the create path the same way it runs on `update_template_language/3`. Invalid language is logged and swallowed since the Drive doc is already created at that point; the user can still recover via the post-create picker.
- LV `set_template_language` event patches the `:templates` assign in place via a small `patch_template_language/3` helper instead of re-reading the entire `list_templates_from_db/0` per click. The self-broadcast is filtered out, so without the in-place patch the badge would lag until the next sync.
- Test-helper migration cutover. Per `dev_docs/migration_cleanup.md`, `test/test_helper.exs` was on the known-buggy `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)` pattern that silently stopped re-applying once `0` was recorded in `schema_migrations`. Swapped to `PhoenixKit.Migration.ensure_current/2` (core 1.7.105+) which passes a fresh wall-clock version to Ecto.Migrator on every boot.

### Fixed
- M1 (PR #11 follow-up): `mount/3` in both LVs no longer queries Settings / Integrations / DB — work moved to a `handle_info` so the disconnected mount is a fast empty shell and the read-bursts run once per session, not twice.
- M2 (PR #11 follow-up): `Test.StubIntegrations` cross-process safety — concurrent stub use across test pids now raises rather than silently racing.
- S2 / S3 / S5 (PR #11 follow-up): Task supervision, O(1) known-file lookup, helpers extraction (see Changed).
- §1.2 / §1.3 (PR #12 follow-up): boot-vs-lazy fallback symmetry; uuid-strict `already_migrated?/0` (see Changed).
- Dead `_ = changeset` line in `update_template_language/3`'s error branch (no-op carried over from an earlier iteration).

### Tests
- `test/schemas/template_test.exs`: 6 new tests for the V110 `:language` field (cast, base + full codes, nil/empty clearing, validate_length boundary), 4 new tests for `language_changeset/2` (cast + length + nil + cast-allowlist isolation), and a regression pin that `sync_changeset/2` does NOT cast `:language`.
- `test/integration/documents_test.exs`: 9 new tests for `Documents.update_template_language/3` — happy path, overwrite, clear (nil + empty string), `:not_found` error, `{:error, changeset}` on length validation, activity-log pinning the from→to metadata on success, the failure-side audit row on `:not_found`, and a PubSub broadcast assertion.
- `test/phoenix_kit_document_creator/web/documents_live_test.exs`: 3 new LV tests — `verify_known_file` rejects unknown ids, the connected-state `set_template_language` event threads `actor_uuid` through to the activity row, the clear-language path captures `language_from` correctly.
- `test/integration/active_integration_test.exs`: updated two pre-existing tests to match the new symmetric §1.2 behavior; added a new test for the "no exact match" failure branch.
- `test/support/stub_integrations.ex`: `get_integration/1` now returns the seeded connection's `data` map (matches real `PhoenixKit.Integrations` response shape) when the requested key matches a seeded `{provider, name}` pair. Closes a pre-existing footgun where the stub's degenerate response short-circuited tests meant to exercise exact-match paths.

### Known limitations
- Templates language picker uses CSS Anchor Positioning (`anchor-name` / `position-anchor` / `position-area`) — Chrome/Edge 125+, Safari 26+, **not Firefox** as of this release. Firefox renders the popover unanchored at the spec-default position (visibility still gated by `[&:not(:popover-open)]:hidden` so it's not a blocker, but the picker is unusable on Firefox until anchor positioning ships there).

## 0.2.9 - 2026-05-02

### Added
- `PhoenixKitDocumentCreator.migrate_legacy/0` — boot-time legacy migration callback covering both kinds of pre-uuid data: (1) the old `document_creator_google_oauth` settings key with locally-stored OAuth tokens → migrated into a `PhoenixKit.Integrations` row under `"google:default"`; (2) name-string `google_connection` references (`"google"` / `"google:my-name"`) → rewritten to the matching row's uuid. Idempotent across boots; activity emissions per migration (`action: "integration.legacy_migrated"`); errors logged but never crash boot. Host apps trigger via `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from `Application.start/2`.
- `GoogleDocsClient.active_integration_uuid/0` — uuid-shaped read accessor for the active Google integration row. Replaces the old `active_provider_key/0`. Detects legacy values, resolves them to the matching integration's uuid, rewrites the setting in place, and returns the uuid; subsequent reads are direct.
- `GoogleDocsClient.uuid?/1` — `@doc false` shared regex helper for "is this a uuid-shaped string". Used by both the lazy on-read path and the boot-time sweep.

### Changed
- **(potentially breaking — module API)** `GoogleDocsClient.active_provider_key/0` → `active_integration_uuid/0`. Returns the integration row's uuid (string) or `nil`, rather than a `provider:name` slug. Settings shape: `document_creator_settings.google_connection` is now a uuid, not a `provider:name` string. End-users transparent (auto-migrated on read + at boot); module consumers calling `active_provider_key/0` directly need to switch.
- Strict-UUID Integrations API. `do_migrate_oauth_credentials/1` creates the integration row via `add_connection/3` (the row-birth path) and writes migrated tokens via `save_setup(uuid, ...)`, replacing the old upsert-by-string-key flow. New `ensure_connection/2` helper handles `:already_exists` on re-runs by resolving the existing uuid.
- `get_credentials/0`, `connection_status/0`, and `authenticated_request/3` gate on uuid presence and return `:not_configured` cleanly when nothing's picked. `GoogleOAuthSettingsLive.mount/3` reads the uuid via the new accessor and handles `nil` gracefully.
- Cross-version compat: `ensure_connection/2`'s `:already_exists` resolve step is gated by `function_exported?(Integrations, :find_uuid_by_provider_name, 1)` — uses the V107 primitive when available, falls back to scanning `list_connections/1` on Hex `~> 1.7`. The `migrate_legacy/0` `@impl PhoenixKit.Module` annotation was dropped because the published behaviour doesn't list it; the orchestrator dispatches by `function_exported?/3` regardless.
- After a successful credentials migration the legacy `document_creator_google_oauth` row is reset to `%{}` so plaintext `client_secret` / `access_token` / `refresh_token` don't survive the move to encrypted Integrations storage. Failure to clear is best-effort with a warning log; doesn't roll back the migration.
- `phx-disable-with` added to the three Drive folder-browse buttons in `GoogleOAuthSettingsLive` (templates / documents / deleted path) — multiple rapid clicks no longer spawn concurrent `Task.start_link` calls.
- Lazy-read crash hardening: `find_uuid_for_data/2` and `rewrite_setting/1` in `GoogleDocsClient` (both run from `active_integration_uuid/0` on every legacy-shape request) now `try/rescue`. Backend / Settings failure logs `Logger.warning` with exception type and falls through cleanly instead of crashing the LV. Both rescues exclude `Exception.message/1` to avoid leaking provider strings or query bindings embedded in Ecto error structs.
- Observability: `resolve_via_list_connections/1` and `log_migration_activity/2` now log exception type before swallowing — operators investigating "why is the resolver returning `:resolver_failed`" or "why is my activity feed empty after upgrade" have something to grep.
- `@version` now derives from `Mix.Project.config()[:version]` at compile time so the runtime function can't drift from the declared package version.
- Test suite migration shim removed. `test_helper.exs` now runs `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, all: true, log: false)` — the same call host apps use in production. The 180-line hand-rolled `Test.Migration` (creating tables that core already owns: `phoenix_kit_settings`, `phoenix_kit_activities`, `phoenix_kit_doc_*`) is gone. Same pattern as `phoenix_kit_ai`.
- Tests dependent on the strict-UUID `add_connection/3` return shape (`{:ok, %{uuid: _}}`) are tagged `@tag :requires_unreleased_core` and excluded by default; opt in via `mix test --include requires_unreleased_core` once the matching core version is published. Standalone `mix test` against Hex `~> 1.7` now exits clean.

### Fixed
- `mix precommit` failures inherited from the strict-UUID flip — `find_uuid_by_provider_name/1` (undefined in Hex `~> 1.7`) caused a hard `call_to_missing` dialyzer error; `@impl PhoenixKit.Module` on `migrate_legacy/0` warned because the published behaviour doesn't declare the callback. Both addressed via `function_exported?/3` runtime gating; `mix precommit` (compile + format + credo + dialyzer) now exits clean.

### Tests
- New integration coverage in `test/integration/active_integration_test.exs` (271 lines): `active_integration_uuid/0` modern-shape passthrough, legacy `"google:name"` exact match, bare `"google"` first-row fallback, unresolvable target → setting cleared; `get_credentials/0` / `connection_status/0` / `authenticated_request/3` `:not_configured` gates; `migrate_legacy/0` combined entry point — `{:ok, summary}` shape, credentials migration converts OAuth → integration row, credentials short-circuit on existing row, reference sweep rewrites string → uuid, idempotency, legacy oauth key wiped after success.
- Test stub additions: `StubIntegrations.list_connections/1` and `seed_connection!/2` (used by `migrate_legacy_connection/1`'s fallback path); `connected!/1` now also seeds a sentinel uuid in `document_creator_settings.google_connection` so existing tests that only call `connected!()` keep working under the new resolver.

## 0.2.8 - 2026-04-30

### Added
- `PhoenixKitDocumentCreator.Errors` — atom dispatcher with one literal `gettext/1` clause per atom (28 atoms). Centralises error translation for the public API; consumers call `Errors.message(reason)` at the UI/API boundary. Same shape as `PhoenixKitSync.Errors` and `PhoenixKitLocations.Errors`. Documented in README.
- SSRF guard on `GoogleDocsClient.fetch_thumbnail_image/1` — `validate_thumbnail_url/1` allowlists `*.googleusercontent.com` / `*.google.com` host suffixes; rejects metadata service (169.254.169.254), loopback, RFC1918, look-alike hosts, non-`http(s)` schemes. Pinned with 8 unit tests.
- Redirect block on the thumbnail fetch — `Req.get/2` is called with `redirect: false` so a 302 from a Google CDN host to an internal IP can't bypass the SSRF allowlist. Pinned with a `Req.Test`-stubbed end-to-end test.
- LiveView test infrastructure: `Test.Endpoint`, `Test.Router`, `Test.Layouts` (with stable flash IDs), `LiveCase`, on-mount hooks, `ActivityLogAssertions` helper, `Test.StubIntegrations` ETS-backed integrations stub.
- `phx-disable-with` on every async + destructive button (refresh, create, modal create, file actions, export PDF, restore, delete, save folder settings, unfiled actions).
- AGENTS.md "What This Module Does NOT Have (by design)" section anchoring deliberate non-features.

### Changed
- **(potentially breaking)** `GoogleDocsClient` and `DriveWalker` now return tagged atoms (`:folder_search_failed`, `:create_folder_failed`, `:create_document_failed`, `:move_failed`, `:get_file_parents_failed`, `:copy_failed`, `:pdf_export_failed`, `:thumbnail_link_failed`, `:thumbnail_fetch_failed`, `:list_files_failed`) on the error branch instead of raw `{:error, "Foo failed: #{inspect(body)}"}` strings. Consumers matching on the string form must switch to atoms (or call `Errors.message/1` to translate).
- `Document.creation_changeset/2`, `Document.sync_changeset/2`, and `Template.sync_changeset/2` now `validate_length(:name, max: 255)`. Over-long names return a clean `{:error, %Ecto.Changeset{}}` instead of raising `Ecto.Adapters.SQL` exceptions.
- `Documents.fetch_thumbnails_async/2` runs under a single supervised parent task in `PhoenixKit.TaskSupervisor` with `Task.async_stream/3` `max_concurrency: 8`. Pre-fix opening a 500-file folder fired 500 unsupervised `Task.start/1` calls.
- `DocumentsLive.mount/3` subscribes to `"document_creator:files"` BEFORE the initial DB read, closing a race window where a `:files_changed` broadcast could be dropped between read and subscribe.
- Activity logging now lands a `db_pending: true` audit row on the error branch of every user-driven mutation (`create_template`, `create_document`, `delete_*`, `restore_*`, `export_pdf`, `set_correct_location`, `create_document_from_template`). Pre-fix a Drive outage erased admin clicks from the audit feed.
- `Task.start/1` → `Task.start_link/1` in `:sync_from_drive` and `:load_drive_folders` LV handlers — orphan tasks now die with the LV instead of running unsupervised after the tab closes.
- `try/rescue` around the `:perform_file_action` backend call so a Drive API raise (econnrefused, HTTP timeout) doesn't crash the LV and wedge `pending_files` on remount.
- Drive API error responses are now logged at 500-char truncation via `log_drive_error/2` instead of being serialised in full into the error tuple.
- `discover_folders/0` timeout cleanup now uses `catch :exit, _` instead of `rescue` — `Task.await_many/2` signals timeouts via `exit/1`, so the previous `rescue` clause never fired and the LV crashed instead of hitting the nil fallback.
- `extract_content_type/1` logs at `:debug` when a Drive thumbnail's content-type falls outside the `~w(image/png image/jpeg image/webp image/gif)` allowlist and is downgraded to `image/png`.
- `handle_info` catch-all in both LiveViews promoted from silent drop to `Logger.debug` so stray PubSub / fixture messages stay observable when debugging.

### Fixed
- Removed deprecated `Variable.extract_from_html/1` (was `@doc false` + `@deprecated` since the Google Docs pivot).
- `enabled?/0` now adds `catch :exit, _ -> false` for sandbox-shutdown resilience.
- README: new `PhoenixKitDocumentCreator.Errors` section listing the error atoms emitted by the public API and showing the canonical translate-at-the-boundary pattern.

### Tests
- 161 → 376 tests, 0 failures, 10/10 stable runs.
- Production coverage: ~52% → **77.92%** via built-in `mix test --cover` (no Mox / no excoveralls). `mix.exs` adds `test_coverage: [ignore_modules: [...]]` so the percentage reports production-only code.

## 0.2.7 - 2026-04-22

### Added
- `GoogleDocsClient.DriveWalker` module — paginated `list_files/1` / `list_folders/1` and recursive `walk_tree/2` (BFS, `pageSize: 1000`, `nextPageToken` looping, batched `'a' in parents or …` queries chunked at 40 IDs per request). Both folder discovery and file listing now cost `O(ceil(N / 40))` Drive calls per BFS level instead of `O(N)` sequential list calls.
- `Documents.register_existing_document/2` and `register_existing_template/2` — DB-only upsert for Drive files the caller has already created (e.g. consumers that organise files into `documents/order-N/sub-M/`). Validates `google_doc_id` via `validate_file_id/1`, validates `template_uuid` via `foreign_key_constraint`, uses `maybe_put/3` so re-registration without optional fields preserves existing values. Opts: `:actor_uuid` (activity log), `:emit_pubsub` (default `true`).
- `Documents.pubsub_topic/0` and `Documents.broadcast_files_changed/0` — single source of truth for the `"document_creator:files"` topic; bulk callers can pass `emit_pubsub: false` and broadcast once at the end.
- `create_document_from_template/3`: new `:parent_folder_id` and `:path` options for placing documents in consumer-managed subfolders.
- `foreign_key_constraint(:template_uuid)` on `Document` changeset — invalid template UUIDs now return a changeset error instead of raising.
- Catch-all `handle_info/2` in `GoogleOAuthSettingsLive` to prevent crashes on unexpected messages (Task supervisor signals, stray PubSub traffic).

### Changed
- `sync_from_drive/0` recursively walks both managed trees and upserts every Google Doc found (including those nested in subfolders) with its actual parent `folder_id` and resolved `path`.
- `classify_by_location/5` accepts a `MapSet` of enumerated folder IDs so files in descendant subfolders stay `:published` instead of being reclassified as `:unfiled`.
- Reconcile drops the implicit "file must be in managed root" rule — any descendant of a managed folder is treated as `:published`.
- `list_folder_files/1` and `list_subfolders/1` on `GoogleDocsClient` now delegate to `DriveWalker` — full pagination instead of the previous silent 100-item cap.
- Narrowed `Documents.default_managed/2` rescue from bare `_` to a targeted set (`ArgumentError`, `KeyError`, `MatchError`, `BadMapError`, `DBConnection.ConnectionError`, `Postgrex.Error`) so future `FunctionClauseError` / `RuntimeError` bugs propagate instead of being silently swallowed.

### Fixed
- Silent data loss past 100 items in `list_folder_files/1` / `list_subfolders/1` — both now fully paginate.
- `test_helper.exs` no longer crashes on module load when `psql` is missing from `PATH` (sandboxes / minimal CI images); degrades to the connect-attempt branch instead.
- `test_helper.exs` PubSub supervisor bootstrap now raises on unexpected errors instead of silently ignoring them.

## 0.2.6 - 2026-04-15

### Added
- Trash tab in DocumentsLive with Active/Trash status toggle (auto-hidden when empty)
- Restore from trash — `restore_template/2`, `restore_document/2`, and `list_trashed_*_from_db/0`
- Pending spinner overlay on cards during async delete/restore (layout-stable)
- `phx-disable-with` on New Template / New Document buttons

### Changed
- Sort document/template lists by `inserted_at DESC` (workaround; see AGENTS.md TODO for `drive_modified_at`)
- Remove delete confirmation popup — soft delete is recoverable from Trash
- Refactor delete flow into data-driven `action_spec/2` shared with restore

### Fixed
- PDF download: anchor now appended to DOM before `.click()` (fixes Firefox)
- Catch-all `handle_info/2` to avoid crashes on unexpected messages

## 0.2.5 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.2.4 - 2026-04-09

### Fixed
- Fix 3 dialyzer errors (invalid contract, pattern match issues)
- Fix sync_from_drive error swallowing (now logs reason)
- Fix schema field access (direct instead of Map.get)

### Changed
- Refactor create_document: extract persist_created_document/5
- Remove dead list_templates/list_documents (replaced by DB versions)
- Graceful DB insert failure (Drive doc still returned, sync picks it up)

## 0.2.3 - 2026-04-06

### Changed
- Migrate Google OAuth credentials to centralized PhoenixKit.Integrations system
- Remove duplicate OAuth code (authorization, exchange, refresh, userinfo)
- Simplify settings LiveView — OAuth flow now handled by Integrations core
- Declare `required_integrations: ["google"]`
- Update dependencies to latest versions

## 0.2.2 - 2026-04-02

### Added
- Add `css_sources/0` callback for Tailwind CSS scanning of module components

### Changed
- Upgrade dependencies

## 0.2.1 - 2026-03-30

### Added
- Add soft delete for documents and templates — files move to deleted folders instead of permanent removal
- Add configurable folder paths and names with Google Drive folder browser
- Add `ensure_folder_path/2` — walks nested Drive paths, creating folders as needed
- Add `move_file/2` to GoogleDocsClient (Drive API PATCH with addParents/removeParents)
- Add `list_subfolders/1` for the Drive folder browser
- Add `validate_file_id/1` to prevent URL path injection in Drive API calls
- Add `get_folder_config/0` for reading folder path + name settings
- Add loading spinner for thumbnail placeholders
- Add delete button (trash icon) on card and list views with confirmation dialog
- Add flash feedback on successful delete
- Add folder browser modal with breadcrumb navigation to settings page
- Add tests for `validate_file_id/1` and `move_file/2` input validation

### Changed
- Parallelize folder discovery with `Task.async` + `Task.await_many` (was sequential)
- Make folder browser loading async via `Task.start` (no longer blocks LiveView)
- Whitelist `browser_field` values to prevent atom exhaustion
- Guard `browser_back` against invalid index
- Strip charset from content-type header in `extract_content_type`
- Update modal template cards to match main page card styling (border, shadow, flex layout)

### Fixed
- Fix `FunctionClauseError` in thumbnail loading — handle map header format from Req >= 0.5

### Removed
- Remove orphaned `editor_scripts.ex` (dead code from GrapesJS removal)

## 0.2.0 - 2026-03-29

### Changed
- Replace local editor architecture (GrapesJS, TipTap, pdfme) with Google Docs API
- Replace ChromicPDF/Gotenberg PDF generation with Google Drive API export
- Rewrite `Documents` context for Google Drive operations (list, create, copy, variable substitution)
- Simplify admin tabs from 13 to 3 (parent + documents + templates)
- Simplify `Paths` module to 4 helpers (index, templates, documents, settings)
- Rewrite `CreateDocumentModal` for Google Docs workflow

### Added
- Add `GoogleDocsClient` — OAuth 2.0, Google Docs API, Google Drive API
- Add `GoogleOAuthSettingsLive` — admin settings page for connecting Google account
- Add `google_doc_id` column to templates, documents, and headers/footers (PhoenixKit V88 migration)
- Add unit tests for `GoogleDocsClient`

### Removed
- Remove GrapesJS editor and all JS hooks (`editor_hooks.js`, ~1500 lines)
- Remove `TemplateEditorLive`, `DocumentEditorLive`, `HeaderFooterEditorLive` LiveViews
- Remove `HeaderFooterLive` listing page
- Remove `EditorPanel` and `EditorScripts` components
- Remove `EditorPdfHelpers` (ChromicPDF/Gotenberg PDF generation)
- Remove `DocumentFormat` module (legacy JSON interchange format)
- Remove `TestingLive`, `EditorPdfmeTestLive`, `EditorTiptapTestLive` (editor comparison pages)
- Remove `chromic_pdf` and `solid` dependencies

## 0.1.2 - 2026-03-25

### Fixed
- Fix all credo warnings (alias ordering, Enum.map_join, cyclomatic complexity)
- Fix all dialyzer warnings (Solid.render pattern match, dead code branches)
- Flatten nesting in ChromeSupervisor using `with`

### Removed
- Remove obsolete `mix phoenix_kit_document_creator.install` task

### Added
- Add PDF generation options research document

## 0.1.1 - 2026-03-25

### Added
- Add MIT LICENSE file
- Add CHANGELOG.md
- Add `@source_url` and GitHub links to mix.exs package metadata
- Add `precommit` mix alias (compile + quality)
- Add PR documentation template
- Add Versioning & Releases section to AGENTS.md

## 0.1.0 - 2026-03-24

### Added
- Extract Document Creator from PhoenixKit into standalone `phoenix_kit_document_creator` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Template` schema (HTML, CSS, GrapesJS native data, paper size, slug)
- Add `Document` schema (rendered HTML/CSS, baked header/footer content)
- Add `HeaderFooter` schema (type discriminator: header/footer)
- Add GrapesJS drag-and-drop template editor with LiveView hooks
- Add document editor for post-creation editing
- Add ChromicPDF integration for PDF export with lazy Chrome startup
- Add Solid (Liquid syntax) template variable substitution
- Add admin LiveViews: template editor, document editor, listings, header/footer editor
- Add drag/resize boundary constraints and coordinate offset fixes
- Add GrapesJS panel customization, theme sync, and canvas centering
