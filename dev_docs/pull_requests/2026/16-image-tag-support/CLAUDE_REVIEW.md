# PR #16 Review — Image tag support in document templates

**Author:** Tymofii Shapovalov (`timujinne`)
**Reviewer:** Dmitri + Claude (Opus 4.7)
**Merged:** 2026-05-11 (`8ba0803`)
**Range:** 27 commits, +4135/-70 across 22 files
**Spec/Plan:** `dev_docs/specs/2026-05-11-image-tag-support-design.md`,
`dev_docs/plans/2026-05-11-image-tag-support.md`

## TL;DR

Substantial, thoughtfully-built feature. The text/image fork of
`Variable.extract_variables/1` is the right shape (one detector per
syntactic family, single combined entry point for callers), the
two-pass substitution in `GoogleDocsClient.substitute_images/2`
(replaceAllText → documents.get → DeleteContentRange +
InsertInlineImage) is the only correct way to do this given the
batchUpdate API, and the descending-start_index ordering trick to
preserve indices across multiple inserts at the same position is
correct and well-tested. The UTF-16 awareness on `find_image_tag_ranges/2`
shows real care — the Cyrillic E2E test is the right belt-and-braces
guard. **No blocking findings.** What stood out worth a follow-up:

1. **[LOW] `VariableConfigForm` is dead code.** Not rendered by any
   LiveView or component — only by its own test module. The PR description
   says it "renders in CreateDocumentModal but `phx-change` persistence
   is not wired" — the first half is also untrue.
2. **[LOW] `separator_options/1` in `VariableConfigForm` emits raw HTML**
   built by string interpolation, then `Phoenix.HTML.raw/1`'s the result.
   Today's gettext labels are safe, but the pattern bypasses HEEx's
   automatic escaping — a translator who inserts `<` survives untouched
   to the DOM.
3. **[LOW] Two unused error atoms** (`:image_too_large`,
   `:missing_required_value`) declared in `@type` with `message/1`
   clauses and translations, but never emitted by any module.
4. **[LOW] `Jason` in `documents_live.ex`** for one encode + one decode
   on the media-picker round-trip — the rest of the codebase uses the
   built-in `JSON` module (Elixir 1.18+).
5. **[NIT] Synchronous Drive call in `do_modal_select_template`** —
   clicking a template card blocks the LV process on
   `Documents.detect_variables/1` (HTTP + DB UPDATE) before the modal
   advances. Typical Drive latency 0.5–2s.
6. **[NIT] Half-written Drive state on `substitute_images` failure** in
   `Documents.create_document_from_template/3` — the copied doc is
   orphaned until the next sync upserts it without `template_uuid` /
   `variable_values`.

Tests are thorough: image pipeline unit (120 lines), variable detector
(146), substitute_images orchestrator (403), media façade (76),
DocumentsLive image-picker round-trip (163 added), config form (84),
modal (84 added), plus an env-gated E2E that exercises the Cyrillic
UTF-16 path against real Google Drive. `mix test` / `format` /
`credo --strict` / `dialyzer` all clean per the PR checklist.

---

## 1. Findings

### 1.1 [LOW] `VariableConfigForm` is dead code

**Where:** `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex`

The component is referenced by exactly two callers:

```
$ grep -rn "VariableConfigForm\|config_form" lib/ test/
lib/.../variable_config_form.ex   # definition
test/.../variable_config_form_test.exs  # render_component/2 in tests
```

It is **not** rendered from `CreateDocumentModal`, `DocumentsLive`, or
any admin view. The PR description states:

> `VariableConfigForm` renders in `CreateDocumentModal` but
> `phx-change` persistence to `Template.variables` is not wired.

The "renders in `CreateDocumentModal`" half is incorrect — `CreateDocumentModal`
uses `render_image_picker/1` and `render_image_list_picker/1` (chooser
buttons), not `config_form/1`. The component currently provides no
user-facing value.

**Suggested resolution (pick one):**
- Delete the module + its test until the admin UI is ready to wire it
  (`build_definitions/1` populates the same `config` map, so nothing
  downstream depends on it).
- Wire it into the template admin view in this PR's follow-up so the
  test isn't a tautology.

Leaving it merged costs a maintenance hit: a future contributor reading
`grep config_form` will assume it's live and propagate the raw-HTML
pattern noted in §1.2 elsewhere.

### 1.2 [LOW] Raw HTML interpolation in `separator_options/1`

**Where:** `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex:83-97`

```elixir
defp separator_options(current) do
  options = [
    {"newline", gettext("New line")},
    {"space", gettext("Space")},
    {"none", gettext("None")}
  ]

  current_str = if current, do: to_string(current), else: "newline"

  Enum.map_join(options, fn {value, label} ->
    selected = if value == current_str, do: " selected", else: ""
    "<option value=\"#{value}\"#{selected}>#{label}</option>"
  end)
  |> Phoenix.HTML.raw()
end
```

The string literals are safe (`"newline"`, `"space"`, `"none"`), but
the `gettext("New line")` / `gettext("Space")` / `gettext("None")`
return values are concatenated unescaped into the HTML and then marked
safe with `Phoenix.HTML.raw/1`. A translator who introduces `<` or `&`
into a po file (intentionally or by typo) gets it injected raw.

This is a tiny attack surface — admin-only UI, translator workflow goes
through review, translations are project-controlled — but it bypasses
the precise reason HEEx exists. Worth fixing for hygiene.

**Suggested fix:** Render the `<option>` list directly in HEEx so the
`{label}` interpolation goes through automatic escaping:

```elixir
~H"""
<select name={"config[#{@variable.name}][separator]"} class="...">
  <%= for {value, label} <- separator_choices() do %>
    <option value={value} selected={value == current_str(@variable.config[:separator] || @variable.config["separator"])}>
      {label}
    </option>
  <% end %>
</select>
"""
```

Then `separator_choices/0` is a pure list of `{value, label}` tuples
with gettext-resolved labels, and `current_str/1` is the small helper.
No `Phoenix.HTML.raw` anywhere.

### 1.3 [LOW] Two error atoms declared, never emitted

**Where:** `lib/phoenix_kit_document_creator/errors.ex`

```
@type error_atom :: ... | :image_too_large | ... | :missing_required_value
def message(:image_too_large), do: gettext("Image exceeds 50 MB or 25 megapixels")
def message(:missing_required_value), do: gettext("A required variable was not filled")
```

Neither atom is returned from any function in `lib/`:

```
$ grep -rn "image_too_large\|missing_required_value" lib/
lib/phoenix_kit_document_creator/errors.ex:55:        | :image_too_large
lib/phoenix_kit_document_creator/errors.ex:58:        | :missing_required_value
lib/phoenix_kit_document_creator/errors.ex:99:  def message(:image_too_large), ...
lib/phoenix_kit_document_creator/errors.ex:102: def message(:missing_required_value), ...
```

The plan likely intended to enforce a 50 MB / 25 MP cap on the media
side and a `required: true` validator on the variable side, both of
which were deferred (the `required` field on `%Variable{}` defaults to
`false` and is never read). Either:

- Wire the validators (`Media.get_url_and_dimensions/1` can check
  `file.size`; the form-submit path can iterate `template_vars` looking
  for `required: true` and an empty value), or
- Drop both atoms from `@type` and `message/1` and re-add them when the
  validators land. Translations files keep the msgid until a
  `mix gettext.extract --no-fuzzy` sweep clears them.

Symptom of the gap: the gettext PO entries will be flagged "obsolete"
on the next extract.

### 1.4 [LOW] `Jason` in `DocumentsLive` only

**Where:** `lib/phoenix_kit_document_creator/web/documents_live.ex:437, 1511`

```elixir
existing_image_values = Jason.encode!(socket.assigns.modal_image_values)
...
case Jason.decode(json) do
```

These are the only `Jason.*` calls in `lib/` — everything else uses the
built-in `JSON` module (Elixir 1.18+, per the user's global
preferences). Easy switch:

```elixir
existing_image_values = JSON.encode!(socket.assigns.modal_image_values)
...
case JSON.decode(json) do
  {:ok, map} when is_map(map) -> ...
  _ -> %{}
end
```

`JSON.decode/1` returns the same `{:ok, term} | {:error, term}` shape,
so the case pattern is unchanged. Removes a residual implicit dep on
`Jason` for this module.

### 1.5 [NIT] Synchronous Drive call in `do_modal_select_template`

**Where:** `lib/phoenix_kit_document_creator/web/documents_live.ex:661-684`

```elixir
defp do_modal_select_template(socket, file_id, name) do
  variables =
    case Documents.detect_variables(file_id) do
      {:ok, fork} ->
        PhoenixKitDocumentCreator.Variable.build_definitions(fork)
        |> Enum.map(&Map.from_struct/1)

      _ -> []
    end
  ...
```

`Documents.detect_variables/1` calls `GoogleDocsClient.get_document_text/1`
(a Drive HTTP roundtrip) and then `repo().update_all` to cache the
detected variables. Both happen synchronously inside the LV's
`handle_event("modal_select_template", ...)` — the LV process is
blocked for the duration. Typical Drive latency is 300ms–2s; a slow
network bumps that to 5s+.

**Why it slips through tests:** the LV test injects a stub via
`docs_client` config; the stub returns immediately.

**Suggested fix:** Move the detect into `start_async`:

```elixir
def handle_event("modal_select_template", %{"id" => file_id, "name" => name}, socket) do
  with :ok <- verify_known_file(socket, file_id) do
    {:noreply,
     socket
     |> assign(
       modal_step: "variables",
       modal_selected_template: %{"id" => file_id, "name" => name},
       modal_variables: :loading
     )
     |> start_async({:detect_vars, file_id}, fn ->
       Documents.detect_variables(file_id)
     end)}
  end
end

def handle_async({:detect_vars, file_id}, {:ok, {:ok, fork}}, socket) do
  variables = Variable.build_definitions(fork) |> Enum.map(&Map.from_struct/1)
  if variables == [], do: create_from_template_directly(socket, file_id, ...), else: ...
end
```

The variables-step body already renders a per-input `disabled={@creating}`
indicator — extending it to handle `modal_variables: :loading` is small.

### 1.6 [NIT] Half-written Drive state on substitute_images failure

**Where:** `lib/phoenix_kit_document_creator/documents.ex:701-724`

```elixir
def create_document_from_template(template_file_id, variable_values, opts \\ []) do
  ...
  with {:ok, target} <- resolve_create_target(opts),
       {:ok, template_vars} <- load_template_vars(template_file_id),
       {:ok, image_fills} <- resolve_image_fills(template_vars, image_value_specs),
       {:ok, new_doc_id} <- client.copy_file(template_file_id, doc_name, parent: target.folder_id),
       {:ok, _} <- client.replace_all_text(new_doc_id, text_values),
       {:ok, _} <- client.substitute_images(new_doc_id, image_fills) do
    persist_created_document(new_doc_id, ...)
  end
end
```

If `substitute_images/2` fails (Drive API hiccup, invalid image URI,
permission glitch on inline image insert), the user sees `{:error, _}`
but a copied-and-text-substituted Drive doc remains in the documents
folder. Next `sync_from_drive/0` walks it up and upserts it as a
plain document — without `template_uuid` or `variable_values`.

**Why it's not catastrophic:** the doc is in the user's managed folder
and visible; they can re-open it, finish the substitution manually, or
delete it. The activity feed shows the failed creation attempt (via
`with` failure → no `log_activity` row → no audit trail of the half-doc).

**Suggested fix:** On image-substitution failure specifically, trash
the copy via `move_file(new_doc_id, deleted_documents_folder_id)` before
returning the error — best-effort, swallow any move failure into a
warning. Or document the orphan behaviour at the function head so
callers know to expect it.

### 1.7 [NIT] Duplicated image-tag regex

**Where:** `lib/phoenix_kit_document_creator/variable.ex:24`
+ `lib/phoenix_kit_document_creator/google_docs_client.ex:741`

```elixir
# Variable
@image_var_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

# GoogleDocsClient
@image_tag_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/
```

The PR description marks this as deliberate ("each module owns its
parsing"). Defensible. Worth noting that the moment someone wants
case-insensitive matching, or to accept `{{image:foo}}` without spaces,
two places must change in lockstep — and forgetting one is a silent
detector vs. substituter mismatch (variable detected, tag never
substituted, literal `{{ image: foo }}` ships in the generated doc).

**Suggested fix (optional):** Move the canonical regex to `Variable`
and expose it as a public 0-arity function (`Variable.image_tag_regex/0`)
that `GoogleDocsClient` calls. Single source of truth, same module
ownership of detection.

### 1.8 [NIT] `extract_image_variables` silently picks first on name collision

**Where:** `lib/phoenix_kit_document_creator/variable.ex:55-63`

```elixir
def extract_image_variables(text) when is_binary(text) do
  @image_var_regex
  |> Regex.scan(text)
  |> Enum.map(fn [_full, keyword, name] -> %{name: name, kind: keyword_to_kind(keyword)} end)
  |> Enum.uniq_by(& &1.name)
  |> Enum.sort_by(& &1.name)
end
```

If a template author writes both `{{ image: logo }}` (single) and
`{{ images: logo }}` (list) with the same name, `Enum.uniq_by/2` keeps
the first-by-document-order and silently drops the kind of the second.
The doc-comment notes this as a feature, but at substitution time the
second tag is **still parsed** by `find_image_tag_ranges/2` and gets
deleted with no image inserted (the `fills` map only has the first
kind's spec). Result: one of the tags renders as empty.

**Suggested fix:** Have `extract_image_variables/1` return
`{:error, {:ambiguous, name}}` on collision, surface a clearer "your
template uses both `{{ image: X }}` and `{{ images: X }}` for the same
name X" UI error. Documentation alone won't catch this; Google Doc
authors don't read module docs.

### 1.9 Accepted: UTF-16 supplementary-plane codepoints

The PR documents that surrogate pairs (most emoji, rare CJK)
miscalculate by one UTF-16 code unit per supplementary codepoint. The
shape of the proper fix is small:

```elixir
defp utf16_units(binary) do
  binary
  |> :unicode.characters_to_binary(:utf8, :utf16)
  |> byte_size()
  |> div(2)
end
```

Replace `String.length/1` in `match_to_range/4` with `utf16_units/1`,
and the supplementary case is correct. ~10 lines. Worth tracking; not
blocking.

---

## 2. Notes on the well-done bits

These are worth calling out so they don't get refactored into
something worse later.

- **Two-pass design** (`replaceAllText` → `documents.get` + per-tag
  insert) is the only correct way given the batchUpdate API. A
  one-pass attempt with `replaceAllText` matching `{{ image: foo }}`
  would not be able to attach `insertInlineImage` — Google's
  `replaceAllText` only replaces with text.

- **Descending-start_index iteration** in `build_image_batch_requests/2`
  is the correct trick. Each delete shrinks the doc by `(e - s)` units;
  processing right-to-left means earlier indices stay valid throughout
  the whole batch. The test that mixes 3 tags at indices 50/120/300 is
  the right belt for that braces.

- **HTTPS-only + 2KB URI guard** in `Media.build_url_result/2` —
  defends against accidentally pushing a `data:` URL into Google's
  inline image insert (which would silently get stored and bloat the
  doc) and caps URL length below sensible limits.

- **Round-trip state preservation** for the media picker
  (`open_media_picker` → encode template + accumulated picks in URL →
  `apply_media_selection` decodes and restores) is the right pattern
  for a navigation that leaves and returns. The `5e40c3a` validation
  of `picking_existing` JSON shape and mode atom plugged the obvious
  injection vector.

- **`Documents.detect_variables/1` returns the forked map, not the
  flat list.** Callers can branch on `fork.text` vs `fork.image`
  without re-parsing. Cleaner than a `[%Variable{type: :image, ...}]`
  list where every consumer pattern-matches on `:type`.

- **Test pyramid is genuine**: unit on the pure parsers, oracles on
  the request-builder shapes, mocked-orchestrator tests on the
  combine layer, env-gated E2E for the things only real Google Docs
  can verify (UTF-16, inline image insertion).

---

## 3. Suggested follow-ups

| ID  | Priority | Fix                                                                                       |
| --- | -------- | ----------------------------------------------------------------------------------------- |
| 1.1 | LOW      | Decide: wire `VariableConfigForm` into the admin UI, or delete the component + its test.  |
| 1.2 | LOW      | Replace `separator_options/1`'s raw HTML with a HEEx `<%= for %>` loop.                   |
| 1.3 | LOW      | Either wire `:image_too_large` / `:missing_required_value` validators, or remove them.    |
| 1.4 | LOW      | Switch `Jason.encode!` / `Jason.decode` to built-in `JSON` in `documents_live.ex`.        |
| 1.5 | NIT      | Move synchronous `Documents.detect_variables/1` into `start_async`.                       |
| 1.6 | NIT      | Best-effort trash the copied Drive doc when image substitution fails.                     |
| 1.7 | NIT      | Single canonical image-tag regex shared between `Variable` and `GoogleDocsClient`.        |
| 1.8 | NIT      | Surface `{:error, :ambiguous_image_var, name}` on `{{ image: X }}` + `{{ images: X }}`.   |
| 1.9 | NIT      | Use `:unicode.characters_to_binary(_, :utf8, :utf16)` byte-size in `match_to_range/4`.    |

---

## 4. Related

- Spec: `dev_docs/specs/2026-05-11-image-tag-support-design.md`
- Plan: `dev_docs/plans/2026-05-11-image-tag-support.md`
- Previous PR: [#14](/dev_docs/pull_requests/2026/14-per-template-locale-picker/)
- Cleanup commits already landed on `main`:
  - `0c4e73f` — square fallback for missing source dimensions
  - `5e40c3a` — validate `picking_existing` JSON shape and mode atom
  - `0a5e329` — non-binary id returns `:image_not_found`
  - `baae133` — remove unreachable `apply_image_selection/4 []` clause
  - `e09caab` — note same-name image/images ambiguity
