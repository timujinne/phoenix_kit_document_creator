# PR #11 Follow-Up — Quality sweep + re-validation

PR #11 is the module-wide quality sweep on top of `BeamLabEU:main`.
The original sweep (Phase 1 + Phase 2) shipped 2026-04-25. Batch 2
re-validation 2026-04-26 against the post-Apr workspace AGENTS.md
pipeline closed the structural deltas the original sweep predates.

## Original sweep — 2026-04-25 (canonical batch)

Phase 1 — PR triage. Eight prior PRs (#1, #2, #3, #5, #6, #8, #9, #10)
re-read end-to-end. Two had live findings:

- ~~**PR #2 follow-up — thumbnail concurrency unbounded**~~ — fixed in
  `e6d7dd0` ("Fix PR #2 follow-up: bound thumbnail concurrency").
  `Documents.fetch_thumbnails_async/2` switched from raw `Task.start/1`
  to a single supervised parent task running `Task.async_stream/3`
  with `max_concurrency: 8` under `PhoenixKit.TaskSupervisor`. Opening
  a folder with hundreds of files no longer fans out hundreds of
  simultaneous Drive requests.
- ~~**PR #9 follow-up — silent `handle_info` catch-all + bare `apply` in
  `:perform_file_action`**~~ — fixed in `9c97300` ("Fix PR #9 follow-up:
  handle_info catch-all logging + backend try/rescue").
  `documents_live.ex` catch-all now logs at `:debug`; the
  `:perform_file_action` handler wraps the backend call in `try/rescue`
  so a Drive API exception keeps the LV alive and surfaces a translated
  failure flash instead of crashing.

The other six PRs (#1, #3, #5, #6, #8, #10) had no live findings;
stub FOLLOW_UPs were committed in `13361c7`.

Phase 2 — quality sweep. Commits:

- **`3686c51`** — C1 + C3 + C4: `PhoenixKitDocumentCreator.Errors`
  atom dispatcher (28 atoms with literal-gettext `message/1` clauses),
  `log_drive_error/2` 500-char body truncation in GoogleDocsClient and
  DriveWalker, AGENTS.md additive pass with the canonical "What This
  Module Does NOT Have" section pinning no-local-editor / no-local-PDF
  / no-Oban-scheduler / no-retry-layer / no-telemetry deliberate
  non-features (the Google Docs pivot makes a lot of old PR review
  findings N/A).
- **`7d5dfa7`** — C5: `phx-disable-with` on every async + destructive
  button (refresh, create, modal create, file actions in toolbar +
  trash row, export PDF, restore, delete).
- **`e72e686`** — C7: full LiveView test infrastructure (Test.Endpoint,
  Test.Router, Test.Layouts with flash-rendering divs, LiveCase, hooks,
  sandbox setup, ActivityLogAssertions helper, test-only Postgres
  migration that creates the module's tables + `phoenix_kit_activities`
  + `uuid_generate_v7()`).
- **`2c60f11`** — C8 + C9 + C10: per-atom Errors EXACT-string pin tests
  (every atom in `@type error_atom`), per-action activity-log tests for
  every CRUD mutation that's reachable without HTTP stubs, LiveView
  smoke tests for documents_live + create_document_modal.
- **`1157d33`** — C11 delta audit: pgcrypto extension added to
  `test_helper.exs` next to uuid-ossp (uuid_generate_v7's
  `gen_random_bytes` dependency was implicit — would break on a fresh
  `createdb`); modal phx-disable-with pin tests.
- **`15ac11a`** — C12 re-validation Round 1: `Task.start` →
  `Task.start_link` in 2 LV handlers (orphan task fix), @spec backfill
  on `Variable` + `Paths` + 5 most-called GoogleDocsClient functions.
- **`2bc8a57`** — final tidy: format + credo nested-alias fix.
- **`ff5666b`** — backfill `@spec` on remaining GoogleDocsClient
  public functions.
- **`8453ac5`** — document PDF download endpoint + inline-script Hook
  migration as TODOs in AGENTS.md.
- **`10cb595`** — C12.5 deep-dive: 7 in-scope fixes — SSRF guard on
  Drive-supplied thumbnail URLs (`validate_thumbnail_url/1` rejecting
  RFC1918 / loopback / link-local / `*.local` / non-http(s) schemes),
  audit-log gap on bulk register API, mount race fix
  (`subscribe → list_*_from_db` order), dead `extract_from_html/1`
  removal, commented-out `def` deletion, README missing Errors API
  section, sync error log lacks resource-uuid context.

**Final state of the original sweep**: 161 → 213 tests, 10/10 stable
runs, `mix precommit` 0 errors. Push permission noted: `gh repo view
--json parent` confirmed `BeamLabEU/phoenix_kit_document_creator`
parent fork relationship despite the local repo having no `upstream`
remote configured (this trap was added to the workspace AGENTS.md).

## Batch 2 — re-validation 2026-04-26

Phase 1 PR triage re-verified clean — all eight PRs' fix sites still
hold in current `lib/`. One stale FOLLOW_UP description in
`10-nested-subfolders-register-api/FOLLOW_UP.md` was corrected: the text
claimed an `:erlang :queue` ADT swap in commit `56d5c66`, but the
actual implementation uses level-batched chunking (also O(N) — same
end effect, different mechanism). Doc-only fix; no code change.

Phase 2 closed the C12 deltas the original sweep predates:

- ~~**Catch-all `handle_info` in `GoogleOAuthSettingsLive` was silent**~~
  — clause at `web/google_oauth_settings_live.ex:273` previously dropped
  unexpected messages with no trace. Promoted to `Logger.debug` matching
  the `documents_live.ex:224-226` precedent. Without this, stray PubSub
  broadcasts or test-fixture messages are impossible to debug.
- ~~**Error-path activity logging gap on 8 user-driven mutations**~~ —
  `create_template`, `create_document`, `delete_document`,
  `delete_template`, `restore_document`, `restore_template`,
  `export_pdf`, and `set_correct_location` all logged only on `:ok`.
  When Drive is down or folders are unreachable, the user-initiated
  click was erased from the activity feed. Added a private helper
  `log_failed_mutation/4` that lands a `db_pending: true` audit row
  on every error branch (matching the existing precedent at
  `documents.ex:615-621` for `create_document_from_template`). PII-safe
  metadata only (`google_doc_id`, `name`); the technical reason stays
  in the surrounding `Logger.error`.
- ~~**Stale `:queue` claim in PR #10 FOLLOW_UP**~~ — wording fix in
  `dev_docs/pull_requests/2026/10-nested-subfolders-register-api/FOLLOW_UP.md`.

### Tests added (Batch 2 — 2026-04-26)

- `test/integration/activity_logging_test.exs` — 8 new error-path
  pinning tests, one per mutation, exercising the deterministic
  `:not_configured` / `:*_folder_not_found` failure paths that fire in
  the test env without HTTP stubs. Each test asserts the row's
  `actor_uuid`, `db_pending: true` flag, `resource_type`, and that
  PII-leak fields like `size_bytes` are absent on the error path.
- `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs`
  (new file) — mount smoke test pinning the page header, plus a
  `handle_info` catch-all test using `capture_log` at `:debug` (with
  per-describe Logger level bump because `config/test.exs` defaults to
  `:warning`). Pins both the survival-after-stray-message behaviour and
  the actual log line.

### Dismissed (re-classified after second-pass review)

These items were initially flagged by C12 agents but, after verifying
against AGENTS.md:472 ("agents overstate; verify before acting") and
the surrounding code, are not real findings:

- **Atom-bombing hardening at `google_oauth_settings_live.ex:226`** —
  `String.to_existing_atom(field)` is gated by
  `if field in @valid_path_fields` on the line immediately above. The
  whitelist already mitigates the threat; the agent's concern was
  hypothetical ("if a future refactor removes the guard").
- **Broad `rescue _e ->` in `documents_live.ex:120-123` and `203-214`** —
  both wrap external Drive/Docs API calls and carry explicit comments
  justifying why catching everything is correct (sync mid-fail is
  safe, file-action crash would wedge `pending_files` on remount).
  AGENTS.md:472 lists this exact pattern as typical false-positive
  noise.
- **Hardcoded `secret_key_base` in `config/test.exs:28`** — test-only
  config, not loaded in prod / dev. Same shape as every other
  phoenix_kit module's test config.
- **`status_label/1` helper refactor** — current LV uses
  `gettext("lost")` / `gettext("unfiled")` on literal strings, status
  values are pinned by schema `validate_inclusion`. New statuses
  would require a migration anyway — this is a refactor without
  functional improvement.

### Files touched (Batch 2)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | `require Logger`; promoted catch-all to `Logger.debug` |
| `lib/phoenix_kit_document_creator/documents.ex` | `log_failed_mutation/4` helper + `:error`-branch logging on 8 mutations |
| `test/integration/activity_logging_test.exs` | +8 error-path tests |
| `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs` | new file: 2 tests (mount + handle_info catch-all) |
| `dev_docs/pull_requests/2026/10-nested-subfolders-register-api/FOLLOW_UP.md` | corrected stale `:queue` description |

### Verification (Batch 2)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 213 → 223 tests (+10), 0 failures
- 10/10 stable runs (see Final checklist below)
- Pre-existing log noise (`Folder discovery failed: {:error, :not_configured}`)
  unchanged — Drive isn't configured in test env, expected

## Batch 3 — fix-everything 2026-04-26

User pushed back on the initial Batch 2 "Skipped (with rationale)"
section, citing `feedback_followup_is_after_action.md`
("FOLLOW_UP.md is an after-action report, not a TODO parking lot —
we fix everything we find") and `feedback_review_verdicts.md`
("never silently classify as resolved"). Re-classified each item:
genuine dismissals moved to "Dismissed (re-classified after second-
pass review)" above; real findings closed in this batch.

### Real bug surfaced by edge-case testing

- ~~**`Document.creation_changeset/2` and both `sync_changeset/2` (Document + Template) missing `validate_length(:name, max: 255)`**~~
  — the full `Document.changeset/2` has it, but the upsert / register
  paths use `creation_changeset/2` and `sync_changeset/2` which
  skipped the validation. A 256-byte name therefore raised
  `Ecto.Adapters.SQL` exceptions instead of returning `{:error, %Ecto.Changeset{}}`.
  This is the canonical AGENTS.md "Coverage push pattern #1" trap —
  tightening the changeset contract converts raises to clean error
  tuples (a real behaviour improvement). Pinned by 5 new schema tests
  (`Document.sync_changeset/2` + `Document.creation_changeset/2` +
  `Template.sync_changeset/2` × {255-char boundary, 256-char rejection,
  Unicode round-trip}) plus the integration tests below.

### Edge-case tests added

- **`Variable` helpers** (`test/phoenix_kit_document_creator_test.exs`):
  6 new tests — duplicate dedup, malformed-placeholder rejection,
  Unicode (ASCII-only `\w` regex behaviour pinned), non-binary input,
  5K-char input, Unicode round-trip in `humanize/1`, empty list
  in `build_definitions/1`.
- **`register_existing_document/2`** (`test/integration/documents_test.exs`):
  6 new tests — Unicode name round-trip, 256-char name rejection (now
  a clean changeset error after the schema fix), 255-char boundary
  acceptance, SQL-metacharacter literal handling, empty-name
  normalize-step rejection (`{:error, :missing_name}` atom — pinned
  the actual return shape so a future refactor that pushes this into
  the changeset doesn't silently change the public API).
- **`CreateDocumentModal`** (`test/phoenix_kit_document_creator/web/components/create_document_modal_test.exs`):
  5 new tests — Unicode variable name rendering, multiline vs text
  type rendering, long template name surfaces in form value,
  `creating: true` disables the submit button, Cancel button does NOT
  carry `phx-disable-with` (UI-state-only — pinning the rule
  explicitly).

### Files touched (Batch 3)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/schemas/document.ex` | added `validate_length(:name, min: 1, max: 255)` to `sync_changeset/2` and `creation_changeset/2` |
| `lib/phoenix_kit_document_creator/schemas/template.ex` | added `validate_length(:name, min: 1, max: 255)` to `sync_changeset/2` |
| `test/phoenix_kit_document_creator_test.exs` | +6 Variable edge-case tests |
| `test/integration/documents_test.exs` | +6 register edge-case tests |
| `test/schemas/document_test.exs` | +5 changeset length/Unicode tests |
| `test/schemas/template_test.exs` | +3 sync_changeset tests |
| `test/phoenix_kit_document_creator/web/components/create_document_modal_test.exs` | +5 modal validation tests |

### Verification (Batch 3)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 223 → 247 tests (+24), 0 failures
- 5/5 stable runs at 247
- `mix format` + `mix credo --strict` + `mix dialyzer` — all clean

## Batch 4 — happy-path coverage push 2026-04-26

User confirmed the Batch 4 retrofit was worth doing on the basis that
it adds zero deps and converts the test suite from "structural
baseline" to "real refactor safety net" for the 11 previously-
uncovered drive-bound actions.

### Production change

**`GoogleDocsClient` — backend resolver.** Two HTTP entry points now
read optional config so tests can route through stubs:

- `defp integrations_backend/0` resolves `Application.get_env(:phoenix_kit_document_creator, :integrations_backend, PhoenixKit.Integrations)`. The three call sites (`get_credentials`, `get_integration`, `authenticated_request`) dispatch through this resolver. Production reads the default when the config is absent — net diff is one line per call site (3 lines added, alias removed).
- `do_fetch_thumbnail_image/1` (Drive thumbnail CDN) appends `Application.get_env(:phoenix_kit_document_creator, :req_options, [])` to its `Req.get/2` opts (the AI module's pattern, applicable here for the one direct `Req.get/1` call that bypasses `authenticated_request`). Production behaviour unchanged when config absent — net diff is one line.

Combined production diff: ~+8 lines, -1 alias.

### Test infrastructure

**`test/support/stub_integrations.ex`** (new module). Implements the
three `PhoenixKit.Integrations` callbacks used by `GoogleDocsClient`
(`get_integration/1`, `get_credentials/1`, `authenticated_request/4`)
with an in-process ETS-backed dispatcher. ETS instead of process
dictionary because the LiveView runs in a different process from the
test process — `Req.Test.allow/3` would be the equivalent for direct
Req calls; for an Integrations-level stub, a public ETS table works
without touching core. Tests opt in via:

```elixir
Application.put_env(
  :phoenix_kit_document_creator,
  :integrations_backend,
  PhoenixKitDocumentCreator.Test.StubIntegrations
)

StubIntegrations.connected!("admin@example.com")
StubIntegrations.stub_request(:post, "/drive/v3/files",
  {:ok, %{status: 200, body: %{"id" => "drv-doc-1"}}})
```

Unstubbed requests return `{:error, {:unstubbed_request, method, url}}`
so tests fail loudly when a code path makes an unexpected outbound
request.

### Tests added (Batch 4)

- **`test/integration/drive_bound_actions_test.exs`** (new file) — 10
  context-layer happy-path tests pinning `:ok`-branch activity logs
  for: `create_template`, `create_template` (5xx error path),
  `create_document`, `delete_document`, `delete_template`,
  `restore_document`, `restore_template`, `export_pdf`,
  `create_document_from_template`, `set_correct_location`. Each
  asserts `actor_uuid` + safe metadata + that the success path does
  NOT carry the `db_pending: true` flag (so a future regression that
  takes the error branch instead of success can't pass silently).
- **`test/phoenix_kit_document_creator/web/documents_live_test.exs`**
  +3 LV-layer tests pinning `actor_opts(socket)` threading on the
  `new_template`, `new_blank_document`, and `delete` handlers. Without
  these, dropping `actor_opts(socket)` from `documents_live.ex:248`
  silently regresses to `actor_uuid: nil` — the prior smoke test that
  asserted "page renders" would still pass.

### Files touched (Batch 4)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | resolver `integrations_backend/0` + `req_options` config-read on the thumbnail Req.get |
| `test/support/stub_integrations.ex` | new — ETS-backed Integrations stub |
| `test/integration/drive_bound_actions_test.exs` | new — 10 context-layer happy-path tests |
| `test/phoenix_kit_document_creator/web/documents_live_test.exs` | +3 LV-layer actor_uuid threading tests |

### Verification (Batch 4)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 247 → 260 tests (+13), 0 failures
- 5/5 stable runs at 260
- `mix format` + `mix credo --strict` + `mix dialyzer` — all clean

### What's still uncovered (deliberate)

- The OAuth-flow LV (`google_oauth_settings_live.ex`) — exercising the
  `Integrations.list_connections/1` / `Integrations.connected?/1`
  paths there would need a separate stub layer (the LV calls
  Integrations directly, not via the resolver). Out of scope for this
  pass — that LV is for OAuth setup and isn't in any test-covered
  user-action path that mutates state.
- The `sync_from_drive` flow + `DriveWalker` — both are Drive-bound
  but the resolver-injected backend doesn't cover the
  `discover_folders/0` → `ensure_folder_path/1` chain (which calls
  `find_folder_by_name` → `authenticated_request`, but the cache-seed
  helper `stub_folder_resolution!/0` short-circuits the whole branch
  in tests, so the chain never executes). The walker has its own
  unit-style tests in `test/google_docs_client_test.exs`. A fuller
  sync-end-to-end test would exercise `Documents.sync_from_drive/0`
  with a live `list_folder_files`/`list_subfolders` stub map — also
  out of scope here.

## Batch 5 — coverage push 2026-04-26

User asked for an aggressive coverage push following AGENTS.md
"Coverage push pattern" — push as close to 100% as possible using only
`mix test --cover` (built-in line coverage), no Mox / excoveralls /
external test deps. The Batch 4 stub infra (`Test.StubIntegrations`)
made this feasible without further production changes.

### Coverage progression

- **Pre-push baseline**: 47.67% total (~52% production)
- **Final**: **77.92% production** (10/10 stable, 374 tests, +114 from
  Batch 4's 260)

Per-module breakdown:

| Module | Before | After |
|---|---|---|
| `Errors`, `Schemas.{Document, HeaderFooter, Template}`, `Variable`, `Paths` | 100% / 25% (Paths) | **100%** |
| `DriveWalker` | 33% | **88%** |
| `Documents` | 60% | **87%** |
| `CreateDocumentModal` | 87% | **87%** |
| `PhoenixKitDocumentCreator` (top-level) | 53% | **82%** |
| `GoogleDocsClient` | 57% | **76%** |
| `DocumentsLive` | 34% | **64%** |
| `GoogleOAuthSettingsLive` | 22% | **73%** |

### Production change

**`mix.exs`** — added `test_coverage: [ignore_modules: [...]]` so the
percentage reports production code, not test-support infrastructure
(DataCase, LiveCase, Test.* modules). No runtime impact.

### Tests added (Batch 5)

| File | Tests added | Targets |
|---|---|---|
| `test/paths_test.exs` (new) | 5 | All 4 path helpers + prefix-aware behaviour |
| `test/integration/module_callbacks_test.exs` (new) | 8 | `enable_system/0`, `disable_system/0`, `css_sources/0`, `children/0`, `settings_tabs/0`, `permission_metadata/0`, `version/0` against real DB |
| `test/integration/drive_walker_test.exs` (new) | 11 | `list_files/1`, `list_folders/1`, `walk_tree/2` happy + 5xx + transport-error + empty-input branches |
| `test/integration/google_docs_client_http_test.exs` (new) | 39 | All 17 public client functions — happy path + non-2xx + transport error each |
| `test/integration/documents_sync_test.exs` (new) | 14 | `sync_from_drive/0`, `persist_thumbnail/2`, `load_cached_thumbnails/1`, `move_to_templates`, `move_to_documents`, `detect_variables/1` |
| `test/phoenix_kit_document_creator/web/documents_live_test.exs` | +25 (new tests) | `switch_view`, `switch_status`, modal events, unfiled events, `delete`/`restore` guards, `refresh`, `silent_refresh`, `dismiss_error`, every `handle_info/2` clause |
| `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs` | +12 | `save_folders` (changed + no-change branches), folder-browser flow, `select_connection` event, `:drive_folders_loaded` handler |
| `test/phoenix_kit_document_creator_test.exs` | +6 | `Variable` edge cases (Unicode, dedup, malformed placeholders, long input) |

### Known limitations

The remaining ~22% gap is a mix of:

- **Render template branches** (~80% of the residual). HEEx
  conditional clauses (`<%= if @loading do %>`, status-mode forks,
  list-vs-grid view modes, file-action toolbar variants) need full LV
  mount-and-click flows that drive every state combination. Driving
  every render path is feasible but produces a long tail of
  fixture-heavy tests.
- **Cross-process sandbox flakes on LV happy-path Drive flows.** Per
  AGENTS.md "Cross-process sandbox sharing is unreliable for seed-and-
  read flows in LiveView tests" — `:sys.replace_state` to inject
  `documents`/`templates` lists gets clobbered by the LV's
  `:sync_complete` re-read from the DB. Affected paths
  (`open_unfiled_actions` + `delete`/`restore` happy paths +
  `export_pdf`) are still pinned at the **context layer** in
  `drive_bound_actions_test.exs` — the LV-side `actor_uuid` threading
  is already covered by the dedicated tests in the
  "connected-state actions thread actor_uuid through to context"
  describe block.
- **Defensive `enabled?/0` rescue + catch :exit** clauses (top-level
  module). Per AGENTS.md "Coverage push pattern — what stays
  uncovered (and that's fine)" — these only fire if core
  re-raises, which is unreachable from the test sandbox.

### Files touched (Batch 5)

| File | Change |
|------|--------|
| `mix.exs` | added `test_coverage: [ignore_modules: [...]]` |
| `test/test_helper.exs` | started `PhoenixKit.TaskSupervisor` for async-task LV paths |
| `test/support/stub_integrations.ex` | switched ETS backing for cross-process visibility (LV process reads test-set state) |
| `test/paths_test.exs` (new) | + Paths helper tests |
| `test/integration/module_callbacks_test.exs` (new) | + Top-level callback tests |
| `test/integration/drive_walker_test.exs` (new) | + DriveWalker HTTP tests |
| `test/integration/google_docs_client_http_test.exs` (new) | + GoogleDocsClient HTTP tests |
| `test/integration/documents_sync_test.exs` (new) | + Documents sync tests |
| `test/phoenix_kit_document_creator/web/documents_live_test.exs` | + LV handler/event/info tests |
| `test/phoenix_kit_document_creator/web/google_oauth_settings_live_test.exs` | + OAuth settings LV tests |
| `test/phoenix_kit_document_creator_test.exs` | + Variable edge-case tests |

### Verification (Batch 5)

- `mix compile --warnings-as-errors` — clean
- `mix test` — 260 → **374 tests** (+114), 0 failures
- 10/10 stable runs at 374
- `mix format` + `mix credo --strict` + `mix dialyzer` — all clean
- Production coverage 47.67% → **77.92%** (test-support modules
  excluded via `test_coverage[:ignore_modules]`)

## Batch 6 — post-merge deep-dive 2026-04-29

User triggered an independent deep-dive review of merged PR #11
(separate from the C12 batches above, which closed before merge).
The deep-dive surfaced two H-severity items that the original
sweep + Batch 2-5 work hadn't reached. Both are surgical fixes on
top of the landed code.

- ~~**H1 — SSRF guard does not block redirects**~~ — fixed in
  `lib/phoenix_kit_document_creator/google_docs_client.ex`
  `do_fetch_thumbnail_image/1`. `Req.get(url, opts)` in Req `~> 0.5`
  follows redirects by default. The SSRF allowlist
  `validate_thumbnail_url/1` checked the *input* URL once, but a
  successful 302 from `lh4.googleusercontent.com` to
  `http://169.254.169.254/...` was followed silently — the
  metadata-service fetch then went out from the application server
  with no second-pass guard. The C12.5 deep-dive that introduced
  the host allowlist explicitly cited metadata-service redirection
  as in-scope. **Fix:**
  ```elixir
  opts = [redirect: false] ++ Application.get_env(:phoenix_kit_document_creator, :req_options, [])
  ```
  `redirect: false` is prepended so it wins via Keyword first-match
  semantics — `:req_options` cannot override it. The thumbnail
  endpoint never legitimately redirects, so closing it off is safe.
- ~~**H2 — Dead `rescue` clause in `discover_folders/0`**~~ — fixed
  in the same file. `Task.await_many/2` on timeout sends `exit/1`
  through the link, not a raised exception. `rescue` only handles
  `raise`d exceptions, so the existing
  ```elixir
  try do
    Task.await_many(tasks, 30_000)
  rescue
    e -> ...
  end
  ```
  was dead code: on a 30-second Drive folder hang, the LV process
  exited and the supervisor restarted it — the `Logger.error`, the
  `Task.shutdown(.., :brutal_kill)` cleanup, and the nil fallback
  all never ran. Replaced with `catch :exit, reason -> ...` matching
  the actual signal type. `Enum.each` for the cleanup (the previous
  code mixed `Task.shutdown` return values with `nil` per-element
  via `Enum.map`); returns a 4-element nil list to match the
  destructure on the next line.

### Tests added (Batch 6 — 2026-04-29)

None in this batch — the H1 end-to-end redirect-block test landed
in Batch 7 (it required wiring `Req.Test` plumbing the original PR
explicitly punted on, with the `:req_options` config knob as the
hook). The H2 timeout path also has no test — pinning would require
either an injectable timeout or a stubbed `authenticated_request`
that hangs, both reasonable but out of scope.

### Files touched (Batch 6)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `redirect: false` prepended to `do_fetch_thumbnail_image/1`'s Req opts; `discover_folders/0` rescue → `catch :exit, reason` |

### Verification (Batch 6)

- `mix compile --warnings-as-errors` — clean
- `mix test test/google_docs_client_test.exs` — 36 tests, 0 failures
- Production diff: ~+12 lines, -8 lines, all in
  `lib/phoenix_kit_document_creator/google_docs_client.ex`

### Pre-existing items surfaced (not closed in Batch 6)

The deep-dive review (`CLAUDE_REVIEW.md`) documents several
pre-existing items that PR #11 didn't introduce and Batch 6 didn't
touch — kept here for traceability:

- **M1** — DB queries in `mount/3` of both top-level LiveViews
  (mount runs twice on connected sessions).
- **M2** — `Test.StubIntegrations` ETS table forces `async: false`
  if used concurrently from multiple tests.
- **L1** — `register_existing_document/2` doesn't validate
  `google_doc_id` before upsert. *Retracted in Batch 7 — the
  function does call `validate_file_id/1` via
  `normalize_register_attrs/1`; the original review missed it.*
- **L2** — `extract_content_type` silent downgrade on type
  mismatch. *Closed in Batch 7.*
- **S2** — `discover_folders/0` parallel tasks are unsupervised.
- **S3** — `verify_known_file/2` is O(N) per event.
- **S5** — `actor_opts/1` duplicated across two LVs.

## Batch 7 — test pin + content-type log 2026-04-30

User asked "anything we need to fix/improve here?" after the
Batch 6 commit landed. Batch 6 fixed the H1 SSRF redirect bypass
and the H2 dead `rescue` clause but landed without an end-to-end
test for H1, and left the L2 content-type silent downgrade
unfixed. This batch closes both, plus retracts the L1 finding from
the original deep-dive review (initial reading missed that
`normalize_register_attrs/1` already calls `validate_file_id/1`).

- ~~**End-to-end test for the SSRF redirect block (H1 from
  Batch 6)**~~ — added a `describe "fetch_thumbnail_image/1
  (SSRF redirect block)"` block in
  `test/google_docs_client_test.exs` with two tests:
  - **Does not follow a 302 to an internal host.** Stubs Req via
    `Req.Test.stub/2` to return `302 Location:
    http://169.254.169.254/...` for an *allowed* input URL
    (`https://lh3.googleusercontent.com/abc`). Asserts
    `{:error, :thumbnail_fetch_failed}` and uses
    `assert_receive`/`refute_receive` on a `send(self(),
    {:plug_called, conn.host})` to pin that the plug was hit
    exactly once — Req did not chase the redirect.
  - **Rejects an input URL outside the allowlist before issuing
    any request.** Sanity check that the URL guard fires first.

  The test uses `Application.put_env(..., :req_options, plug:
  {Req.Test, StubName})` with a unique stub atom per test (via
  `System.unique_integer/1`) and `on_exit` cleanup. The test
  module switched from `async: true` to `async: false` because
  Application env is global state — matches the existing pattern
  in `test/integration/drive_walker_test.exs` and friends.
- ~~**Expose `fetch_thumbnail_image/1` as `@doc false`-public**~~ —
  same shape as `validate_thumbnail_url/1` directly above it. The
  function is the SSRF perimeter: tests pin it without driving a
  full Drive auth flow. Comment explains the public-but-not-API
  status.
- ~~**L2 — Log content-type downgrade**~~ — fixed in
  `extract_content_type/1`. Pre-fix, a Drive thumbnail with
  `Content-Type: image/svg+xml` (or anything outside the
  `~w(image/png image/jpeg image/webp image/gif)` allowlist)
  silently fell back to `image/png` in the data URI — no log,
  hard to debug. Now `Logger.debug` records the original value.
- ~~**CLAUDE_REVIEW.md L1 retraction**~~ —
  `register_existing_document/2` IS guarded.
  `normalize_register_attrs/1` at
  `lib/phoenix_kit_document_creator/documents.ex:804` calls
  `GoogleDocsClient.validate_file_id(a[:google_doc_id])` and
  returns `{:error, :invalid_google_doc_id}` on a regex mismatch.
  L1 entry struck through with the correction noted in
  `CLAUDE_REVIEW.md`.

### Tests added (Batch 7 — 2026-04-30)

- `test/google_docs_client_test.exs` — `describe
  "fetch_thumbnail_image/1 (SSRF redirect block)"` with 2 tests
  (redirect-not-followed + URL-guard-fires-first). Suite count
  36 → 38.

### Files touched (Batch 7)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | `fetch_thumbnail_image/1` exposed as `@doc false`-public for the SSRF perimeter test; `extract_content_type/1` adds `Logger.debug` on the silent-downgrade path |
| `test/google_docs_client_test.exs` | +2 redirect-block tests; module flipped to `async: false` for the Application env access |
| `dev_docs/pull_requests/2026/11-quality-sweep/CLAUDE_REVIEW.md` | L1 finding struck through with correction |

### Verification (Batch 7)

- `mix compile --warnings-as-errors` — clean
- `mix test test/google_docs_client_test.exs` — **38 tests, 0
  failures** (was 36; +2 redirect-block tests)
- Test output confirms both behaviour pins:
  - `[DocumentCreator] thumbnail fetch returned non-200 |
    status=302` — Req returned the 302 directly because
    `redirect: false`.
  - `[DocumentCreator] thumbnail URL rejected |
    reason=host_not_allowed | url="http://169.254.169.254/foo"`
    — URL guard fired before any request.

### Remaining items (still not fixed)

Per CLAUDE_REVIEW.md, these remain pre-existing and unaddressed
even after Batch 7:

- ~~**M1** — DB queries in `mount/3` (changes SSR behaviour;
  warrants its own PR).~~ — closed in Batch 8 (issue #13 PR).
- ~~**M2** — `Test.StubIntegrations` ETS table forces `async: false`
  if used concurrently from multiple tests.~~ — closed in Batch 8.
- ~~**S2** — `discover_folders/0` parallel tasks unsupervised.~~
  — closed in Batch 8.
- ~~**S3** — `verify_known_file/2` is O(N) per event.~~ — closed
  in Batch 8.
- ~~**S5** — `actor_opts/1` duplicated across two LVs.~~ — closed
  in Batch 8.

## Batch 8 — close all parking-lot items 2026-05-05

Issue #13 (per-template language picker) brought the M-tier and
S-tier residuals from Batch 7's "Remaining items" list into scope.
Per `feedback_followup_is_after_action.md` — `## Open` should be
`None.` and parking-lot lists shouldn't accumulate. Each item was
fixed mechanically in the same PR that landed the language column.

- ~~**M1** — Move `mount/3` DB reads to `:load_initial` /
  `:load_settings` handlers~~. Disconnected mount returns an empty
  shell; connected mount sends a self() message that performs the
  reads. Cuts the DB-call burst on every page load in half. Docs
  live + Settings live both refactored in
  `documents_live.ex:24-71` / `90-105` and
  `google_oauth_settings_live.ex:23-58` / `66-95`.
- ~~**M2** — `Test.StubIntegrations` claim/release ownership~~.
  `claim!/0` registers the calling pid as the table owner;
  subsequent calls from a different pid raise loudly with a
  `:concurrent_stub_use` exit. Subsumes §1.9 from PR #12 — the
  named ETS table stays (cross-process boundary requires it) but
  the async-false constraint is enforced at runtime.
- ~~**S2** — `discover_folders/0` →
  `Task.Supervisor.async_stream_nolink(PhoenixKit.TaskSupervisor, ...)`~~.
  Caller-LV exit cleans children automatically; per-task failure is
  reported as `{:exit, reason}` in the stream so the explicit
  `catch :exit, _` block is gone.
- ~~**S3** — `verify_known_file/2` is O(1)~~. Replaced 4×
  `Enum.any?/2` with `MapSet.member?/2` backed by a
  `known_file_ids` assign rebuilt on `mount` + `:sync_complete`.
- ~~**S5** — `actor_opts/1` lifted to
  `PhoenixKitDocumentCreator.Web.Helpers`~~. Both LVs delegate
  via tiny private wrappers (`defp actor_opts(s), do:
  Helpers.actor_opts(s)`) to keep call shape stable across the
  file. New module is the canonical home for any future LV
  cross-cutting helpers.

Plus the C12 triage on the Batch 8 changes themselves surfaced
two additional items (already in the same commit batch):

- Narrow the rescue in `Documents.default_language_code/0` from
  bare `_` to named exception classes (matches the existing
  `default_managed/2` shape).
- `apply_template_language/2` logs a warning when `update_all`
  touches zero rows (concurrent-delete visibility).

### Files touched (Batch 8)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/web/documents_live.ex` | M1 (mount→handle_info), S3 (MapSet) |
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | M1 (mount→handle_info) |
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | S2 (supervised async_stream) |
| `lib/phoenix_kit_document_creator/web/helpers.ex` | NEW — actor_opts/actor_uuid (S5) |
| `lib/phoenix_kit_document_creator/documents.ex` | C12 follow-ups (narrow rescue, apply log) |
| `test/support/stub_integrations.ex` | M2 + §1.9 (claim/release) |

### Verification (Batch 8)

- `mix precommit` — clean (compile + format + credo --strict 69
  checks no issues + dialyzer 0 errors)
- `mix test` — 414 tests, 0 failures, 4 excluded; 5/5 random
  seeds stable
- Browser smoke on `phoenix_kit_parent` (no Google connection):
  disconnected-mount empty state renders cleanly with the new
  mount→handle_info flow; with two synthetic templates seeded,
  the language picker opens and closes correctly across both
  card and list views; 0 console errors

## Open

None — all findings closed across Batches 2 + 3 + 4 + 5 + 6 + 7 + 8.
