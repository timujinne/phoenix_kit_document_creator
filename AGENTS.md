# AGENTS.md

Guidance for AI agents working on `phoenix_kit_document_creator`.

## Overview

Hex package that adds document template management and PDF generation to
PhoenixKit apps through the Google Docs and Drive APIs. Templates and documents
are Google Docs living in Google Drive; the local database mirrors their
metadata for fast listing and audit tracking. Variables use `{{ placeholder }}`
syntax and are substituted through the Docs `replaceAllText` API; PDF export
uses the Drive export endpoint. Templates are organised by a Category → Type
taxonomy with per-category presets, and documents can be composed from several
template sections.

- **Depends on:** `phoenix_kit` `~> 2.21 and >= 2.21.3` (Hex) — Module behaviour, Settings,
  Integrations, Activity, PubSubHelper, `Utils.Routes`, `Utils.Slug`,
  `Utils.Multilang`, `SchemaPrefix`, `Modules.Storage`, `Modules.Languages`,
  core web components. Plus `phoenix_live_view ~> 1.2`, `req ~> 0.5`,
  `gettext ~> 1.0`, and `rustler` (optional, only for a source build of
  `mdex_native` pulled in transitively by core). No sibling `phoenix_kit_*`
  deps.
- **Consumed by:** `phoenix_kit_projects` (duck-typed — it reads
  `phoenix_kit_project_extensions/0`; neither package depends on the other).
  An external consumer still reads the deprecated
  `phoenix_kit_doc_templates.category_uuid` / `type_uuid` columns.
- **Admin surface:** `Document Creator` (`/admin/document-creator`) with subtabs
  `Documents`, `Templates`, `Categories`; a settings tab at
  `/admin/settings/document-creator`; category / type / preset form sub-pages
  registered through `route_module/0`; a `Documents` tab inside the projects
  hub.
- **Module key** `"document_creator"`; settings prefix `document_creator_`.

## What this module does NOT do

Deliberate non-features. Don't reintroduce them without checking first.

- **No local rich-text editor.** Editing happens in Google Docs. GrapesJS,
  TipTap and similar were tried and removed. A feature that seems to want a
  local editor is almost certainly the wrong shape.
- **No local PDF rendering.** PDFs are exported via the Drive API — no
  ChromicPDF, Gotenberg, or Chrome dependency. Headers, footers, page size and
  orientation are the Google Doc template's responsibility, not this module's.
- **No HeaderFooter feature.** `Schemas.HeaderFooter` is a tombstone for a
  deprecated storage scheme; headers and footers live in the Google Doc.
- **No own Ecto repo.** Uses the host app's repo via
  `PhoenixKit.RepoHelper.repo()`.
- **No periodic sync scheduler and no Oban worker.** Sync runs on demand from
  the LiveView and via PubSub fan-out. `Application.start/2` starts an Oban
  child only when the host configures `:phoenix_kit_document_creator, Oban`,
  and no worker ships in the package; scheduled refresh is a host concern.
- **No retry/backoff layer over the Drive client.**
  `PhoenixKit.Integrations.authenticated_request/4` handles 401 token refresh;
  everything else surfaces as `{:error, _}` to the caller.
- **No telemetry hooks.**
- **No JS bundle.** `js_sources/0` is not implemented. One inline `<script>`
  survives in `DocumentsLive` and is a known defect, not a pattern to copy —
  see Landmines and TODOs.

## Commands

```bash
mix deps.get
createdb phoenix_kit_document_creator_test   # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors, unused-lock + hex.audit checks, format --check-formatted + credo --strict + dialyzer, then the full test suite; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

`mix quality` (rewrites formatting) and `mix quality.ci` (checks it) are the
format+credo+dialyzer subsets of `mix precommit`.

Gettext catalogues:

```bash
mix gettext.extract --merge priv/gettext
```

## Conventions

- **Module key, tab ids, URL segments.** Module key `"document_creator"`; tab
  ids `:admin_document_creator`, `:admin_document_creator_documents`,
  `:admin_document_creator_templates`, `:admin_document_creator_categories`,
  `:admin_settings_document_creator`. URL segments use hyphens
  (`document-creator`, `document-creator/templates`).
- **Path helpers.** Use `PhoenixKitDocumentCreator.Paths`, which wraps
  `PhoenixKit.Utils.Routes.path/1` so the host's URL prefix and locale segment
  are applied. Never hardcode a path.
- **Routing.** Tab pages are declared with `live_view:` on the `Tab` struct and
  auto-discovered into core's `live_session :phoenix_kit_admin`. The
  category / type / preset form sub-pages come from `route_module/0` →
  `PhoenixKitDocumentCreator.Web.Routes`, which supplies `admin_routes/0` and
  `admin_locale_routes/0` (the same paths in both, distinguished only by route
  name suffix — never register one path through both a tab and a route module).
  Never hand-register plugin routes in a host app's `router.ex`; see core's
  `guides/custom-admin-pages.md`.
- **LiveView macro.** Every page LiveView is `use Phoenix.LiveView` with
  explicit imports of the core components it needs
  (`PhoenixKitWeb.Components.Core.*`); components are `use Phoenix.Component` or
  `use Phoenix.LiveComponent`. Templates never wrap in `LayoutWrapper` — admin
  LiveViews render inside core's admin live_session, which supplies the layout.
- **Gettext.** Own backend `PhoenixKitDocumentCreator.Gettext` with catalogues
  in `priv/gettext` (`en`, `et`, `ru`). Call sites use the macro form
  (`use Gettext, backend: PhoenixKitDocumentCreator.Gettext` then `gettext(…)`)
  so `mix gettext.extract` can see them. Tabs carry
  `gettext_backend: PhoenixKitDocumentCreator.Gettext` and
  `gettext_domain: "default"` so core can localise their labels.
- **Error strings.** Call sites return plain `{:error, :atom}` tuples, never
  free text. `PhoenixKitDocumentCreator.Errors.message/1` is the single
  translation point, and its msgids must stay literal arguments to `gettext/1`
  — do not refactor it into a lookup map, the extractor only sees literals.
- **CSS.** `css_sources/0` returns `[:phoenix_kit_document_creator]` so the
  `:phoenix_kit_css_sources` compiler adds this package to the host's Tailwind
  scan paths; classes used only in this module's templates would otherwise be
  purged.
- **JS hooks.** None. `js_sources/0` is unimplemented, so there is no bundle to
  register. A hook belongs in a `js_sources/0` bundle under a namespaced
  global; an inline `<script>` is the broken pattern, because morphdom does not
  execute inserted script tags and the listener vanishes on LiveView
  navigation.
- **`enabled?/0` must `rescue` and `catch :exit`.** Module discovery runs early
  in boot, before Settings may be ready, and the test sandbox can exit the pool
  checkout under a caller — both paths must return `false` rather than crash.
- **Activity logging must not crash the caller.** Every call to
  `PhoenixKit.Activity.log/1` sits behind a
  `Code.ensure_loaded?(PhoenixKit.Activity)` guard: the `log_activity/1`
  helpers in `Documents` and `Taxonomy`, plus the two legacy-migration sites in
  `GoogleDocsClient` and the top-level module. Route new logging through one of
  the two helpers rather than adding a fifth guarded call. Mutating functions
  take `opts` with `:actor_uuid` for attribution; LiveViews thread it via
  `Web.Helpers.actor_opts/1`.
- **Soft-delete sentinels.** Files use a four-value `status`:
  `"published"` (inside the managed tree, root or any descendant), `"trashed"`
  (deleted via the app or found in Drive's trash), `"lost"` (gone from Drive —
  recovers automatically if it reappears), `"unfiled"` (in Drive but outside the
  managed tree; the UI offers a resolution popup). Taxonomy records use
  `status` `"active"` / `"deleted"`; trashing a category cascades to its types
  and to templates reachable by `category_uuid` or `type_uuid`, and records the
  affected template uuids in the activity log so restore can scope itself.
  Documents are never cascaded.
- **Schemas.** UUIDv7 primary keys (`@primary_key {:uuid, UUIDv7, autogenerate:
  true}`, `@foreign_key_type UUIDv7`) and `use PhoenixKit.SchemaPrefix` on every
  table-backed schema, so queries target the schema core migrated into.
  `schema_prefix_conformance_test.exs` fails the build if one is missing.
- **Credentials.** Google OAuth credentials live in `PhoenixKit.Integrations`
  under the `"google"` provider; the module declares
  `required_integrations: ["google"]` and never persists client id/secret or
  tokens itself. The selected connection is referenced **by uuid** in
  `"document_creator_settings"` → `"google_connection"`;
  `GoogleDocsClient.active_integration_uuid/0` resolves it and promotes legacy
  `"google"` / `"google:name"` strings on read. Folder paths and cached folder
  ids are stored separately in `"document_creator_folders"`.
- **Injection points.** Three application-env swaps exist for tests, all under
  `:phoenix_kit_document_creator`: `:docs_client` (Drive/Docs client),
  `:integrations_backend`, `:media_module`. Production defaults are the real
  modules.
- **Host hook: `:attachments_parent_folder`.** A `{Mod, :fun}` under
  `:phoenix_kit_document_creator`, resolved by `Attachments.scope_folder/2`
  when the template image picker opens (never in `mount/3`). It is called as
  `fun(:document_image, actor_uuid, %{template_file_id: id})` or `/2` and
  returns `{:ok, folder_uuid}` or `nil`. Pass the answer to
  `MediaSelectorHelper.media_selector_url/2` as `scope_folder:`. Don't
  hand-append the param: core validates and encodes it there. It takes effect
  only on core 2.23.2 or later and applies to uploads, not picked files. A hook
  that raises, throws or exits must degrade to `nil`.

### Landmines

- **The inline `<script>` in `DocumentsLive`.** It registers the
  `phx:open-url` / `phx:download-pdf` / `visibilitychange` listeners and is
  guarded by `window.__pkDocCreatorInitialized` so re-renders don't double-bind.
  The guard is a workaround, not a fix: script tags inserted by morphdom are not
  executed, and any host `Content-Security-Policy: script-src 'self'` kills the
  block. Don't add a second one.
- **Bulk register calls fan out one PubSub broadcast each.**
  `register_existing_document/2` and `register_existing_template/2` default to
  `emit_pubsub: true`. A bulk caller must pass `emit_pubsub: false` and call
  `Documents.broadcast_files_changed/0` once at the end, or every connected
  admin LiveView resyncs per row.
- **`StubIntegrations` forces `async: false`.** It is backed by a single named
  ETS table so the LiveView process can read state the test process wrote; two
  concurrent tests racing on it produce cross-test flakes. Any file using it
  must declare `async: false`.
- **Deprecated taxonomy mirror columns.** `phoenix_kit_doc_templates`'s
  `category_uuid` / `type_uuid` are a compatibility mirror of the *primary*
  membership only; the source of truth is
  `phoenix_kit_doc_template_taxonomy`. They carry a deprecation `COMMENT` and
  must not be dropped until that consumer migrates. Read memberships
  through `Taxonomy`, not through the mirror.
- **`test_helper.exs` runs the module chain through a version-keyed wrapper.**
  `PhoenixKitDocumentCreator.Test.SchemaMigration` is keyed on
  `Migrations.Schema.current_version()`, so a chain bump re-applies on the next
  run. Adding DDL to the chain without bumping `@current_version` leaves every
  local database stale and the failure looks like a missing column.

## Architecture

```
lib/
  phoenix_kit_document_creator.ex            # PhoenixKit.Module impl: tabs, settings, legacy migration
  phoenix_kit_document_creator/
    application.ex                           # supervisor; Oban child only if the host configures it
    documents.ex                             # context — Drive+DB coordination, listing, sync, export
    documents/composer.ex                    # multi-section document composition (compose/2)
    taxonomy.ex                              # context — Category → Type CRUD, cascade trash/restore, pickers
    google_docs_client.ex                    # Docs + Drive API client over Integrations
    google_docs_client/drive_walker.ex       # paginated + recursive Drive traversal
    media.ex                                 # façade over PhoenixKit.Modules.Storage for image substitution
    attachments.ex                           # :attachments_parent_folder host hook → picker scope_folder
    errors.ex                                # single translation point for error atoms
    variable.ex                              # {{ variable }} extraction and type guessing
    paths.ex                                 # route path helpers
    gettext.ex                               # Gettext backend
    migrations/schema.ex                     # module-owned migration chain
    schemas/                                 # template, document, document_section, template_preset,
                                             #   template_taxonomy, category, type, header_footer (legacy)
    web/
      routes.ex                              # admin_routes/0 + admin_locale_routes/0 for form sub-pages
      documents_live.ex                      # main listing (templates + documents)
      categories_live.ex                     # taxonomy listing
      category_form_live.ex / type_form_live.ex / preset_form_live.ex
      project_documents_live.ex              # projects-hub Documents tab
      google_oauth_settings_live.ex          # folder config + connection picker
      helpers.ex                             # actor_opts/1, actor_uuid/1
      components/                            # create_document_modal, image_picker, variable_config_form
```

### Public API layers

Three complementary layers; pick the narrowest that does the job.

| Layer | Module | Scope |
|---|---|---|
| Drive/Docs only | `GoogleDocsClient` | Raw API: create/copy/move files, list folders, export PDF, read content, substitute variables. No DB. |
| Traversal | `GoogleDocsClient.DriveWalker` | `list_files/1` and `list_folders/1` are the canonical paginated primitives (`list_folder_files/1` / `list_subfolders/1` on the client delegate here). `walk_tree/2` BFSes a folder tree and returns every descendant folder plus every Google Doc inside them, annotated with owning `folder_id` and resolved `path`. |
| Combined | `Documents` | Drive + DB. DB-only reads (`list_templates_from_db/0`, `list_documents_from_db/0`, `load_cached_thumbnails/1`, `register_existing_*`, `update_template_language/3`) and combined writes (`create_template/2`, `create_document_from_template/3`, `sync_from_drive/0`, `delete_document/2`). All public functions carry `@spec`. |

`Taxonomy` is the fourth context and owns categories, types, presets and
template memberships; it never touches Drive.

### Data model

Every table is `phoenix_kit_doc_*`, UUIDv7 keys, schema-prefix aware.

| Table | Holds |
|---|---|
| `phoenix_kit_doc_templates` | name, slug (unique), status, google_doc_id (partial unique), path, folder_id, `variables` jsonb, `language` (BCP-47, nullable), thumbnail, config, `data` jsonb, deprecated `category_uuid` / `type_uuid` mirror |
| `phoenix_kit_doc_documents` | name, google_doc_id (partial unique), status, path, folder_id, `template_uuid` FK, `project_uuid` FK, `variable_values` map, thumbnail, config, `data` jsonb |
| `phoenix_kit_doc_template_taxonomy` | template × category membership with optional group (`type_uuid`); unique on `(template_uuid, category_uuid)` |
| `phoenix_kit_doc_categories` / `phoenix_kit_doc_types` | taxonomy, `position`-ordered, `status` active/deleted, `data` jsonb holds per-locale names |
| `phoenix_kit_doc_document_sections` | ordered sections of a composed document, unique on `(document_uuid, position)` |
| `phoenix_kit_doc_template_presets` | per-scope preset payloads |
| `phoenix_kit_doc_headers_footers` | legacy tombstone |

### Contracts

| Kind | Value | Notes |
|---|---|---|
| PubSub | `"document_creator:files"` | `{:files_changed, self()}` after any DB mutation admin sessions should resync on. Read the topic from `Documents.pubsub_topic/0`. |
| PubSub | `"document_creator:taxonomy"` | `{:doc_taxonomy_changed, level, uuid}` where `level` is `:category`, `:type` or `:template`. Subscribe with `PhoenixKit.PubSubHelper.subscribe/1`. |
| Setting | `"document_creator_enabled"` | boolean, drives `enabled?/0` |
| Setting | `"document_creator_settings"` | json; `"google_connection"` holds the integration uuid |
| Setting | `"document_creator_folders"` | json; folder paths plus cached `*_folder_id` values, dropped whenever the folder config changes |
| Setting | `"document_creator_google_oauth"` | legacy, reset to `%{}` after `migrate_legacy/0` runs |
| Permission | `"document_creator"` | one key, used as the `permission:` on every tab |
| Project extension | `"document_creator_docs"` | duck-typed catalog entry for the projects hub; `permission_actions: [:view, :edit_tasks]`; linkage is per-document via `documents.project_uuid` |

### Sync and status model

- **Mount** reads the DB and renders immediately; a background pass hits Drive,
  upserts, reconciles status, then re-reads and updates assigns.
- **Sync.** `Documents.sync_from_drive/0` walks both managed trees recursively
  with `DriveWalker.walk_tree/2`, upserts every Doc found (including ones in
  subfolders) with its real parent `folder_id` and human-readable `path`, then
  `reconcile_status/3` reconciles DB records against the walk using a `MapSet`
  of every enumerated folder id.
- **Nested subfolders are `published`.** `classify_by_location/5` accepts a
  parent matching the managed root **or** any descendant, so consumers may
  organise files into subfolders without them being reclassified `unfiled`.
- **Path convention.** `path` is a forward-slash string anchored at the Drive
  root and **includes the managed folder name**: a doc in the documents root is
  `"documents"`, one in `documents/order-123/sub-4` is
  `"documents/order-123/sub-4"`, a deleted-tree file is `"deleted/documents"`.
  The register functions default to the managed-root path when `:path` is
  omitted.
- **Create.** As soon as the Google API creates or copies a file the DB record
  is written with its `path` and `folder_id`.
  `create_document_from_template/3` takes `:parent_folder_id` and `:path` so a
  consumer can place the new document into its own subfolder; `:path` is only
  meaningful alongside `:parent_folder_id`.
- **Delete** moves the file into the configured deleted folder and sets the DB
  status to `"trashed"`.
- **Unfiled resolution.** `Documents.move_to_templates/2`,
  `Documents.move_to_documents/2` and `Documents.set_correct_location/2` are the
  three outcomes the UI offers for a file found outside the managed tree.
- **Consumer-registered files.** `register_existing_document/2` and
  `register_existing_template/2` upsert a Drive file into the DB with **no Drive
  API calls**, for wrappers that do their own copy and placement. Missing
  `:folder_id` / `:path` default to the managed root and the next sync rewrites
  both from the walker, so incomplete consumer metadata self-heals. Registering
  a file outside the managed tree is allowed; it classifies as `unfiled`.
- **Drive listing is one primitive.** All file and folder listing goes through
  `DriveWalker`; pagination (`nextPageToken` at `pageSize: 1000`) lives there
  once. Folder discovery and file listing use batched-parents queries
  (`'a' in parents or 'b' in parents …`, chunked at 40 ids), so a tree of N
  subfolders costs about `O(ceil(N / 40))` calls per BFS level instead of
  `O(N)`. Folder ownership comes from each returned folder's `parents` field
  matched against the current BFS level.
- **Variables.** Definitions detected in a template are saved to the template's
  `variables`; the actual substitution values are persisted onto the created
  document's `variable_values`.
- **Per-template locale.** A template's nullable `language` is a full BCP-47
  code, set at creation via `create_template(name, language: code)` (defaulting
  to the project's primary language from `PhoenixKit.Modules.Languages`) or
  later via `update_template_language/3`; `nil` / `""` clears it. Documents
  never store a language — they inherit through `template_uuid`. Read it back
  from `list_templates_from_db/0`'s `"language"` key.
- **Thumbnails** are fetched async from Drive, persisted, and served from the DB
  cache on page load.
- **Legacy migration.** `PhoenixKitDocumentCreator.migrate_legacy/0` (the
  `PhoenixKit.Module` callback, run by
  `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` at host boot) handles
  both legacy shapes: plaintext OAuth credentials under
  `document_creator_google_oauth`, and name-string `google_connection`
  references predating the uuid switch. Each emits an
  `"integration.legacy_migrated"` activity row. After a successful credentials
  migration the legacy settings row is overwritten with `%{}` so plaintext
  secrets don't outlive the move to encrypted Integrations storage. The on-read
  promotion in `GoogleDocsClient.active_integration_uuid/0` is the lazy variant
  for records the boot pass missed.

## Database & migrations

Owns a versioned chain: `PhoenixKitDocumentCreator.Migrations.Schema` via
`migration_module/0`, marker `dcr_schema:<N>` as a `COMMENT ON` the
`phoenix_kit_doc_documents` table, currently V2. `mix phoenix_kit.update`
applies it in hosts; tests run it through
`PhoenixKitDocumentCreator.Test.SchemaMigration`, keyed on
`current_version/0`.

The `phoenix_kit_doc_*` **tables themselves are created by core** (the V135
squash baseline), including the `status` indexes on templates and documents,
the partial-unique `google_doc_id` indexes and the taxonomy tables. This chain
only iterates on that shape:

| Version | Change |
|---|---|
| V1 | `phoenix_kit_doc_documents.project_uuid` — nullable FK to `phoenix_kit_projects(uuid)`, `ON DELETE SET NULL`, plus its index. Purely additive. |
| V2 | `phoenix_kit_doc_template_taxonomy` join table (template × category, optional group), its unique and lookup indexes, and a backfill of one row per template that had a `category_uuid`. Stamps the legacy `templates.category_uuid` / `type_uuid` columns with a deprecation `COMMENT`; they stay populated as a mirror of the primary membership. |

Rules for the chain:

- A marker-less table reads as version `0` — the core-baseline shape from
  before this chain existed. There is no pre-chain content to defend, so unlike
  an adoptive V1 there is nothing to guard against.
- `up/1` is idempotent end to end (`IF NOT EXISTS` everywhere, `ON CONFLICT DO
  NOTHING` on the backfill) and stamps the marker last.
- `down/1` is version-aware and runs inside Ecto's DDL transaction; the
  `DROP TABLE` runs before the marker rewrite so a failure can never leave
  "marker present, table gone".
- **Rolling back past V2 destroys multi-category data.** `down(version: 1)`
  drops the join table; only the single-binding legacy mirror survives, and a
  later `up` re-backfills from that one column alone.
- The schema prefix is interpolated into raw DDL, so it goes through
  `validated_prefix/1` (`^[a-zA-Z_][a-zA-Z0-9_]*$`) first.
- A shape change to a core-created column is a core migration first, then a
  schema edit here. A new column or table that belongs to this module is a new
  version in this chain — bump `@current_version` in the same commit.

## Testing

Test database `phoenix_kit_document_creator_test`. Before anything connects,
`test_helper.exs` passes the resolved database name to
`Test.LiveDatabaseGuard.check!/1`, which raises for any name ending in `_dev` or
`_prod` — `PGDATABASE` is honoured, so a dev shell's export would otherwise
point the migration run at a real database. It then makes one
bounded connection attempt with the repo's own credentials through core's
`PhoenixKit.TestSupport.PostgresPreflight` (falling back to a plain
`start_link` attempt on a core that predates it) and, when the database is
unreachable, prints the classified reason and excludes `:integration` so unit
tests — schemas, changesets, `Variable`, `Errors`, `Paths`, the pin/prefix
conformance guards — still run.

With a database, the helper builds the schema the way a host does:
`PhoenixKit.Migration.ensure_current(TestRepo, log: false)` for core's chain,
then `Ecto.Migrator.run/4` over
`PhoenixKitDocumentCreator.Test.SchemaMigration` keyed on the module chain's
`current_version/0`. It also pins `:phoenix_kit_url_prefix` to `"/"` in
`:persistent_term`, and starts `PhoenixKit.PubSub.Manager`,
`PhoenixKit.ModuleRegistry`, `PhoenixKit.TaskSupervisor`, a fallback
`PhoenixKit.PubSub` registry, and the LiveView test endpoint.

Support modules under `test/support`:

| Module | Role |
|---|---|
| `Test.Repo` | Ecto repo for the suite |
| `DataCase` | SQL-sandbox case; tags `:integration` automatically |
| `LiveCase` | LiveView case; wires the test endpoint, `put_test_scope/2` + `fake_scope/1`, tags `:integration` |
| `Test.Endpoint` / `Test.Router` / `Test.Layouts` | standalone Phoenix stack, since core's `live_session` is not available |
| `Test.Hooks` | `on_mount :assign_scope` replicating what core's admin live_session assigns |
| `Test.SchemaMigration` | version-keyed wrapper around the module chain |
| `Test.StubDocsClient` | records Drive/Docs calls in a per-test Agent, no HTTP |
| `Test.StubIntegrations` | stubs `get_integration/1`, `get_credentials/1`, `authenticated_request/4`; **requires `async: false`** |
| `ActivityLogAssertions` | asserts activity rows by action, module and metadata subset; imported into both cases |

Two tags gate optional behaviour: `:integration` (needs Postgres) and
`:requires_phoenix_kit_i18n_api` (excluded when the resolved core pre-dates
`PhoenixKit.Dashboard.Tab.localized_label/1`).

`config/test.exs` honours `PGUSER`, `PGPASSWORD`, `PGHOST`, `PGPORT` and
`PGDATABASE`, defaulting to `postgres` / `postgres` / `localhost` / `5432`. On
a machine with no `postgres` role, export `PGUSER`; the preflight reports the
rejected credentials up front instead of letting the pool time out later.

Two conformance tests are load-bearing and should not be relaxed:
`core_pin_conformance_test.exs` (the `:phoenix_kit` requirement must stay
`~> 2.21 and >= 2.21.3` — the floor is where core's website-wide Integrations
page took its current path, and a three-segment `~> 2.21.3` would pin a single
minor and break consumers, never this repo) and
`schema_prefix_conformance_test.exs` (every table-backed schema must
`use PhoenixKit.SchemaPrefix`).

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s; design notes live under
`dev_docs/` and `docs/`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **Index `inserted_at DESC` on both file tables.** Core's baseline already
  creates the `status` indexes, but nothing indexes `inserted_at`, and the list
  queries are `WHERE status IN (…) ORDER BY inserted_at DESC` on every mount and
  sync — with recursive walking, consumers using nested subfolders surface far
  more rows. Add `phoenix_kit_doc_documents (inserted_at DESC)` and
  `phoenix_kit_doc_templates (inserted_at DESC)` as V3 of **this module's**
  chain. Unblocked now; do it next time the chain is bumped for another reason.
- **Store Drive's real `modifiedTime` and sort by it.**
  `Documents.schema_to_file_map/1` exposes the DB `updated_at` as
  `"modifiedTime"`, and the list queries sort by `inserted_at DESC` as a
  workaround — `updated_at` is bumped on every sync (the `upsert_*_from_drive`
  functions use `on_conflict: {:replace, […, :updated_at]}`), so any
  `updated_at` ordering is chaotic. The fix is a `drive_modified_at` column
  populated from the Drive `modifiedTime` field on list responses, sorted on and
  exposed as `"modifiedTime"`; then the `inserted_at` sort can revert. Trigger:
  the first complaint that "modified" dates or ordering look wrong.
- **Replace `Web.Components.CreateDocumentModal` with
  `PhoenixKitWeb.Components.Core.Modal`.** The core modal already handles
  Escape dismissal, backdrop click, slot-based title/actions and width presets;
  the bespoke markup duplicates daisyUI classes and diverges from every other
  module's modal UX. `DocumentsLive` already uses the core modal elsewhere, so
  this is the last holdout.
- **Serve PDF exports from a signed download endpoint, not the LiveView
  socket.** `DocumentsLive`'s `export_pdf` event calls `Documents.export_pdf/1`,
  base64-encodes the binary and pushes it as a `phx:download-pdf` event, which
  the inline `<script>` turns into a `data:` link. A 5 MB cap currently rejects
  anything larger with a "export from Google Docs instead" message, so the
  socket no longer stalls — but the payload still inflates 33% via base64 and
  the PDF sits in LiveView assigns until the JS fires (`N concurrent admins ×
  pdf_size`). The proper shape is three pieces: a controller route registered
  in `route_module/0`, a signing layer over `{file_id, exp, actor_uuid}` via
  `Plug.Crypto.MessageVerifier` with `exp ≤ 5 min`, and a controller that
  streams the bytes with the right `Content-Type` / `Content-Disposition`; the
  LiveView then becomes `sign_pdf_download/2` plus a `push_event("open-url", …)`.
  Trigger: admins needing exports above the cap.
  Since 0.9.7 `export_pdf/1` fetches PDFs past Drive's ~10 MB `files.export`
  cap through the file's `exportLinks`, so the admin page downloads them only
  to discard them at the 5 MB push cap; the endpoint would make those
  deliverable.
- **`reconcile_status/3` is N+1 against Drive when many files are untracked.**
  Every record whose `google_doc_id` is in the DB but absent from the latest
  walk falls through `classify_by_api/5` to a per-file
  `GoogleDocsClient.file_status/1`. Normally that is a handful of `lost` /
  trashed-elsewhere records, but a folder rename or bulk move on Google's side
  pushes hundreds through it. Drive has no "files.list?id in (…)"; the batched
  read is the `q='abc' in parents or …` pattern `DriveWalker` already uses,
  which only works grouped by parent. Fix: page the unmatched records in chunks
  of 40, group by `folder_id`, one batched query per (folder_id, chunk).
  Trigger: a sync that visibly hangs after a bulk Drive reorganisation.
- **Move the inline `<script>` in `DocumentsLive` into a hook.** It listens for
  `phx:open-url`, `phx:download-pdf` and a `visibilitychange` silent-refresh,
  guarded by `window.__pkDocCreatorInitialized` against duplicate registration.
  Script tags in a `~H` template are not executed by morphdom on navigation and
  break under a host `Content-Security-Policy: script-src 'self'`. The fix is a
  `js_sources/0` bundle exposing the hook under a namespaced global, and a
  mount-time `phx-hook` on a hidden element instead of the block.
