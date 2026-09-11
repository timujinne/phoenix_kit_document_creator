## 0.9.2 - 2026-09-11

### Fixed

- Core 2.21.3 renamed the website-wide integrations page from
  `/admin/settings/integrations/website` to `/admin/settings/integrations`
  (the `/website` segment only existed to disambiguate it from the personal
  page, which has since moved to `/profile/settings/integrations`). This
  module's two "manage connections" links (added in 0.9.1) still pointed at
  the old path, which no longer 404s — it matches core's
  `/admin/settings/integrations/:uuid` edit route with `uuid = "website"`,
  raises `Ecto.Query.CastError`, and surfaces as a LiveView reload loop. Both
  links now go through new `Paths.integrations/0` / `Paths.new_integration/0`
  helpers pointing at the renamed path (#46).
- Replaced the test suite's `psql -lqt` database-reachability check with
  core's `PhoenixKit.TestSupport.PostgresPreflight` where available. The old
  check ran over a unix socket as the shell's user, so a misconfigured role
  for TCP connections (e.g. no `postgres` role on a Homebrew install) reported
  the database as present and only failed later as a pool checkout timeout
  that read like flakiness; the preflight makes one bounded connection with
  the repo's own credentials and prints the actual reason (#45).

### Changed

- Upgraded locked dependencies: `phoenix_kit` 2.21.1 → 2.22.16, `leaf` 0.6.1 →
  0.7.0, `ranch` 2.2.1 → 2.3.0.

## 0.9.1 - 2026-09-07

### Fixed

- The folder-settings page's "Settings → Integrations" links (both the
  connection-picker's "Add" link and the manage-connections link) pointed at
  `/admin/settings/integrations[/new]`, which renders the **personal**
  integrations UI over a `{:user, uuid}` owner scope. Every read/write this
  module actually does (`list_connections/1`, `add_connection/2`,
  `get_integration/1`, ...) runs in the default `:system` scope, i.e. Settings
  → Integrations → **Website Integrations**. Following either link landed on a
  page that couldn't show the connection the picker just listed, and "Add"
  there would have created a connection this module never reads. Both links
  now point at `/admin/settings/integrations/website[/new]` (#44).

### Changed

- Upgraded locked dependencies: `phoenix_kit` 2.13.9 → 2.21.1 (pulls in the
  new `phoenix_kit_templates` dependency), `phoenix` 1.8.12 → 1.8.13,
  `phoenix_live_view` 1.2.10 → 1.2.11, `req` 0.7.3 → 0.7.4, `oban` 2.23.1 →
  2.24.1, `leaf` 0.5.1 → 0.6.1, `dialyxir` 1.4.7 → 1.4.8, `ex_doc` 0.40.3 →
  0.40.4, `hammer` 7.4.0 → 7.5.0, `mint` 1.9.3 → 1.10.0, `tesla` 1.21.2 →
  1.21.3, `quic` 1.8.1 → 1.8.2.

## 0.9.0 - 2026-08-25

### Changed

- **Template categories/groups/language now edit through a single modal**
  (#43). The old per-row dropdown popover (multi-category checkboxes + group
  select) and the separate language popover are gone — an "Edit" button opens
  a modal where categories, groups, and language are all edited as draft
  state and written once on Save, rather than round-tripping to the DB on
  every checkbox/select change. The dropdown popover also lost focus (and
  closed) on every `phx-change` patch, which made multi-category edits
  impractical; the modal is a `<dialog>` and isn't affected. The row/card now
  shows a compact read-only summary of the current language + categories.
- Date/time display (`format_time`/`format_datetime`) now renders the month
  name through `PhoenixKit.Utils.Date.short_month/1` (locale-translated)
  instead of `Calendar.strftime`'s English-only `%b`.
- Upgraded locked dependencies: `phoenix_kit` 2.13.5 → 2.13.9, `phoenix_pubsub`
  2.2.0 → 2.3.0, `swoosh` 1.27.1 → 1.28.0, plus `tz` added transitively.

## 0.8.0 - 2026-08-17

### Added

- **Category and Type names are now translatable per-language** (#41).
  `Taxonomy.localized_name/2` resolves a display name for `Category`/`Type`
  through the (previously unused) `data` JSONB column, mirroring
  `PhoenixKitCatalogue.Catalogue`'s translation mechanism on top of
  `PhoenixKit.Utils.Multilang.get_language_data/2` — no migration needed.
  Applied at every category/type display site: the admin taxonomy list, the
  document grid's category/type filters and pickers, the type-select in the
  category picker, and the preset form's category heading and "Document
  type" select. `CategoryFormLive` and `TypeFormLive` gain language tabs
  (via `PhoenixKitWeb.Components.MultilangForm`) so translations are
  actually enterable. `category_options/1` and `type_options/2` take an
  optional `locale` to return translated `options_for_select/2` labels.

### Changed

- Upgraded locked dependencies: `phoenix_kit` 2.4.0 → 2.8.1 (still within the
  `~> 2.4` pin — `MultilangForm`/`Multilang` predate that floor), plus
  `beamlab_countries`, `ecto`, `etcher`, and `quic` patch/minor bumps.

## 0.7.0 - 2026-08-14

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.4`.** `Template.changeset/2` now calls
  `PhoenixKit.Utils.Slug.put_slug/3`, which core did not ship until 2.4.0. The
  pin was raised from `~> 2.0` because that range admits cores where the
  function does not exist — and the failure would land in the **consumer's**
  app as an `UndefinedFunctionError` on every save touching `:name`, never in
  this repo's own run, since the workspace always resolves the newest core.
  Still two-segment, so every later 2.x satisfies it.

  `core_pin_conformance_test.exs` moved with it, and now guards both
  directions: too narrow (a three-segment pin collapsing to one minor) and too
  wide (a core lacking the function this module calls).

### Fixed

- **Renaming a template moved its URL.** The local `maybe_generate_slug/1`
  keyed on `get_change(:slug)` being nil, which is true both when the caller
  left the slug alone and when the record hasn't got one — so any save carrying
  no slug of its own re-derived it from the name, and nothing recorded the old
  one. Core's `put_slug/3` distinguishes the two: an explicit slug wins, an
  explicitly blanked one regenerates, and no slug at all defers to the stored
  record (#39).

- **Two templates with the same name silently shared a slug.** Nothing ever
  probed for collisions, which broke get-by-slug lookups. Slugs are now
  suffixed `-2`, `-3` … until free, excluding the row itself on update.

- **A generated slug could overflow `varchar(255)`.** `validate_length(:slug)`
  sat *before* generation, so it only ever saw explicitly-cast slugs; it now
  runs after, and `put_slug/3` is given `max_length: 255` so the suffix is
  trimmed into the cap rather than overflowing it (Postgres raises rather than
  truncating).

- **Two `:requires_unreleased_core` moduletags excluded nothing.** This repo's
  `test_helper.exs` stopped excluding that tag at core 2.0, so the slug tests
  were running against a Hex-resolved core all along rather than being masked
  as the PR assumed. Removed now that the pin guarantees the function is there.

## 0.6.0 - 2026-08-13

### Added

- **A template can belong to several categories at once** (#38). Membership
  moves from the single `category_uuid`/`type_uuid` pair on
  `phoenix_kit_doc_templates` to a many-to-many join table,
  `phoenix_kit_doc_template_taxonomy` — one row per `(template, category)`
  with its own optional group, unique on `(template_uuid, category_uuid)`.
  The admin UI gains a per-row checkbox popover for templates; documents keep
  their single-select dropdowns. `Taxonomy.set_template_memberships/3` is a
  transactional replace-all, and `Documents.list_templates_for_category/1` now
  sources through the join, so a multi-category template appears under each
  category annotated with that category's group.

- **Migration chain V2** creates the join table, backfills one row per template
  that currently has a category, and stamps a deprecation `COMMENT` on the
  legacy columns. ⚠️ **`down(target: 1)` destroys all multi-category data** —
  it drops the join table, and only the single-binding legacy mirror survives.

- **A "Standard groups" seed** (`Taxonomy.ensure_default_group_order/2`, plus a
  button in the categories admin) puts the nine canonical ANDI groups in order.
  Idempotent.

### Changed

- **The legacy `templates.category_uuid`/`type_uuid` columns are kept and kept
  populated** as a backward-compatibility mirror of the *primary* membership
  (the one whose category has the lowest `Category.position`), so the ANDI
  consumer keeps working unchanged until it migrates to the join table. **Do
  not drop them without a coordinated ANDI migration.** The mirror is
  recomputed from surviving active memberships on category/group
  trash and restore, so it never points at a trashed category and a
  multi-category template does not vanish from single-category readers.

- `trash_category/1` and `trash_type/1` no longer trash a template that still
  belongs to another active category.

- Dependency updates: `phoenix_kit` 2.3.0.

### Fixed

- **The image picker was hardcoded in Russian** (#37). Every visible string in
  `Web.Components.ImagePicker` was a Russian literal — "Убрать", "Сбросить",
  "Поиск по имени", "Файлы не найдены", "Назад", "Вперёд" — so an Estonian or
  English user got Russian in the middle of an otherwise translated page. All
  seven now go through Gettext, and the file counter became a real `ngettext/3`
  instead of the abbreviation that was there to dodge plurals. The documents
  view's "Search by name…" msgid had never been extracted, so it fell through
  to English in every locale; it is now in the catalogues.

- Four tests tagged `:requires_unreleased_core` no longer sit excluded from
  every run. They gate on `PhoenixKit.Integrations.add_connection/3`'s
  strict-UUID return shape, which was unpublished when the tag was added but
  has shipped since core 2.0 — and this package has pinned `~> 2.0` since, so
  every version the pin can resolve carries it. The exclusion had stopped
  protecting anything and was hiding four passing tests.

## 0.5.2 - 2026-08-12

### Fixed

- **Images silently vanished from composed documents whose earlier sections
  carried variables** (#35). Composing runs two phases — text substitution,
  then images. The image phase re-fetches the document so marker indices are
  current, but it matched those fresh indices against section ranges captured
  *before* any text was substituted. Substitution changes the document's
  length, so every index after an edit moves; a marker that drifted outside its
  own stale range was filtered out and skipped.
  `substitute_all_sections/3` still returned `:ok`, so nothing reported a
  problem — the images simply were not there.

  Measured on a live four-section compose: an image marker at 16145 with a
  section range of `{16080, 16227}` moved to 15975 after the text phase
  shortened the document by 170 units, falling below its own range, and ten
  drawings disappeared without an error. This is why the bug looked
  intermittent — the drift grows with how many variables the *preceding*
  sections carry, so reordering templates so the image section follows
  variable-heavy ones is enough to trigger it.

  Section boundaries are now shifted by the net length change of every
  replacement that starts before them (`shift_ranges/2`), counted in UTF-16
  code units — the unit Google Docs indices are expressed in.
- **Multiline values overstated that shift.** `insertText` does not store a
  value verbatim: Google strips control characters (U+0000–U+0008,
  U+000C–U+001F, which includes CR) and Private Use Area code points. A
  `:multiline` variable from a `<textarea>` routinely carries CRLF endings, so
  counting the raw value dragged every later boundary rightward. Values are now
  sanitized once and that exact string is used both for the `insertText`
  request and for the delta arithmetic, so the two agree by construction.

### Changed

- Dependency updates: `phoenix` 1.8.11, `beamlab_ex_aws_sqs` 5.0.1, `hackney`
  4.7.4 and the transitive set.

## 0.5.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.5.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Fixed

- **Silent `batchUpdate` failures (PR #33).** `batch_update/2` was the only
  client function that never checked HTTP status — a 400 from Google returned
  `{:ok, resp}` and every caller reported success on an unmodified document.
  `batchUpdate` is atomic and rejects `insertText` with empty text, so a single
  blank variable voided **every** substitution in a composed document, with no
  error and no log. Blank values now emit only the `deleteContentRange`.
- **Dropped tables on append (PR #33).** `append_template/2` flattened via
  `get_document_text/1`, which walks only paragraph blocks, so tables — and any
  `{{var}}` living solely inside a table cell — were silently discarded.
- **Cross-section table corruption (PR #33).** Pre-existing table positions were
  read from `el["table"]["startIndex"]`, a field that does not exist in the real
  API (`startIndex` belongs to the surrounding `StructuralElement`). Every
  pre-existing table reported `nil`, and Erlang term ordering sorts `nil` after
  every integer — so once more than one table-bearing section was appended, a
  later section's cell text was written into an earlier section's table. Fixed
  at all four call sites; the existing test mocks had encoded the bug rather
  than the real API shape and were corrected.
- **Formatting loss on append (PR #33).** Column widths, character styles,
  alignment, line spacing, named styles, indents and list bullets now survive an
  append, each stated explicitly (including `bold: false`) so a fresh insert
  cannot inherit a neighbour's formatting.
- **Section boundaries merged paragraphs (PR #33).** `insertPageBreak` inserts
  an inline element, not a paragraph break, so an appended section's first
  paragraph structurally merged with the target's last one and reformatted the
  preceding section's tail. A literal newline now precedes the page break.
- **Delete succeeds for orphaned rows (PR #33).** A row whose Drive file was
  hard-deleted out-of-band could never be removed — `move_to_deleted_folder`
  treated the 404 as fatal. A missing file now proceeds with the DB soft-delete;
  a 404 on the move PATCH stays distinct as `:move_failed`.
- **Template slugs were still ASCII-only (PR #32).** The delegation to core's
  `Slug.slugify/1` added in #31 was a silent no-op: `transliterate` defaults to
  `false`, so the `[^a-z0-9]+` pass still deleted every Cyrillic character and a
  Cyrillic or Greek template name produced an **empty** slug — exactly the bug
  #31 set out to fix. Now passes `transliterate: true`.

### Changed

- Taxonomy UX (PR #33): new categories/types default to one past the highest
  active sibling instead of position 0; stale references to trashed
  categories/types render a visible placeholder instead of looking cleared; the
  flattened "All Types" filter prefixes each type with its owning category.

## 0.4.8 - 2026-06-16

### Changed

- **`VariableConfigForm` now derives the annotated toggle state through `Variable.image_config_annotated?/1`** instead of its own `config_value/3` lookup. This makes the checkbox preview a single source of truth with the canonical host-app accessor — they previously diverged on a mixed atom/string-keyed config (`%{annotated: nil, "annotated" => false}`) — and guarantees `current_annotated` is a strict boolean, matching its `attr :boolean` contract.

## 0.4.7 - 2026-06-16

### Added

- **Per-slot `annotated` flag for image variables.** Template authors can now toggle whether each `{{ image: … }}` / `{{ images: … }}` slot includes annotation-flattened images (`true`, default and existing behaviour) or the raw photo (`false`). The flag lives in the variable's `config` jsonb, is edited through a toggle in the template editor, and is surfaced string-keyed via `Documents.image_slots_for_template/1`. The library stores and carries the flag but does not flatten annotations itself — that remains the host app's responsibility when building `image_params` for `substitute_images/3`.
- **`Variable.image_config_annotated?/1`** — canonical accessor that reads either atom- or string-keyed `annotated` values and defaults to `true` when missing or `nil`, so host apps don't need to know the config key shape.

### Changed

- **`Documents.coerce_config/1`** now stringifies incoming config keys before coercion, so atom-keyed caller input (e.g. `%{annotated: false}`) is stored uniformly string-keyed and won't produce duplicate JSON keys in jsonb.
- **`parse_bool/1`** now treats `nil`/empty as the safe `true` default and drops unrecognised values via `:skip` (preserving the existing stored value), instead of silently coercing every unknown input to `true`.
- **`parse_columns/1`** now requires the whole input string to parse as an integer (aligning with `parse_integer/1`), so values like `"2abc"` no longer clamp to `2`.
- **`resolve_slot_config/3`** now drops `nil` saved values before merging defaults, preventing an explicit `%{"annotated" => nil}` from shadowing the default with `nil`.
- **External links open safely.** All `target="_blank"` anchors in `DocumentsLive` now carry `rel="noopener noreferrer"`, not only the row-action menu links.
- **Dependencies refreshed.** `phoenix_kit` 1.7.126 → 1.7.144, `phoenix_live_view` 1.1.31 → 1.2.0.

### Internal

- **`mix precommit` hardened** with `hex.audit` and `mix test --warnings-as-errors`; surfaced and fixed warnings across the suite.
- Row-menu edit/view links now use the native `target`/`rel` attr support in PhoenixKit core components rather than dynamic spread workarounds.

## 0.4.6 - 2026-06-09

### Fixed

- **Image height arithmetic no longer divides by nil.** `GoogleDocsClient.build_media_items/1` now preserves the source `height_px` so `scale_height/3` always has a denominator; previously a missing height could crash the inline image sizing path.
- **`scale_height/3` hardened against nil source height.** If the source height is missing, the function now falls back to the configured/default height instead of raising.
- **Image config lookup centralised.** Both the inline and table-grid image paths read width/height config through the same helper, removing an atom-keyed fallback that mishandled explicit `false` for future boolean flags.

### Changed

- **Dependencies refreshed.** `phoenix_kit` 1.7.126 patch bump.

### Internal

- Added regression tests pinning the exact rendered height (`450.0 PT`) and ensuring `build_media_items/1` carries `height_px` end-to-end.

## 0.4.5 - 2026-05-31

### Added

- **Sortable Documents/Templates columns.** The Name / Status / Created / Modified headers are now sortable via PhoenixKit's `sort_header_cell` (default **Modified ↓**); a click toggles the column, a second click flips direction. Sorting is applied in memory before pagination and a whitelisted field parser guards the `toggle_sort` payload.
- **Ellipsis (⋯) row-action menu.** The per-row action buttons (Edit/View, Export PDF, Restore/Delete) are replaced with PhoenixKit's `table_row_menu` dropdown in both the table and card views, preserving the per-status actions and their `phx-disable-with` guards.

### Changed

- **Sort state is URL-driven.** `toggle_sort` now `push_patch`es `sort_by` / `sort_dir` into the URL (read back in `handle_params`) like every other piece of table state, so the active sort is bookmarkable, shareable, and survives reload/back; the change also resets `page=1` in the URL so the page param can no longer go stale. Pagination links carry the sort params too.
- **Date columns sort chronologically.** Created / Modified now compare parsed `DateTime` values via `DateTime.compare/2` (timezone-aware, naive values read as UTC) instead of lexicographic ISO-8601 strings, so rows order correctly across differing offsets and textual precision.
- **Status column sorts by rank.** The Status column orders by a fixed rank (unfiled → lost → published) rather than alphabetically, surfacing the attention-needing states first; unknown/`nil` statuses still sort last in both directions.
- **Dependencies refreshed.** `phoenix_kit` 1.7.125 → 1.7.126, `swoosh` 1.25.3 → 1.26.0.

## 0.4.4 - 2026-05-29

### Fixed

- **Documents/Templates card layout.** daisyUI's default `.card-body` padding (1.5rem) was stacking on top of the card's custom inner spacing, leaving a ~24px gap between the thumbnail and the title and a dead band under the action buttons; the card now zeroes `.card-body` padding via `[&_.card-body]:p-0` (targeting the nested element so a future `card-sm`/`card-md` size variant can't defeat it). The Category/Type `<select>` pickers no longer clip their trailing option in narrow cards — in the card view they shrink together and wrap to a second row, while the table-view row keeps the original inline, intrinsic-width pickers.

### Changed

- **Dependencies refreshed.** `phoenix_kit` 1.7.119 → 1.7.125, `phoenix_live_view` 1.1.30 → 1.1.31, `oban` 2.22.1 → 2.23.0, `leaf` 0.2.13 → 0.2.21, `fresco` 0.5.8 → 0.6.3, `etcher` 0.4.9 → 0.5.3, plus `swoosh`, `ex_aws_sns`, and `decimal` patch bumps.

### Internal

- **Document card render helpers are now declared function components.** `render_thumbnail/1`, `render_language_picker/1`, and `render_category_picker/1` carry `attr` declarations and are invoked via `<.component />`, so each call site is validated at compile time; the category picker's layout variant is now an `attr :layout, values: ~w(inline card), default: "inline"` and is resolved once into a `card?` assign. No behavior change.

## 0.4.3 - 2026-05-22

### Changed

- **Denser, responsive Documents/Templates card grid.** Re-enabled the `card_grid_class` attr on `<.table_default>` (removed in 0.4.2 because the released core lacked it) so the grid now scales from one column up to six (`grid-cols-1` … `2xl:grid-cols-6`). The toolbar is responsive: below `sm` the page actions collapse into a single dropdown and the filters hide behind a "Filters" toggle; on `sm`+ they show inline. Requires `phoenix_kit` ≥ 1.7.118 (locked at 1.7.119).
- **Category / Type / Preset forms use the shared core components.** Converted the hand-rolled `<input>` / `<label>` / manual error loops in `CategoryFormLive`, `TypeFormLive`, and `PresetFormLive` to the PhoenixKit core `<.input>` / `<.select>` / `<.textarea>` components, so label and column alignment match the rest of the admin UI and validation errors render through the shared gettext path.

### Fixed

- **Card-grid loading skeleton matches the loaded grid.** The skeleton used `gap-4` while the real card grid uses `gap-3`, so card spacing visibly shifted when loading finished; both now use `gap-3`, and `card_grid_class` carries an explicit `grid-cols-1` base.

## 0.4.2 - 2026-05-21

### Fixed

- **Documents listing compiles clean again.** Removed the `card_grid_class` attr passed to `<.table_default>` in `DocumentsLive` — it is not defined in the released `phoenix_kit` core component, so it failed `mix precommit` (`compile --warnings-as-errors`) and was silently dropped at runtime by the component's `:global` attr (no effect on the card grid). The denser grid awaits a core release that ships the attr; see the marker comment at the call site.
- **Drive image upload hardened.** `GoogleDocsClient.upload_image_for_embedding/3` now escapes backslashes (before quotes) when building the multipart metadata JSON, so a file name containing `\` can no longer produce an invalid metadata object. Manual JSON construction is retained to avoid a transitive Jason dependency.

## 0.4.1 - 2026-05-21

### Added

- **Category → Type taxonomy.** Replaces the hard-coded category strings with a managed two-level **Category → Type** hierarchy. New `Category` / `Type` schemas (UUIDv7, soft-delete via `status`) and a `PhoenixKitDocumentCreator.Taxonomy` context — CRUD, cascade trash/restore in one transaction, reorder, and picker helpers. Templates and documents gain nullable `category_uuid` / `type_uuid` FKs; a document inherits its taxonomy from the source template. Admin UI at `/admin/document-creator/categories`: two-column `CategoriesLive` (categories | types of the selected category), `CategoryFormLive` / `TypeFormLive` create-edit pages, row menus (Edit / Trash / Restore / Delete Forever), and drag-to-reorder via the `SortableGrid` hook. Category + Type `<select>` pickers appear on template/document cards (read-only badges in the trash view). Requires the **V120** migration from `phoenix_kit` core. UI localized for `en` / `et` / `ru`.
- **Preset management UI.** An admin surface for the composition presets introduced in 0.4.0. `PresetFormLive` — a name / description / type form with a section editor and per-variable defaults — plus a presets panel in `CategoriesLive` for managing presets per category. New API: `Documents.update_preset/2`, `delete_preset/1`, and `preset_stale_info/1` (flags sections that point at deleted templates). The section editor operates on `Template` structs, preserves the original author on edit, and keeps sections referencing non-published templates. Strings localized for `en` / `et` / `ru`.
- **Multi-column images.** `{{ images: name }}` (`image_list`) slots can render as an N-column grid (1–4) instead of a vertical stack. Authors set the default column count per variable in the template editor (a Columns `<select>` alongside `separator`/`max_count`); the value rides through to `image_params[slot]["columns"]`. Rendering uses a two-phase Google Docs `batchUpdate`: Phase 1 deletes the placeholder and inserts a table (`rows = ceil(n / cols)`); Phase 2 re-fetches the doc and fills each cell with `insertInlineImage`, sized via `image_width_for_columns/2` and inserted last-first to avoid index drift. `columns == 1` keeps the inline path. New public `GoogleDocsClient` helpers: `content_width_pt/1`, `image_width_for_columns/2`, `table_image_inserts/3`, `fill_table_cells/3`, `match_new_tables/3`.
- **Composed-document recipe persistence.** `Documents.create_composed_document/2` accepts a `:data` map persisted on `Document.data`, so the host app can store the template/image selection ("recipe") that produced a document and re-create it later.
- **Trash provenance.** Trashing a document/template stamps `data["deleted"]` with `at` + `by_uuid` (NULL-safe jsonb merge that preserves sibling keys); restoring clears it. The Documents trash view shows "&lt;date&gt; · &lt;who&gt;" (display name resolved from the actor uuid). Restoring a file that was deleted from Drive surfaces `:drive_file_not_found` with a dismissible warning banner instead of a hard error.
- **`Taxonomy.count_categories/1` and `count_types_for_category/2`** — SQL `COUNT` helpers used for the Active/Trash badge counts.
- **`Documents.image_slots_for_template/1`** now returns `%{name, kind, config}` so consumers (e.g. the order-document picker) can read `columns`/`max_count`/etc. without re-querying the template. The merged config is normalised to string keys.

### Changed

- **Categories Active/Trash sub-tabs** unified with the Documents page style — string `status_mode` assigns, a shared `status_subtabs` component, and auto-hide of the sub-tab row when Trash is empty. The Categories sidebar tab now sorts last (`priority` 647 → 651, after Documents/Templates).
- **Trashed-by name resolution moved off the LiveView render path.** Names are resolved once when the trashed lists load/sync and read from assigns, rather than querying `Auth.get_users_by_uuids/1` on every render.

### Fixed

- **Drift-proof multi-column table identification.** Phase 2 now matches newly-inserted tables by document order (`match_new_tables/3`) instead of a `startIndex` set-difference. The old approach misclassified any pre-existing table located *after* a multi-column placeholder (Phase 1's inserts shift its index), tripped the count guard, and left every grid in the document empty.
- **Trash badge counts** use SQL `COUNT` instead of loading every soft-deleted row just to take its length.
- **Deletion metadata** is stamped/cleared only on the table that owns the `google_doc_id` (derived from the folder key / restore type), instead of running an `update_all` against both `Document` and `Template`.
- **Stale tests** brought in line with shipped behaviour: `insertInlineImage` object sizes are asserted in `PT` (not `EMU`); `image_slots_for_template/1`'s config-bearing return shape is covered. Both were assertions against already-correct code that only ran with a database.

### Internal

- **`mix precommit` is green** end-to-end (`compile --warnings-as-errors`, `deps.unlock --check-unused`, `format`, `credo --strict`, `dialyzer`). Resolved pre-existing `credo --strict` complexity/nesting findings via pure extractions in `documents.ex`, `google_docs_client.ex`, `google_oauth_settings_live.ex`, and `preset_form_live.ex`; added `.dialyzer_ignore.exs` for `call_without_opaque` false positives on opaque external types (`Gettext.Plural`, `MapSet`, `Ecto.Multi`).
- Duplication removed via shared helpers: `Taxonomy.apply_status_filter/2` (list/count) and `GoogleDocsClient.cached_folder_id_keys/0`.

## 0.4.0 - 2026-05-13

### Added

- **Document composition.** Build a single Google Doc from N template sections, each with its own variable map and image config. Public API: `Documents.create_composed_document/2`. Sections are persisted as `DocumentSection` rows (`template_uuid`, `position`, `variable_values`, `image_params`) so the recipe survives template edits. Per-section variable substitution is range-scoped — identical `{{name}}` keys in different sections resolve independently (`GoogleDocsClient.substitute_in_range/5`). Whole flow is wrapped in `Ecto.Multi` with best-effort Google Doc cleanup on rollback.
- **Template presets.** Named, reusable composition recipes scoped via `scope_type` + `scope_id` and optionally categorized. New schema `TemplatePreset` (jsonb `sections` array). API: `Documents.save_preset/1`, `list_presets/1`, `apply_preset/1`, `recipe_for/1`. `apply_preset/1` returns `{:ok, sections} | {:error, :not_found}` and drops sections referencing deleted templates with a warning.
- **Template category.** New `category` string column on `phoenix_kit_doc_templates` (V117). Admin UI gains a popover category picker on each template card (cards + list views). API: `Documents.update_template_category/3` — emits `template.category_updated` activity row and broadcasts `:files_changed`.
- **`Documents.image_slots_for_template/1`** — extracts `{{ image: name }}` / `{{ images: name }}` slot names + kinds from a template's Google Doc text via the injectable docs client.
- **`Documents.update_template_variable_config/3`** — persists per-variable `config` edits (`default_width_px`, `separator`, `max_count`) into `phoenix_kit_doc_templates.variables` jsonb. Coerces empty / non-integer form inputs to skip rather than crash on `String.to_integer/1`. Used by the `VariableConfigForm` inside `CreateDocumentModal` for `:image` and `:image_list` variables (debounced 500ms on `phx-change`).
- **`ImagePicker` LiveComponent** — generic, parameterised by `(scope_type, scope_id, mode, current_selection, files)`. Server-side pagination (page size 50) and name-substring filter. Host owns file resolution and receives `{:image_picker_changed, picker_id, selection}` messages.
- **Migration V117** — `category` column on templates, `phoenix_kit_doc_document_sections` (unique on `(document_uuid, position)`), `phoenix_kit_doc_template_presets` tables.
- **`PhoenixKitDocumentCreator.Application`** — module-application registered via `mix.exs :mod`. Starts conditional Oban supervision when the host app supplies `:phoenix_kit_document_creator, Oban` config; otherwise an empty supervisor. Does **not** start `PhoenixKit.Supervisor` (the host app owns it).
- **Test scaffolding** — `StubDocsClient` + `StubDocsClientHelpers` for call-order assertions without HTTP traffic; `LiveCase.render_live/2` + `ComponentHostLive` for isolated LiveComponent testing.

### Changed

- **`Composer.compose/2` returns `{:error, {:unsupported_separator, sep}}`** for separators other than `:page_break` (MVP scope), instead of raising `ArgumentError`. Uniform tagged-tuple contract across the module and `Documents.create_composed_document/2`.
- **`Documents.create_composed_document/2` broadcasts `:files_changed`** on success so connected admin LiveViews resync, matching every other mutation path in the context.
- **`mix.exs` `:compilers`** — extends `Mix.compilers()` (`[:phoenix_kit_css_sources] ++ Mix.compilers()`) instead of replacing it. Fixes parent apps consuming this library as a path dep — `.beam` files were not being written, so `Documents.create_composed_document/2` etc. appeared undefined.

### Fixed

- **`GoogleDocsClient.insertInlineImage` Unit** — switched from `EMU` to `PT` (1 px = 0.75 pt). The Docs API only accepts `PT` or `UNIT_UNSPECIFIED`; the previous `EMU` made every image-substitution `batchUpdate` 400 with `INVALID_ARGUMENT`, so image-variable substitution never actually inserted anything in real usage.
- **`DocumentsLive` empty-render crash** — `render_category_picker/1` was called as a plain function in HEEx and tried `assign/3` on a hand-built map, crashing `ArgumentError` on every render. Now matches the convention used by `render_language_picker/1` just above it (calls `category_options()` inline).
- **`Composer` merge precedence** — earlier section positions now win on key collision (`Map.merge(vals, acc)` rather than the reverse) so a section-0 value isn't overwritten by a section-1 value during multi-section substitution.
- **`config/config.exs` Oban block** gated on `config_env() != :test` so the library's standalone test suite can boot. Host apps overriding the entire `:phoenix_kit_document_creator, Oban` keyword are unaffected.

### Removed

- **`createPositionedObject` from image inserts.** Research against the Google Docs API reference confirmed `createPositionedObject` is not a valid `batchUpdate` request type — positioned objects can only be created interactively in the editor UI. The path was never reachable from any caller (default `z_index` is 0) so production traffic was unaffected. `z_index > 0` and `opacity != 1.0` now log a warning and fall back to `insertInlineImage`.

### Known limitations (deferred to follow-ups)

- `image_params.opacity` and `image_params.z_index` are stored on `DocumentSection` and accepted by `ImagePicker`'s config, but currently no-op at render time — the Google Docs API has no surface for image opacity, and positioned objects can't be created via `batchUpdate`. Stored for future activation if/when the API gains support.
- `TemplatePreset.sections` is an unschema'd `{:array, :map}` — typos in section descriptor keys are silent at save time and surface as "dropped section" warnings at `apply_preset/1` time. An embedded schema would tighten this.
- Orphan-doc sweeper (`TODO(orphan-doc-sweeper)` in `composer.ex`) not yet implemented — when a `Multi` rolls back after `:google_doc` succeeds, the best-effort `delete_document/1` only logs on failure; no periodic reconciliation yet.
- Standalone dev/prod Oban config in `config/config.exs` still references a non-existent `PhoenixKitDocumentCreator.Repo`. Harmless when this library runs as a dependency (host overrides), but should be either repaired or removed.
- The PubSub topic `"document_creator:files"` is not tenant-scoped. Fine for single-tenant hosts; a multi-tenant host should scope by tenant id.

## 0.3.0 - 2026-05-11

### Added

- Image placeholders in templates: `{{ image: name }}` for single images and `{{ images: name }}` for ordered lists. Variables detected via forked `extract_variables/1` returning `%{text: [...], image: [...]}`. Filled via PhoenixKit `MediaBrowser` selector in the create-document modal. Per-variable config (`default_width_px`, `separator`, `max_count`) editable via the `VariableConfigForm` component (read-only in v1; admin persistence is a follow-up). Substitution is a two-pass batchUpdate: text-first via `replaceAllText`, then images via `documents.get` + `DeleteContentRange` + `InsertInlineImage`. `find_image_tag_ranges/2` correctly handles multi-byte (UTF-16) prefix text via codepoint counting.
- `Variable.extract_string_variables/1` and `Variable.extract_image_variables/1` — public leaf detectors; `extract_variables/1` now returns `%{text: [...], image: [...]}` (breaking change within this module's public API).
- `Variable` struct gains a `config` field: `%{default_width_px: 400}` for `:image`, plus `separator` and `max_count` for `:image_list`. Stored in the existing `variables` jsonb column.
- `GoogleDocsClient.substitute_images/2` — walks `documents.get` content, finds every image tag occurrence by UTF-16 code unit offset, then issues a single `batchUpdate` with `DeleteContentRange` + `InsertInlineImage` per occurrence. Handles both single and list cases; inserts are ordered from last to first occurrence to preserve indices.
- `Errors` atoms: `:image_not_found`, `:image_url_not_public`, `:image_insert_failed`, `:image_tag_not_found`.
- Admin fill form: `:image` variables render a "Choose image" button; `:image_list` variables render "Choose images" (multi-select). Sequential media picks accumulate via `picking_existing` URL param so earlier selections are not lost when returning from the `MediaBrowser`.
- Persistence for image-variable `config` edits: `Documents.update_template_variable_config/3` writes per-variable config (`default_width_px`, `separator`, `max_count`) back to `phoenix_kit_doc_templates.variables` jsonb on `phx-change` from the modal form. Per-template scope, broadcasted via `broadcast_files_changed/0`. `VariableConfigForm` is now rendered inside `CreateDocumentModal` for `:image` and `:image_list` variables.

### Changed

- `Documents.detect_variables/1` now returns `{:ok, %{text: [...], image: [...]}}` — callers that expected a flat list must be updated.
- `Documents.create_document_from_template/3` orchestrates two ordered `batchUpdate` passes: text substitution first, image substitution second.
- Text-variable regex gains explicit negative-lookahead `(?!images?\s*:)` to encode the invariant that `{{ image: x }}` tags are never captured as text variables.

### Fixed

- UTF-16 code unit offset bug in `match_to_range/4`: `Regex.scan` returns byte offsets; arithmetic now converts the prefix-and-match bytes through `:unicode.characters_to_binary(_, :utf8, :utf16)` so both BMP characters (Cyrillic, Latin extended, common CJK) and supplementary-plane codepoints (emoji, rare CJK extensions) contribute the correct number of `startIndex` units to the Drive document.
- `Errors`: dropped two unemitted atoms (`:image_too_large`, `:missing_required_value`) plus their `message/1` clauses — neither was returned by any module and the gettext entries would have shown up as obsolete on the next extract.
- `VariableConfigForm.separator_options/1`: replaced raw-HTML `Phoenix.HTML.raw/1` interpolation with HEEx `<option>` tags so gettext-resolved labels go through automatic escaping.
- `DocumentsLive`: media-picker round-trip JSON now uses the built-in `JSON` module (Elixir 1.18+) instead of `Jason`, matching the rest of the codebase.

### Known limitations (deferred to follow-ups)
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
