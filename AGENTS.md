# AGENTS.md — PhoenixKit Document Creator

## Project Overview

Elixir library (Hex package) that adds document template management and PDF generation to PhoenixKit apps via Google Docs API. Templates and documents live in Google Drive. Variables use `{{ placeholder }}` syntax and are substituted via the Docs API. PDF export uses the Drive API export endpoint.

## What This Module Does NOT Have (by design)

The Google Docs pivot in PR #2 deliberately took several capabilities off the table. Don't reintroduce them without first checking with Max:

- **No local rich-text editor.** Editing happens in Google Docs. Earlier iterations shipped GrapesJS / TipTap / similar — all removed. If a feature seems to want a local editor, it's almost certainly the wrong shape.
- **No local PDF rendering.** PDFs are exported via the Drive API. No ChromicPDF, no Gotenberg, no Chrome dependency. Headers/footers/page-size/orientation are the responsibility of the Google Doc template, not this module.
- **No HeaderFooter feature module.** The `Schemas.HeaderFooter` schema is a tombstone for a deprecated header/footer storage scheme; headers and footers live in the Google Doc itself now.
- **No own Ecto repo.** Uses the host app's repo via `PhoenixKit.RepoHelper.repo()`. Don't add a dedicated repo here.
- **No own migrations directory.** Tables `phoenix_kit_doc_templates` / `phoenix_kit_doc_documents` / `phoenix_kit_doc_headers_footers` are created by core `phoenix_kit` versioned migrations (V86 + V94). Schema changes — including dropping legacy `content_html`/`content_css`/`content_native`/`header_uuid`/`footer_uuid` columns — happen in core, not here.
- **No periodic sync scheduler / Oban worker.** Sync runs on demand from the LiveView and via PubSub fan-out. If a consumer needs scheduled refresh, that's a host-app concern, not a feature of this module.
- **No retry/backoff layer over the Drive API client.** `Integrations.authenticated_request/4` handles 401 token refresh; everything else surfaces as `{:error, _}` to the caller. Adding a Google-specific retry policy is feature work that hasn't been requested.
- **No telemetry hooks.** None planned; if usage shape changes and observability becomes load-bearing, this gets revisited.

## Tech Stack

- **Language**: Elixir ~> 1.15
- **Framework**: Phoenix LiveView ~> 1.0
- **Database**: PostgreSQL (via Ecto through PhoenixKit's repo)
- **Document editing**: Google Docs (via Google Docs API v1)
- **File storage**: Google Drive (via Drive API v3)
- **Auth**: OAuth 2.0 via PhoenixKit.Integrations (centralized)
- **HTTP client**: Req ~> 0.5
- **Parent**: PhoenixKit (provides Module behaviour, Settings API, admin layout, Ecto repo, Integrations)


## Development Workflow

```bash
# One-shot: format + credo --strict + dialyzer
mix quality

# CI mode: format --check-formatted + credo --strict + dialyzer
mix quality.ci

# Full precommit: compile + quality
mix precommit
```

Or step-by-step:

```bash
mix format           # format code
mix compile          # compile
mix credo --strict   # lint
mix dialyzer         # type check
```

## Pre-commit Commands

Always run before git commit:

```
# 1.
mix precommit

# 2. Fix problems

# 3. Analyze current changes
git diff
git status

# 4. Make commit
```


## Project Structure

```
lib/
  phoenix_kit_document_creator.ex          # Main module — PhoenixKit.Module behaviour, tab registration
  phoenix_kit_document_creator/
    documents.ex                           # Context module — list/create/sync/export, register_existing_*
    google_docs_client.ex                  # Google Docs + Drive API client with OAuth 2.0
    google_docs_client/
      drive_walker.ex                      # Paginated + recursive Drive traversal (BFS + batched `in parents`)
    variable.ex                            # Extract {{ variables }} from text, guess types
    paths.ex                               # Centralized route path helpers
    schemas/
      template.ex                          # Template schema (name, slug, status, google_doc_id, path, folder_id)
      document.ex                          # Document schema (name, variable_values, google_doc_id, path, folder_id)
      header_footer.ex                     # HeaderFooter schema — legacy, deprecated
    web/
      documents_live.ex                    # LiveView — template/document listing with Drive thumbnails
      google_oauth_settings_live.ex        # LiveView — folder configuration and Google connection picker
      components/
        create_document_modal.ex           # Modal for creating documents (blank or from template with variables)

test/
  test_helper.exs                          # Smart DB detection — excludes integration tests when DB unavailable
  support/
    test_repo.ex                           # Ecto repo for tests
    data_case.ex                           # ExUnit case template with SQL Sandbox
  schemas/                                 # Unit tests for schema changesets (no DB needed)
  integration/                             # Integration tests — full CRUD + template→document workflow
  google_docs_client_test.exs              # Unit tests for GoogleDocsClient (pure functions + interface)
  phoenix_kit_document_creator_test.exs    # Unit tests for main module, variable extraction, admin tabs
```

## Key Architectural Decisions

- **Google Drive is source of truth for content**: All document content lives in Google Drive. The Phoenix app is a coordinator — it manages OAuth, lists files, substitutes variables, and exports PDFs via API.
- **Local DB mirrors metadata**: File metadata (name, google_doc_id, status, thumbnails, variables, path, folder_id) is mirrored to the local database for fast listing and audit tracking. Listing reads from DB; background sync keeps it current with Drive.
- **Four-status system**: Templates and documents have a `status` field:
  - `"published"` — file lives inside the managed tree (root or any descendant subfolder)
  - `"trashed"` — soft-deleted via app (moved to deleted folder) or found in Drive trash
  - `"lost"` — disappeared from Drive (manually deleted by someone in Google). Recovers automatically if reappearing.
  - `"unfiled"` — exists in Drive but outside the managed tree. The UI provides a resolution popup (move to templates/documents, or accept current location).
- **Nested subfolders inside the managed tree are `:published`**: `sync_from_drive/0` walks the entire managed tree recursively via `GoogleDocsClient.DriveWalker.walk_tree/2`. Any Google Doc in any descendant of the templates/documents root is treated as `:published`; reconciliation builds a `MapSet` of every enumerated folder ID and `classify_by_location/5` accepts a parent that matches the managed root **or** any descendant. Consumers are free to organise files into subfolders (e.g. `documents/order-123/sub-4/`) without the library reclassifying them as `:unfiled`.
- **Path convention**: `path` is a forward-slash-separated human-readable string anchored at the Drive root, **including the managed folder name**. A doc in the documents root → `"documents"`. A doc in `documents/order-123/sub-4` → `"documents/order-123/sub-4"`. Deleted-tree files → `"deleted/documents"`. Walker-produced paths follow this same shape; the register functions default to the managed-root path when the caller omits `:path`.
- **Variable tracking**: When creating a document from a template, `variable_values` (the actual substitution values) are persisted to the Document record for debugging. Variable definitions detected in templates are saved to the Template `variables` field.
- **No local editor**: Editing happens in Google Docs. No GrapesJS, TipTap, or other JS editors.
- **No local PDF generation**: PDFs are exported via the Drive API. No ChromicPDF, Gotenberg, or Chrome dependency.
- **Credentials via PhoenixKit.Integrations**: Google OAuth credentials (client_id/secret, access/refresh tokens) are managed centrally by `PhoenixKit.Integrations` under the `"google"` provider. The module declares `required_integrations: ["google"]`.
- **Legacy migration**: Both kinds of legacy data (the old `document_creator_google_oauth` settings key with locally-stored OAuth tokens, AND name-string `google_connection` references that predate the uuid switch) are migrated by `PhoenixKitDocumentCreator.migrate_legacy/0` — the `PhoenixKit.Module` callback. Host apps trigger this via `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from their `Application.start/2`. Activity emissions (`action: "integration.legacy_migrated"`) record each migration. After a successful credentials migration the legacy `document_creator_google_oauth` row is reset to `%{}` so plaintext `client_secret` / `access_token` / `refresh_token` don't outlive the move to encrypted Integrations storage. The on-read promotion in `GoogleDocsClient.active_integration_uuid/0` is the lazy-fallback variant for records the boot pass missed.
- **Auto-refresh on 401**: API calls go through `PhoenixKit.Integrations.authenticated_request/4` which automatically refreshes expired access tokens.
- **Folder config stored separately**: Folder paths and cached folder IDs are stored in `"document_creator_folders"` settings key (not in the integration data).
- **Connection selection**: The module stores the selected Google connection UUID in `"document_creator_settings"` → `"google_connection"`. Multiple Google connections are supported via the integration picker component.
- **No own Ecto repo**: Uses the host app's repo via `PhoenixKit.RepoHelper.repo()`.
- **Unified Drive listing primitive**: All Drive file/folder listing goes through `GoogleDocsClient.DriveWalker`. `list_folder_files/1` and `list_subfolders/1` on the client are thin wrappers; pagination (`nextPageToken` looping at `pageSize: 1000`) lives in one place. Both folder discovery and file listing across a walked tree use batched-parents queries (`'a' in parents or 'b' in parents …` chunked at 40 folder IDs per request) — one request per BFS level for folders, one batched sweep for files — so walking a tree of N subfolders costs roughly `O(ceil(N / 40))` Drive calls per level instead of `O(N)` sequential list calls. Folder ownership is resolved from each returned folder's `parents` field by matching against the current BFS level.

## Data Flow

```
Mount → DB read (instant) → render
         ↓ (background)
Google Drive API → upsert DB → reconcile status → re-read DB → update assigns
```

- **Sync**: `Documents.sync_from_drive/0` recursively walks both managed trees via `DriveWalker.walk_tree/2`, upserts every Doc found (including subfolders) with its actual parent `folder_id` and human-readable `path`, then `reconcile_status/3` reconciles DB records against the walk, using a `MapSet` of all enumerated folder IDs (root + descendants) for classification.
- **Create**: After Google API creates/copies a file, the DB record is immediately written with path/folder_id. `create_document_from_template/3` accepts `:parent_folder_id` and `:path` options for placing the new document into a consumer-managed subfolder.
- **Consumer-registered files**: `register_existing_document/2` and `register_existing_template/2` upsert a Drive file into the local DB **without any Drive API calls** — for wrappers that do their own copy/placement (e.g. into `order-N/sub-M/`) and just need the record to appear in `list_documents_from_db/0`. Missing `:folder_id` or `:path` default to the managed root; the next sync rewrites both from the walker, so stale or incomplete consumer-supplied metadata self-heals. Registering a file outside the managed tree is allowed — it gets classified `:unfiled` on next sync, same as manually-moved files.
- **Delete**: After moving a file to the Drive deleted folder, the DB status is set to "trashed".
- **Unfiled resolution**: Files outside the managed tree can be moved to templates/documents or their current location can be accepted as correct.
- **Thumbnails**: Fetched async from Drive, persisted to DB, loaded from DB cache on page load.

## Database Tables (V86 + V94)

Migration V86 (core) creates the tables. V94 adds `google_doc_id`, `status`, `path`, and `folder_id` columns.

- `phoenix_kit_doc_templates` — name, slug, status, google_doc_id (partial unique), path, folder_id, variables (jsonb), thumbnail, config, data
- `phoenix_kit_doc_documents` — name, google_doc_id (partial unique), status, path, folder_id, template_uuid (FK), variable_values (map), thumbnail, config, data
- `phoenix_kit_doc_headers_footers` — legacy, deprecated (headers/footers handled by Google Docs natively)

**Note:** Migrations live in PhoenixKit core (`lib/phoenix_kit/migrations/postgres/`), not in this module.

## Public API Layers

The module exposes three complementary APIs:

1. **`PhoenixKitDocumentCreator.GoogleDocsClient`** — Direct Google Drive/Docs API access. No local DB operations. Use for: creating files, listing folders, moving files, exporting PDFs, reading document content, template variable substitution.

2. **`PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker`** — Paginated + recursive Drive traversal. `list_files/1` and `list_folders/1` are the canonical paginated primitives (`list_folder_files/1` / `list_subfolders/1` on the parent client delegate here). `walk_tree/2` BFS's a folder tree and returns every descendant folder + every Google Doc inside any of them, each annotated with its owning `folder_id` and resolved `path`.

3. **`PhoenixKitDocumentCreator.Documents`** — Combined Drive + DB operations. Coordinates between Google Drive and the local database. Includes DB-only functions (`list_templates_from_db`, `list_enabled_languages`, `load_cached_thumbnails`, `register_existing_document`, `register_existing_template`, `update_template_language`) and combined functions (`create_template`, `create_document_from_template`, `sync_from_drive`, `delete_document`). All public functions have `@spec` annotations. Mutating functions accept `opts` with `:actor_uuid` for activity logging; register functions additionally accept `:emit_pubsub` (default `true`) — bulk callers should pass `false` and call `Documents.broadcast_files_changed/0` once at the end so connected admin LiveViews resync exactly once.

   **Per-template locale (V110+).** Each template has a nullable `:language` field (full BCP-47 code, e.g. `"en-US"`, `"et-EE"`). Set on creation via `create_template(name, language: code)` (defaults to the project's primary language from `PhoenixKit.Modules.Languages` when the opt is omitted) or after the fact via `update_template_language(google_doc_id, code, opts)` — passing `nil`/`""` clears the value. Documents intentionally don't store a language; they inherit from `template_uuid → templates.language`. Read it back via `list_templates_from_db/0`'s map `"language"` key.

## Critical Conventions

- **Module key**: `"document_creator"`
- **Tab IDs**: `:admin_document_creator`, `:admin_document_creator_documents`, `:admin_document_creator_templates`
- **URL paths**: Use hyphens (`document-creator`, `document-creator/templates`)
- **Settings keys**: `"document_creator_enabled"`, `"document_creator_settings"`, `"document_creator_folders"`
- **Translations**: All user-facing strings use `gettext()` via `PhoenixKitWeb.Gettext` backend
- **CSS sources**: `css_sources/0` returns `[:phoenix_kit_document_creator]` for Tailwind scanning
- **Required integrations**: `["google"]` — declares dependency on Google provider
- **`enabled?/0` must `rescue`** — module discovery runs early in boot, before Settings may be ready. `enabled?/0` wraps the Settings read in a `rescue _ -> false` clause so a missing DB or config doesn't crash the discovery pass. Every `PhoenixKit.Module` implementation follows this pattern — don't omit it on new modules.
- **Activity logging must not crash the caller** — every mutating context function logs via `PhoenixKit.Activity.log/1`. The `log_activity/1` helper in `Documents` guards with `Code.ensure_loaded?/1`, and `PhoenixKit.Activity.log/1` itself rescues its own DB errors (logs a warning). Don't call `PhoenixKit.Activity.log/1` directly from anywhere but that helper — route through `log_activity/1` so the guard pattern stays uniform.
- **Admin routing** — plugin LiveView routes are auto-discovered by PhoenixKit and compiled into `live_session :phoenix_kit_admin`. Never hand-register them in a parent app's `router.ex`; use `live_view:` on a tab or a route module. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference
- **PubSub topic**: `"document_creator:files"` — broadcast `{:files_changed, self()}` after any DB mutation that should trigger other admin sessions to resync. Both `Documents.broadcast_files_changed/0` and the LiveView's local helper use this constant.

## Running Tests

```bash
# Unit tests only (no database needed)
mix test --exclude integration

# All tests (requires PostgreSQL)
createdb phoenix_kit_document_creator_test
mix test
```

### Code Search

- Use `rg` (ripgrep) for text/regex/strings/comments
- Use `ast-grep` for structural patterns/function calls/refactoring

**Prefer `ast-grep` over text-based grep for structural code searches.**

```bash
ast-grep --lang elixir --pattern 'Documents.$FUNC($$$)' lib/
ast-grep --lang elixir --pattern 'def handle_event($$$) do $$$BODY end' lib/
```

## Common Tasks

- **Adding admin tabs**: Register in `phoenix_kit_document_creator.ex` `admin_tabs/0` callback.
- **Adding new API operations**: Add to `google_docs_client.ex` using `authenticated_request/3` for auto-refresh.
- **Adding path helpers**: Add to `paths.ex`.
- **Changing OAuth flow**: OAuth is managed centrally by `PhoenixKit.Integrations`. The `GoogleDocsClient` uses `Integrations.authenticated_request/4` for API calls with auto-refresh.
- **Handling unfiled files**: Use `Documents.move_to_templates/1`, `Documents.move_to_documents/1`, or `Documents.set_correct_location/1`.

## Versioning & Releases

Version is tracked in three places — all must match:
1. `mix.exs` — `@version`
2. `lib/phoenix_kit_document_creator.ex` — `def version, do: "x.y.z"`
3. `test/phoenix_kit_document_creator_test.exs` — version compliance test

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-24" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in all three locations above
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

- Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`
- **NEVER mention Claude or AI assistance** in commit messages

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

## TODOs

- **More urgent after recursive sync:** Add a migration with indexes on `status` and `inserted_at DESC` for both tables — the new recursive walker can surface many more rows for consumers using nested subfolders, and the list queries are `WHERE status IN (…) ORDER BY inserted_at DESC` on every mount/sync. Indexes: `create index(:phoenix_kit_doc_documents, [:status])`, `create index(:phoenix_kit_doc_templates, [:status])`, `create index(:phoenix_kit_doc_documents, [inserted_at: :desc])`, `create index(:phoenix_kit_doc_templates, [inserted_at: :desc])`. Migration goes in **phoenix_kit core** (`lib/phoenix_kit/migrations/postgres/`), not this module.

- **Store Drive's real `modifiedTime` and sort/display by it.** Today `schema_to_file_map/1` exposes the DB `updated_at` as `"modifiedTime"`, and the list queries in `documents.ex` sort by `inserted_at DESC` as a **workaround** — `updated_at` gets bumped on every sync (because `upsert_*_from_drive` uses `on_conflict: {:replace, [..., :updated_at]}`), making any `updated_at`-based ordering chaotic. The proper fix is to add a `drive_modified_at` column (from the Google Drive `modifiedTime` field on list responses), populate it in `upsert_*_from_drive`, sort by that, and have `schema_to_file_map` expose it as `"modifiedTime"`. Then the "modified" timestamp and ordering reflect what the user actually did in Google Docs, not when we last ran a sync — and the `inserted_at` sort can revert.

- **Replace the bespoke `Web.Components.CreateDocumentModal` with `PhoenixKitWeb.Components.Core.Modal`** — the Core modal already handles Escape-key dismissal, backdrop click, slot-based title/actions, and width presets. The current custom markup duplicates daisyUI modal classes and diverges from every other module's modal UX.

- **PDF export should go through a signed download endpoint, not the LiveView WebSocket.** Today `documents_live.ex:382` calls `Documents.export_pdf/1`, gets the full PDF binary back, and pushes a `phx:download-pdf` event with the bytes base64-encoded; an inline `<script>` listener materialises the base64 into a `data:application/pdf;base64,…` link and clicks it. That works for small PDFs but stresses LiveView's WebSocket frame buffer (default 1 MB transport window per frame, multi-MB PDFs can stall the socket), holds the PDF in LV process assigns until the JS hook fires (memory: `N concurrent admins × pdf_size`), and inflates payload by 33% via base64. The proper fix is a controller route at `/admin/document-creator/pdf/:file_id?token=…` that streams the PDF as `application/pdf` directly. Three pieces needed: (1) a public route registered in `route_module/0` (`PhoenixKitDocumentCreator.Routes` is currently empty for non-LV routes), (2) a signing layer via `Plug.Crypto.MessageVerifier` over `{file_id, exp, actor_uuid}` with an exp ≤ 5 min, (3) a controller that calls `Documents.export_pdf/1` and `send_resp` with the right `Content-Type` / `Content-Disposition` headers. Then the LV becomes `Documents.sign_pdf_download(file_id, ttl: …) → push_event(socket, "open-url", %{url: url})`. Mid-priority — only matters when admins start exporting large PDFs or you see WebSocket frame errors in production.

- **`reconcile_status/3` is N+1 against Drive when many files are untracked.** Every record whose `google_doc_id` is in the DB but missing from the latest walk fans out to a per-file `GoogleDocsClient.file_status/1` call (`documents.ex:classify_by_api`). For a healthy module that's a small N (only "lost" / "trashed-elsewhere" records hit this path), but a folder rename or a bulk move on Google's side could push hundreds of files through the per-file path on the next sync. Drive's API doesn't have a native "files.list?id in (...)" — the canonical batched read for arbitrary IDs is the `q='abc' in parents or 'def' in parents …` pattern (already used by `DriveWalker`), which only works when grouped by parent. A pragmatic fix would be: page through the unmatched records in chunks of 40, group by `folder_id`, and issue one batched Drive query per (folder_id, chunk). Owner: untriaged. Lower priority — reconcile runs every 2 min and only on untracked records, so the worst case is a one-off slow sync, not a per-mount perf cliff.

- **Move the inline `<script>` block in `documents_live.ex:776+` to a Phoenix Hook.** A literal `<script>` is injected into the `~H` template; it listens for `phx:open-url`, `phx:download-pdf`, and a `visibilitychange` silent-refresh trigger. The block is wrapped in `if (!window.__pkDocCreatorInitialized)` to avoid duplicate listener registration across re-renders — that works but is a workaround for the underlying issue: `<script>` inside Phoenix templates re-evaluates on every full DOM patch, and the global window flag only papers over it. Phoenix's first-class `phx-hook` system handles lifecycle automatically (`mounted()` once, `destroyed()` cleanup). Inline scripts also break under any host-app `Content-Security-Policy: script-src 'self'`. Fix is structural: move the JS into `assets/js/hooks/document_creator.js`, register it on the `LiveSocket` in the host app's `app.js`, and replace the inline block with a single mount-time hook on a hidden anchor element. Crosses the module boundary (host app has to import the hook), so the right time to do this is when a second module also needs a hook and the workspace-level convention can be set up once. Lower priority than the PDF endpoint above — current code works, workarounds are explicit and correct.


## External Dependencies

| Package | Range | Role |
|---|---|---|
| `phoenix_kit` | `~> 1.7` | Module behaviour, Settings API, admin layout, Integrations, Activity, PubSubHelper, Routes |
| `phoenix_live_view` | `~> 1.1` | Admin pages |
| `req` | `~> 0.5` | HTTP client for Google Docs / Drive API |
| `ex_doc` | `~> 0.39` (dev) | Generated documentation |
| `credo` | `~> 1.7` (dev/test) | Linting |
| `dialyxir` | `~> 1.4` (dev/test) | Static type analysis |

No other runtime dependencies. OAuth credentials are stored by `PhoenixKit.Integrations`; the module itself never persists client_id/secret or tokens directly.
