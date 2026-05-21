# Follow-up: post-merge fixes for PR #20 / #21

**Date**: 2026-05-21
**By**: @claude (Dmitri Don)

Applied directly to `main` after the review in [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md).
All non-integration tests pass (`343 tests, 0 failures`, integration excluded — no local
PostgreSQL); `mix format` clean; and after item #8, the full `mix precommit` pipeline
passes (compile `--warnings-as-errors`, `deps.unlock --check-unused`, format,
`credo --strict`, dialyzer).

## 1. Stale `image_slots_for_template/1` test (review #1)

`test/integration/image_slots_test.exs` — replaced the exact-`==` assertion on the old
`%{name, kind}` shape with a `Map.take(.., [:name, :kind])` projection, plus an explicit
check that the `image_list` slot exposes `config["columns"] == 1`. The old assertion
would have failed under PostgreSQL once `:config` was added.

## 2. Drift-proof Phase-2 table identification (review #2)

`lib/phoenix_kit_document_creator/google_docs_client.ex`

- Added `match_new_tables/3`: reconstructs the pre/new table interleaving from the
  *doc2* (pre-Phase-1) indices and reads it off the post-Phase-1 tables **positionally**.
  Table order is never changed by inserts, so this is immune to the index drift that
  broke the old `startIndex` set-difference. Returns `:mismatch` (caller skips Phase 2)
  when counts don't line up.
- Rewrote `do_fill_table_cells` to use it; extracted the success branch into
  `fill_matched_tables/5` (also clears a Credo nesting finding).
- Tests: 5 new `match_new_tables/3` cases in `google_docs_client_table_test.exs`,
  including the previously-broken "pre-existing table **after** a placeholder" scenario
  and the "between two placeholders" case.

## 3. Move user-name resolution off the render path (review #3)

`lib/phoenix_kit_document_creator/web/documents_live.ex`

- Added `deleted_by_names` to mount assigns and `assign_deleted_by_names/1`, which
  resolves names from both trashed lists and is called only where those lists change
  (`:load_initial`, `:sync_from_drive` completion, `patch_file_in_assigns`).
- `assign_files/2` now reads `assigns.deleted_by_names` instead of querying per render.

## 4. Count queries for trash badges (review #4)

- `lib/phoenix_kit_document_creator/taxonomy.ex`: added `count_categories/1` and
  `count_types_for_category/2` (SQL `COUNT`, same `:status` semantics as the list fns).
- `web/categories_live.ex`: `reload_categories`/`reload_types` use the count helpers for
  the active-mode trash badge instead of `length(list_*(status: "deleted"))`.

## 5. Stamp/clear only the relevant schema (review #5)

`lib/phoenix_kit_document_creator/documents.ex`

- `stamp_deleted_data/3` and `clear_deleted_data/2` now take the schema. The schema is
  derived from `folder_key` (`deleted_schema/1`) on delete and from `type`
  (`restored_schema/1`) on restore, so only the table that owns the `google_doc_id` is
  updated instead of running an `update_all` against both.

## 6. EMU→PT test drift (review #6, pre-existing)

`test/.../google_docs_client/image_substitution_test.exs` — two `build_image_batch_requests/2`
single-image tests still asserted EMU object sizes; the code has emitted PT since
`fae10c8` (predates #20), so they were failing on `main`. Updated to PT (`px * 0.75`).

## 7. Readability: extract `apply_image_fills/3`

`lib/phoenix_kit_document_creator/google_docs_client.ex` — pulled the non-empty-fills
branch of `substitute_all_images` into `apply_image_fills/3`, leaving a clear
gather-then-apply shape and clearing that function's Credo nesting finding. Pure
extraction, no behavior change.

## 8. Make `mix precommit` green (credo --strict + dialyzer)

`mix precommit` was already red on `main` before this work (pre-existing debt, none from
the items above). Resolved so the whole pipeline passes:

- **Credo `--strict`** (was 8 refactoring + 2 design findings → **0**), all pure
  extractions with no behavior change:
  - `documents.ex`: split `update_template_variable_config` into
    `fetch_template_by_file_id` / `merge_variable_config` / `write_variable_config!`;
    aliased `Ecto.Adapters.SQL`. Flattened `rename_document` into a single `with`
    (dropping the redundant last clause; also covers review #7's nesting-by-extraction
    pattern for that function).
  - `google_docs_client.ex`: extracted `migrate_folder_candidate` /
    `resolve_migration_folder_id` / `move_migration_folder` / `clear_cached_folder_ids`
    from `migrate_folders_to_root`.
  - `google_oauth_settings_live.ex`: decomposed `save_folders` into six helpers and
    extracted `run_folder_migration` from `migrate_folders` (helpers placed below the
    `handle_event/3` clauses so the clause group stays contiguous).
  - `preset_form_live.ex`: extracted `match_section_by_id` from `reorder_sections`.
  - `rename_document_test.exs`: aliased `Test.StubDocsClient`.
- **Dialyzer** (5 `call_without_opaque` false positives → ignored): added
  `.dialyzer_ignore.exs` for the opaque external types `Gettext.Plural`, `MapSet`
  (`stale_info`), and `Ecto.Multi` (composer), wired via `mix.exs` `ignore_warnings`.
  Matched by `{file, warning_type}` so the entries survive line shifts; dialyzer reports
  `Unnecessary Skips: 0`.

## 9. Code-review pass (reuse / quality / efficiency)

A three-agent review of items #1–#8 surfaced these fixes — all pure refactors, no
behavior change, `mix precommit` still green:

- **Efficiency:** dropped the redundant `assign_deleted_by_names/1` call from
  `patch_file_in_assigns/2` (`documents_live.ex`). That path only fires on active-file
  taxonomy changes (pickers render in the active view only) and never mutates the trashed
  lists, so it re-queried `get_users_by_uuids` per pick for a map the trash-only view
  never reads. `:load_initial` / `:sync_from_drive` already cover every trashed-list
  change; the helper's comment was corrected to drop the stale "optimistic move" claim.
- **Quality:** removed a dead `MapSet.new |> MapSet.to_list` round-trip in the Phase-2
  table flow (`google_docs_client.ex`) — leftover from the old set-difference algorithm;
  `match_new_tables/3` is order-based and needs only a list, so `pre_existing_table_starts`
  is now collected directly as one.
- **Reuse / Quality:** extracted `GoogleDocsClient.cached_folder_id_keys/0` (backed by
  `@cached_folder_id_keys`) so `google_oauth_settings_live.ex` no longer duplicates the
  folder-cache key list.
- **Quality:** extracted `Taxonomy.apply_status_filter/2`, shared by all four
  `list_*`/`count_*` functions (was a copy-pasted `:status` `case`).
- **Reuse:** `fetch_template_by_file_id/1` now reuses `get_template_by_google_doc_id/1`
  instead of repeating the `get_by`.

Flagged but intentionally skipped (verified false positives / would change behavior):
reusing the dep's `User.full_name/1` (different fallback chain — would regress to `nil`);
unifying `deleted_schema/1` ⇄ `restored_schema/1` (the delete and restore paths genuinely
speak different atom domains); making `match_new_tables/3` private (public-for-test is the
module's established convention); and adding the name-resolve to `apply_optimistic_move`
(unnecessary — the optimistic file map has no `data.deleted.by_uuid` until the next sync).

## Not done (out of scope / deferred)

- End-to-end test of the `substitute_all_images` Phase 1/2 orchestration. `get_document`
  and `batch_update` go through `authenticated_request` (real OAuth HTTP), so this needs
  full integration setup (DataCase + stubbed Drive/Docs requests) and would be DB-gated
  — i.e. it would not run in the sandbox. Deferred; the pure helpers it delegates to are
  covered.
- Empty trailing grid cells when `media` doesn't fill the last row (cosmetic).
