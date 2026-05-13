# PR #17 Review — Document Composition

**PR:** [#17 — Document composition: multi-section docs, recipes, presets, image picker](https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/17)
**Author:** @timujinne
**State:** MERGED
**Size:** +2 780 / −34 across 30 files, 26 commits
**Reviewer:** Claude (Opus 4.7) — Elixir/Phoenix/Ecto skills loaded

---

## 1. Summary

Implements Tasks 1–8 of the document composition design: multi-template composed
documents (per-document recipe snapshots), named scoped presets, an `ImagePicker`
LiveComponent, and per-section variable substitution. Adds a `category` column on
templates with an admin UI picker. Ships three new migrations (V117), nine new
modules, and ~1 000 LoC of tests.

The branch self-corrected several real bugs mid-review (EMU vs PT image unit,
last-write-wins merge order, range-scoped substitution, mount-twice
double-querying, `PhoenixKit.Supervisor` already-started, `assign/3` crash on raw
map, broken `createPositionedObject` request). The final tree is much healthier
than any intermediate commit and the test suite now actually boots — the earlier
"tests pass" claims were unverified until commit `b65bbde`.

---

## 2. What's good

- **`Composer` is a clean Ecto.Multi pipeline.** Cross-step data dependencies
  (`%{google_doc: gdoc_id}`, `%{appended: ...}`, `%{document: doc}`) genuinely
  need `Multi` rather than `Repo.transact/1`. The rollback handler at
  `composer.ex:161` matches on `%{google_doc: gdoc_id}` to fire a best-effort
  `delete_document` — and the comment above it explicitly warns future editors
  not to reorder the `:google_doc` step. Good hazard-awareness.
- **`mount/3` follows the LiveView Iron Law.** `documents_live.ex:34-37` gates DB
  work behind `connected?(socket)` and defers it to `:load_initial` so disconnected
  mount stays a no-op shell. The comment explicitly calls out the
  "subscribe-before-read" ordering so a `:files_changed` broadcast between read
  and subscribe is not lost. Textbook.
- **Docs-client injection via `Application.get_env/3`** with `GoogleDocsClient` as
  default is the right shape for swap-in `StubDocsClient` in tests — no Mox
  ceremony, no global state, async-safe.
- **Range-scoped substitution** (`substitute_in_range/5`, commit `b587474`) is
  implemented correctly: reverse-index `deleteContentRange` + `insertText` in a
  single `batchUpdate` so per-section identical keys (`{{name}}`) resolve
  independently. Self-corrected from an earlier whole-doc pass that would have
  silently dropped section-1+ values.
- **`coerce_config/1`** drops empty-string number inputs (`""` → `:skip`) instead
  of `String.to_integer/1`-raising on `phx-change`. Combined with the 500 ms
  debounce, this neutralizes a class of LiveView crashes on partially-filled
  numeric inputs.
- **Test scaffolding** (`StubDocsClient`, `LiveCase.render_live/2`,
  `ComponentHostLive`) is clean and reusable for future LiveComponent work.

---

## 3. Issues

### 3.1 ~~🔴 Likely bug: `apply_preset/1` may silently drop every section~~ — RETRACTED

**Original concern:** that `Map.get(s, "template_uuid")` (a hex string from
JSONB) compared against the contents of a `MapSet` built from
`select [t], t.uuid` would mismatch because the latter returned raw binaries.

**Why it's wrong:** `UUIDv7` (`deps/uuidv7/lib/uuidv7.ex:54`) delegates `load/1`
to `Ecto.UUID.load/1`, which decodes the raw 16-byte storage form back to the
hex-encoded string. So both sides of the `MapSet.member?/2` comparison are hex
strings and the lookup works. There is also a happy-path test
(`recipe_and_presets_test.exs:135`) that inserts a Template, persists a Preset
with `live.uuid` as the section `template_uuid`, and asserts the returned
section list contains the kept UUID — which it would not if the comparison
silently dropped everything.

Apologies for the false alarm.

### 3.2 🟠 PubSub topic is unscoped (Phoenix red flag for multi-tenant hosts)

`documents.ex:36` — `@pubsub_topic "document_creator:files"`. From the Phoenix
skill: *Unscoped topics = data leaks between tenants.* If a host app embeds this
library inside a multi-tenant deployment, an admin in tenant A causing a
template mutation will broadcast `:files_changed` to every admin LiveView,
including those in tenant B, triggering cross-tenant DB reads. The DB reads
themselves are filtered by `status`/`google_doc_id`, not by tenant — so this
isn't a *data leak* per se, but it is a needless fan-out.

Suggest accepting a `scope` arg (à la Phoenix 1.8+ scopes) and namespacing the
topic: `"document_creator:files:#{scope.org_id}"`. Acceptable to defer if the
library only ships into single-tenant hosts today, but worth a TODO.

### 3.3 🟠 `image_params.opacity` and `image_params.z_index` are stored but no-op

Confirmed both in moduledoc (`document_section.ex:16-18`) and the latest commit
(`4e8450f`): `createPositionedObject` is not a valid `batchUpdate` request type,
and `EmbeddedObject` has no opacity surface. The code now warns and falls back
to `insertInlineImage` — correct defensive shape — but operators can still pick
values in the UI that will silently never apply.

Options:
1. **Remove** the columns/fields until the Google Docs API supports them (a
   two-pass `batchUpdate` is mentioned in the docstring but not on any
   roadmap). Costs a migration.
2. **Grey out** the input controls in the picker so users don't waste time
   tweaking values that won't render.
3. **Keep, document loudly.** Today's state. Acceptable short-term but the
   moduledoc note is invisible to operators.

Prefer (2) for now and (1) once it's clear the API won't change.

### 3.4 🟠 `Composer.compose/2` raises on unsupported separator

`composer.ex:77-80` raises `ArgumentError` for any `separator` value other than
`:page_break`. The rest of the module returns tagged tuples, and the public
context entry point `Documents.create_composed_document/2` is typed
`{:ok, Document.t()} | {:error, term()}`. A raised `ArgumentError` crashes the
caller LV. Prefer `{:error, {:unsupported_separator, sep}}` so callers get one
uniform error surface.

### 3.5 🟡 `update_template_variable_config/3` silently no-ops on unknown variable

`documents.ex:143-167`. If `var_name` doesn't match any variable in the
template's `variables` JSONB, the `Enum.map` returns the list unchanged and the
function returns `{:ok, template}`. The caller can't distinguish "I updated
config X" from "I tried to update config X but there's no variable with that
name." Same goes for `update_template_variable_config` being called *while* a
template's variables are being re-detected — race. Either narrow the return to
`{:error, :variable_not_found}` or document the silent-pass behaviour.

### 3.6 🟡 `create_composed_document/2` doesn't broadcast `:files_changed`

Every other create / mutate path in `Documents` ends with
`broadcast_files_changed/0` so connected admin LVs resync. Composed documents
inserted via `Composer` do not — the `Multi` chain ends at
`Multi.insert(:document, ...) → Multi.run(:sections, ...)` without a broadcast
hook. Connected admins will see the new document only on their next manual
reload or on the next periodic sync.

Easy fix: broadcast in `create_composed_document/2` after the Multi commits.

### 3.7 🟡 `config/config.exs` test-gating papers over a latent dev/prod bug

`config.exs:46-66` now guards the Oban block with `config_env() != :test`. This
unblocks the test suite (good), but the standalone dev/prod config still
references a non-existent `PhoenixKitDocumentCreator.Repo` module. The commit
message explicitly admits this is "still-broken-by-design." Since this library
is meant to be consumed by host apps that supply their own Oban config, the
dev/prod block is dead weight. Drop it, or stub out a real
`PhoenixKitDocumentCreator.Repo` for standalone usage.

### 3.8 🟡 `validate_sections/2` derives `published` boolean from `status == "published"`

`composer.ex:88-89`. Anything that isn't exactly `"published"` (e.g. `"lost"`,
`"unfiled"`) is treated as unpublished. That's probably the intended business
rule — composing from a lost-or-unfiled template would be a bad idea — but the
error surface returns `:unpublished_templates`, which is misleading when the
real cause is `"lost"`. Either narrow the message or treat
`"published" | "lost" | "unfiled"` as composable.

### 3.9 🟢 Minor: `Map.get/2` defaults in `apply_preset/1` swallow `position: nil`

`documents.ex:2074` — `Enum.sort_by(&Map.get(&1, "position"))`. If a section is
missing `"position"`, `Map.get/2` returns `nil` and `Enum.sort_by/2` will raise
`Protocol.UndefinedError` on mixed-nil comparison. Defensive: `Map.get(&1,
"position", 0)`. Probably never happens with controlled inputs, but presets are
persisted JSONB and survive code changes.

### 3.10 🟢 Minor: `ImagePicker` has no "deselect" path

`image_picker.ex:74-83`. The `pick` event uniquely appends to selection in
`:list` mode but offers no way to remove. The contract says the host "echoes
back" selection, so the host can drop a uuid from `:current_selection` and the
component will reflect it — but operators clicking the same thumbnail twice will
expect a toggle. Either document the no-toggle contract loudly in the moduledoc
or implement toggle internally.

---

## 4. Schema / migration sanity

`DocumentSection` uses `belongs_to` with `foreign_key: :document_uuid` /
`:template_uuid` and `references: :uuid`, matching the project convention from
`Document`/`Template`. Unique index on `(document_uuid, position)` enforced both
at the DB layer and via `unique_constraint/3`. `foreign_key_constraint/2` on
both FKs.

Confirmed against the Ecto skill's red-flag list:

- ✅ No belongs_to crossing context boundaries (single Documents context).
- ✅ `creation_changeset` / `changeset` / `sync_changeset` split per use case.
- ✅ Preload usage absent here — composed docs read via `has_many :sections`
  but with no eager join (good, since sections-per-doc could be many).
- ✅ Multi-tenancy: not implemented (see 3.2).
- ✅ Sandbox/Cachex: not applicable.

`TemplatePreset` stores `sections` as `{:array, :map}` — fine for JSONB
serialisation, but be aware: there is **no schema for the inner section
descriptor**, so a typo in any key (`"templat_uuid"`) flows through without
validation and surfaces as the silent-drop in 3.1. Consider an embedded schema
for preset sections.

---

## 5. LiveView correctness

The category picker crash on render (commit `2ce52b4`) is fixed correctly:
`render_category_picker/1` no longer calls `assign/3` on a hand-built assigns
map; it inlines `category_options()` exactly the way `render_language_picker`
above it does. Pattern matches the established convention.

The mount/handle_params split in `documents_live.ex` is correct (3.0 above).
The earlier `mount` ran DB reads twice; the `if connected?(socket)` gate plus
`send(self(), :load_initial)` is the canonical fix.

`ImagePicker` is a LiveComponent and correctly `send`s back to `self()`, which
is the parent LV pid — standard pattern. The `assign_new` for
`:current_selection` documented in the moduledoc is a sharp edge worth keeping
the explanation around.

---

## 6. Test coverage assessment

- ✅ `composer_test.exs` — validation unit tests (5a).
- ✅ `composed_document_test.exs` — happy-path + rollback integration tests
  (via `StubDocsClient`).
- ✅ `recipe_and_presets_test.exs` — covers `recipe_for`, `save_preset`,
  `list_presets`.
- ⚠️ **`apply_preset/1` happy path is not exercised end-to-end with a real
  inserted Template.** This is precisely the path that 3.1 says will silently
  drop everything. A test that inserts a Template, persists a Preset referencing
  its UUID as a *string* (matching JSONB round-trip), then calls
  `apply_preset/1` and asserts `{:ok, [_section]}` would catch it.
- ✅ `image_picker_test.exs` — covers filter, pagination, selection.
- ✅ `image_substitution_test.exs` — adjusted for inline fallback after the
  `createPositionedObject` removal.

---

## 7. Recommended follow-ups (in priority order)

**Applied in this branch:**

- ✅ **§3.4** `Composer.compose/2` now returns `{:error, {:unsupported_separator, sep}}`
  instead of raising `ArgumentError` — uniform tagged-tuple contract.
- ✅ **§3.6** `Documents.create_composed_document/2` now calls
  `broadcast_files_changed/0` on success — connected admin LiveViews resync.

**Still open (need design input):**

1. **Decide what to do with `opacity` / `z_index`** — UI grey-out or schema
   drop. (§3.3)
2. **Drop or repair the standalone dev/prod Oban config** in `config.exs`.
   (§3.7)
3. **Scope the PubSub topic** if the library will ship into multi-tenant
   hosts. (§3.2)
4. **Embed a schema for `TemplatePreset.sections` entries** so typo'd keys
   fail loudly at save time, not silently at apply time. (§4)
5. **Tighten `update_template_variable_config/3` return shape** for unknown
   variable names. (§3.5)
6. **Implement orphan-doc sweeper** (the existing `TODO(orphan-doc-sweeper)`
   in `composer.ex:9`) — once the Multi rolls back after `:google_doc`
   succeeds, only `Logger.warning` records the orphan. A periodic Oban sweep
   over `phoenix_kit_doc_documents` ∪ Drive would close the loop.

---

## 8. Overall

Approve in spirit — the merged result is solid and the self-corrections during
the PR show good engineering discipline. The `apply_preset/1` type-mismatch
(§3.1) is the one issue that warrants a quick follow-up PR before any UI starts
using presets in earnest; the others are smaller polish items.
