# PR #22 Review: table_default port + upstream merge

**Verdict: PASS with one medium-severity bug**

---

## Stage 1: Spec Compliance

### 1. `documents_live.ex` ported to `<.table_default>` -- PASS
- `render_file_grid/1` (line 1436) correctly uses `<.table_default>` with `card_media`, `card_body` slots, and `table_default_*` primitives for list view.
- `view_mode` mapping (line 1454): `"cards"` -> `"card"`, `"list"` -> `"table"` -- correct for the component's `values: [nil, "card", "table"]`.
- `card_grid_class` (line 1471) overrides the default column density -- correct.
- `show_toggle={false}` (line 1455) since the page owns its own toggle buttons -- correct.
- `card_class` (line 1459) uses a 1-arity function per item for conditional pending opacity -- component handles this (confirmed `table_default.ex` normalizes fn/string).

### 2. Upstream merge integrity -- PASS
- **Old fork functions removed**: `build_image_batch_requests_with_embedded_fills`, `resolve_image_tag_fill`, `ensure_batch_success`, `in_section_range_tuple` -- zero hits in `lib/` and `test/` across both repos.
- **Upstream image engine intact**: `apply_image_fills`, `match_new_tables`, `build_image_batch_requests/3`, `find_image_tag_ranges/2` all present in merged `google_docs_client.ex`.
- **Fork-unique functions re-added**: `upload_image_for_embedding/3` (line 1277) and `set_anyone_reader_permission/1` (line 1326) present with all dependencies (`@drive_upload_base`, `@drive_base`, `authenticated_request/3`, `log_drive_error/2`).
- **Andi caller**: `/www/app/lib/andi/orders/document_creator.ex:556` calls `GoogleDocsClient.upload_image_for_embedding(data, mime_type)` -- signature matches.

### 3. `documents_live.ex` auto-merge completeness -- PASS
- Fork features preserved: `@per_page` (line 29), `page` assign (line 60), `filters` assign (line 61), `handle_params` pagination (lines 96-123), `filter_files/2` (line 1937), `per_page/0` helper (line 1902), search input (line 1062), Created column (line 1674).
- Upstream additions preserved: `deleted_by_names` (line 65), `assign_deleted_by_names/1` (line 1390), taxonomy `set_taxonomy_category/type` handlers (lines 469-501), `Taxonomy` alias (line 22).
- No duplicated function clauses or orphaned assigns.

### 4. Composer changes -- PASS
- `common_type_uuid/2` (line 125) propagates shared type_uuid to composed documents -- clean logic.
- Orphan doc cleanup on substitution failure (lines 160-182) -- correct restructure from flat `with` to `case` + nested `with`.

### 5. Tests -- PASS
- New test `describe "duplicate slot names across sections"` (152 lines) covers the cross-section slot collision regression.
- All existing tests reference `build_image_batch_requests/3` and `find_image_tag_ranges/2` which exist in the merged file.

### 6. No conflict markers -- PASS
### 7. Version 0.4.1 -- PASS

**Spec Verdict: PASS**

---

## Stage 2: Code Quality

### BUG - MEDIUM: Search query (`q`) dropped on view/status switch
**File**: `documents_live.ex:1913`
**Problem**: `list_path_with_params/2` builds `base_params` from `assigns.filters` but omits the `"q"` key. When a user switches view mode (`switch_view`) or status tab (`switch_status`) while a search query is active, the `"q"` param is lost from the URL, clearing the search silently.
**Suggestion**: Add `"q" => assigns.filters["q"]` to the `base_params` map at line 1913.
**Rationale**: The `filter` handler works because it passes `new_filters` (which includes `"q"`) as `extra_params`, but the other two handlers only pass their single changed param. This is a functional regression -- the user types a search, switches to list view, and loses their search.

### NITPICK: Inline style in card_media thumbnail link
**File**: `documents_live.ex:1483`
**Problem**: `style="display:flex;justify-content:center;padding:8px 8px 8px 8px;background:oklch(var(--color-base-200));"` -- inline styles are harder to maintain and break the daisyUI convention used elsewhere.
**Suggestion**: Use Tailwind classes: `class="flex justify-center p-2 bg-base-200"`.

### NITPICK: `Enum.reject(&(&1 in [nil, false, ""]))` in card_class fn
**File**: `documents_live.ex:1466`
**Problem**: This filter-and-join pattern for conditional classes is verbose. Phoenix/LiveView has a built-in way to handle this.
**Suggestion**: Could use a simple list filter or the `class` attr with conditional entries, but this is functional and readable enough.

**Quality Summary:** 0 critical, 1 medium bug, 0 minor, 2 nitpick
**Quality Verdict: Ship** (after fixing the `q` param bug)

---

## Overall Verdict: PASS

The upstream merge is clean: old fork image functions are fully removed, upstream's canonical image engine is intact, the two fork-unique functions (`upload_image_for_embedding`, `set_anyone_reader_permission`) are correctly re-added with all dependencies present. The `<.table_default>` port is well-executed with correct view_mode mapping and slot usage. Compilation succeeds with zero errors.

**Fix before merge (priority order):**
1. **BUG-MEDIUM** `documents_live.ex:1913` -- add `"q" => assigns.filters["q"]` to `base_params` in `list_path_with_params/2` to preserve search across view/status switches.
