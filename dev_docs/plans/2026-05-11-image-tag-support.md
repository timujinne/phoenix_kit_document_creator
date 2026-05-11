# Image Tag Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `{{ image: name }}` and `{{ images: name }}` placeholders to Document Creator templates: detect them, let admins pick media via PhoenixKit `MediaBrowser`, and substitute them into generated Google Docs via a second `batchUpdate` pass.

**Architecture:** Two-pass substitution — text first via existing `replaceAllText`, images second via `documents.get` + custom `DeleteContentRange` + `InsertInlineImage` batch. Variable detection forks into `extract_string_variables/1` and `extract_image_variables/1` with the text regex explicitly excluding image tags via negative lookahead. Per-variable config (default width, separator, max_count) lives in the existing `variables` jsonb column; filled image values are stored as media IDs.

**Tech Stack:** Elixir, Phoenix LiveView 1.x, Ecto, Req (HTTP), Google Docs + Drive v1/v3 APIs, PhoenixKit `MediaBrowser` LiveComponent.

**Spec:** `dev_docs/specs/2026-05-11-image-tag-support-design.md`.

---

## Conventions for all tasks

- All steps run from `/www/phoenix_kit_document_creator` unless noted.
- After every code change you must be able to run `mix test path/to/file.exs` and `mix format` cleanly.
- Quality gate before any commit: `mix format && mix credo --strict` (full `mix quality` runs Dialyzer — slow — leave it for milestone commits noted in the plan).
- Commits stay on branch `feat/image-tag-support`. The spec is already committed there (`010a023`).
- TDD: write the failing test, see it fail, write the minimum code to pass, see it pass, commit.

---

## File map

| File | Type | Responsibility |
|---|---|---|
| `lib/phoenix_kit_document_creator/variable.ex` | Modify | Add `:image` / `:image_list` types, `config` field, split detection regexes |
| `lib/phoenix_kit_document_creator/errors.ex` | Modify | Add 5 new error atoms + gettext clauses |
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | Modify | Add `find_image_tag_ranges/2` and `substitute_images/2`; existing `replace_all_text/2` unchanged |
| `lib/phoenix_kit_document_creator/documents.ex` | Modify | Refactor `detect_variables/1` to return forked map; add image-pass to `create_document_from_template/3`; add `resolve_image_media/1` helper |
| `lib/phoenix_kit_document_creator/media.ex` | Create | Thin façade over PhoenixKit Media: `get_url_and_dimensions/1` returning `{url, width_px, height_px}` |
| `lib/phoenix_kit_document_creator/web/components/create_document_modal.ex` | Modify | Render image-picker buttons for `:image` / `:image_list` variables, integrate `MediaBrowser` selector |
| `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex` | Create | Small form component for editing per-variable `config` (default width, separator, max_count) |
| `test/phoenix_kit_document_creator/variable_test.exs` | Modify | New cases for split regexes + negative-lookahead invariant |
| `test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs` | Create | Unit tests for tag-range finder and batch builder with fixture document JSON |
| `test/phoenix_kit_document_creator/documents/image_pipeline_test.exs` | Create | Integration of the two-pass orchestration with Drive client stubbed |
| `test/phoenix_kit_document_creator/errors_test.exs` | Modify | New atoms render via `Errors.message/1` |

---

## Task 1 — Add `config` field to `Variable` struct, no semantic change

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex:11-20`
- Test: `test/phoenix_kit_document_creator/variable_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/phoenix_kit_document_creator/variable_test.exs`:

```elixir
describe "struct shape" do
  test "variable has a config map, defaulting to empty" do
    v = %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: :text}
    assert v.config == %{}
  end
end
```

- [ ] **Step 2: Run test, expect fail**

`mix test test/phoenix_kit_document_creator/variable_test.exs --only describe:"struct shape"` should fail with "key :config not found".

- [ ] **Step 3: Add the field**

In `variable.ex` change the type and struct:

```elixir
@type t :: %__MODULE__{
        name: String.t(),
        label: String.t(),
        type: variable_type(),
        default: String.t() | nil,
        required: boolean(),
        config: map()
      }

@enforce_keys [:name, :label, :type]
defstruct [:name, :label, :type, default: nil, required: false, config: %{}]
```

- [ ] **Step 4: Run test, expect pass**

`mix test test/phoenix_kit_document_creator/variable_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "feat(variable): add config field to Variable struct"
```

---

## Task 2 — Add `:image` and `:image_list` to `variable_type`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex:9`

- [ ] **Step 1: Write the failing test**

Append to the "struct shape" describe block:

```elixir
test "image and image_list are valid types" do
  for t <- [:image, :image_list] do
    assert %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: t}.type == t
  end
end
```

This currently passes at runtime (structs don't enforce types), but Dialyzer will complain. We use the test as a regression marker.

- [ ] **Step 2: Update the type spec**

```elixir
@type variable_type :: :text | :date | :currency | :multiline | :image | :image_list
```

- [ ] **Step 3: Verify**

`mix test test/phoenix_kit_document_creator/variable_test.exs` — green.

- [ ] **Step 4: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "feat(variable): add :image and :image_list to variable_type"
```

---

## Task 3 — Split string-variable detection into its own function with negative-lookahead

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex:28-36`
- Test: `test/phoenix_kit_document_creator/variable_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
describe "extract_string_variables/1" do
  test "extracts plain text variables" do
    text = "Hello {{ name }} and {{ company }}"
    assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) ==
             ["company", "name"]
  end

  test "deliberately ignores {{ image: x }} tokens" do
    text = "Logo: {{ image: logo }} and name {{ name }}"
    assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
  end

  test "deliberately ignores {{ images: x }} tokens" do
    text = "Gallery: {{ images: photos }} and name {{ name }}"
    assert PhoenixKitDocumentCreator.Variable.extract_string_variables(text) == ["name"]
  end

  test "returns [] for non-binary input" do
    assert PhoenixKitDocumentCreator.Variable.extract_string_variables(:atom) == []
  end
end
```

- [ ] **Step 2: Run, expect compile / fail**

`mix test test/phoenix_kit_document_creator/variable_test.exs --only describe:"extract_string_variables/1"` should fail with `undefined function extract_string_variables/1`.

- [ ] **Step 3: Add the function**

In `variable.ex`:

```elixir
@string_var_regex ~r/\{\{\s*(?!images?\s*:)(\w+)\s*\}\}/

@doc """
Extracts text variable names from `{{ name }}` placeholders.

Deliberately ignores `{{ image: name }}` and `{{ images: name }}` via a negative
lookahead — those are handled by `extract_image_variables/1`.

Returns a sorted list of unique names.
"""
@spec extract_string_variables(term()) :: [String.t()]
def extract_string_variables(text) when is_binary(text) do
  @string_var_regex
  |> Regex.scan(text)
  |> Enum.map(fn [_full, name] -> name end)
  |> Enum.uniq()
  |> Enum.sort()
end

def extract_string_variables(_), do: []
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/variable_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "feat(variable): add extract_string_variables with image-tag exclusion"
```

---

## Task 4 — Add `extract_image_variables/1`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex`
- Test: `test/phoenix_kit_document_creator/variable_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
describe "extract_image_variables/1" do
  test "captures single-image and list-image tags" do
    text = """
    Logo: {{ image: logo }}
    Photos: {{ images: photos }}
    Plain: {{ name }}
    Duplicate: {{ image: logo }}
    """

    assert PhoenixKitDocumentCreator.Variable.extract_image_variables(text) == [
             %{name: "logo", kind: :image},
             %{name: "photos", kind: :image_list}
           ]
  end

  test "tolerates whitespace variations" do
    text = "{{image:a}} {{  images :  b  }}"
    assert PhoenixKitDocumentCreator.Variable.extract_image_variables(text) == [
             %{name: "a", kind: :image},
             %{name: "b", kind: :image_list}
           ]
  end

  test "returns [] for non-binary input" do
    assert PhoenixKitDocumentCreator.Variable.extract_image_variables(nil) == []
  end
end
```

- [ ] **Step 2: Run, expect fail**

Same command as Task 3 with the new describe block.

- [ ] **Step 3: Implement**

In `variable.ex`:

```elixir
@image_var_regex ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

@doc """
Extracts image variable definitions from `{{ image: name }}` /
`{{ images: name }}` placeholders.

Returns a list of `%{name: String.t(), kind: :image | :image_list}` maps,
deduplicated by name, sorted by name.
"""
@spec extract_image_variables(term()) :: [%{name: String.t(), kind: :image | :image_list}]
def extract_image_variables(text) when is_binary(text) do
  @image_var_regex
  |> Regex.scan(text)
  |> Enum.map(fn [_full, keyword, name] ->
    %{name: name, kind: keyword_to_kind(keyword)}
  end)
  |> Enum.uniq_by(& &1.name)
  |> Enum.sort_by(& &1.name)
end

def extract_image_variables(_), do: []

defp keyword_to_kind("image"), do: :image
defp keyword_to_kind("images"), do: :image_list
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/variable_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "feat(variable): add extract_image_variables"
```

---

## Task 5 — Refactor `extract_variables/1` to return forked `%{text:, image:}`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex:27-36`
- Test: `test/phoenix_kit_document_creator/variable_test.exs`

This is the **breaking-change task** for `Variable.extract_variables/1`. Internal callers (`Documents.detect_variables/1`) are updated in Task 11. Between Task 5 and Task 11 the module compiles but `Documents.detect_variables/1` is broken — that's acceptable for a feature branch as long as you don't push between tasks.

- [ ] **Step 1: Write the failing test**

Replace the existing `describe "extract_variables/1"` block with:

```elixir
describe "extract_variables/1 (fork)" do
  test "returns string and image variables separately" do
    text = """
    {{ client_name }} {{ image: logo }} {{ name }} {{ images: photos }}
    """

    assert PhoenixKitDocumentCreator.Variable.extract_variables(text) == %{
             text: ["client_name", "name"],
             image: [
               %{name: "logo", kind: :image},
               %{name: "photos", kind: :image_list}
             ]
           }
  end

  test "returns empty fork for empty text" do
    assert PhoenixKitDocumentCreator.Variable.extract_variables("") ==
             %{text: [], image: []}
  end

  test "returns empty fork for non-binary" do
    assert PhoenixKitDocumentCreator.Variable.extract_variables(nil) ==
             %{text: [], image: []}
  end
end
```

- [ ] **Step 2: Run, expect fail**

The old `extract_variables/1` returns a flat list, so tests fail with a shape mismatch.

- [ ] **Step 3: Rewrite the function**

In `variable.ex` replace the old `extract_variables/1` with:

```elixir
@doc """
Convenience entry point that runs both detectors and returns a forked map.

Returns `%{text: [String.t()], image: [%{name, kind}]}`.
"""
@spec extract_variables(term()) :: %{
        text: [String.t()],
        image: [%{name: String.t(), kind: :image | :image_list}]
      }
def extract_variables(text) do
  %{
    text: extract_string_variables(text),
    image: extract_image_variables(text)
  }
end
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/variable_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "refactor(variable): fork extract_variables into text and image branches"
```

---

## Task 6 — Update `build_definitions/1` for image variables

**Files:**
- Modify: `lib/phoenix_kit_document_creator/variable.ex:41-52`
- Test: `test/phoenix_kit_document_creator/variable_test.exs`

`build_definitions/1` currently takes `[String.t()]`. It must now take the forked map and emit a flat list of `Variable.t()` structs covering both branches, with image variables carrying default `config`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "build_definitions/1" do
  test "builds text variables with empty config" do
    fork = %{text: ["client_name"], image: []}

    assert [
             %PhoenixKitDocumentCreator.Variable{
               name: "client_name",
               type: :text,
               config: %{}
             }
           ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
  end

  test "builds image variable with default config" do
    fork = %{text: [], image: [%{name: "logo", kind: :image}]}

    assert [
             %PhoenixKitDocumentCreator.Variable{
               name: "logo",
               label: "Logo",
               type: :image,
               config: %{default_width_px: 400}
             }
           ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
  end

  test "builds image_list variable with default config" do
    fork = %{text: [], image: [%{name: "photos", kind: :image_list}]}

    assert [
             %PhoenixKitDocumentCreator.Variable{
               name: "photos",
               type: :image_list,
               config: %{default_width_px: 400, separator: :newline, max_count: nil}
             }
           ] = PhoenixKitDocumentCreator.Variable.build_definitions(fork)
  end

  test "preserves order: text first (alpha), then image (alpha)" do
    fork = %{
      text: ["b_text", "a_text"],
      image: [
        %{name: "b_img", kind: :image},
        %{name: "a_img", kind: :image_list}
      ]
    }

    names = PhoenixKitDocumentCreator.Variable.build_definitions(fork) |> Enum.map(& &1.name)
    assert names == ["a_text", "b_text", "a_img", "b_img"]
  end
end
```

- [ ] **Step 2: Run, expect fail**

Old `build_definitions/1` accepts `[String.t()]`.

- [ ] **Step 3: Rewrite**

In `variable.ex`:

```elixir
@doc """
Builds Variable structs from a forked detection map. Text variables come first
(sorted), then image variables (sorted by name).
"""
@spec build_definitions(%{
        text: [String.t()],
        image: [%{name: String.t(), kind: :image | :image_list}]
      }) :: [t()]
def build_definitions(%{text: text_names, image: image_defs}) do
  text_vars =
    text_names
    |> Enum.sort()
    |> Enum.map(fn name ->
      %__MODULE__{
        name: name,
        label: humanize(name),
        type: guess_type(name),
        required: false,
        default: nil,
        config: %{}
      }
    end)

  image_vars =
    image_defs
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn %{name: name, kind: kind} ->
      %__MODULE__{
        name: name,
        label: humanize(name),
        type: kind,
        required: false,
        default: nil,
        config: default_image_config(kind)
      }
    end)

  text_vars ++ image_vars
end

defp default_image_config(:image), do: %{default_width_px: 400}

defp default_image_config(:image_list),
  do: %{default_width_px: 400, separator: :newline, max_count: nil}
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/variable_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/variable.ex test/phoenix_kit_document_creator/variable_test.exs
git commit -m "refactor(variable): build_definitions takes forked map, emits image config"
```

---

## Task 7 — Add error atoms

**Files:**
- Modify: `lib/phoenix_kit_document_creator/errors.ex`
- Test: `test/phoenix_kit_document_creator/errors_test.exs` (modify) or create equivalent

- [ ] **Step 1: Inspect existing structure**

`cat lib/phoenix_kit_document_creator/errors.ex` to confirm the dispatch shape — every existing atom has a `def message(:atom_name), do: gettext("…")` clause.

- [ ] **Step 2: Write failing tests**

Append to `test/phoenix_kit_document_creator/errors_test.exs` (create the file with a stub `defmodule PhoenixKitDocumentCreator.ErrorsTest do use ExUnit.Case, async: true` if it doesn't exist):

```elixir
describe "message/1 — image errors" do
  for atom <- [
        :image_not_found,
        :image_url_not_public,
        :image_too_large,
        :image_insert_failed,
        :image_tag_not_found,
        :missing_required_value
      ] do
    test "returns a non-empty string for #{atom}" do
      assert is_binary(PhoenixKitDocumentCreator.Errors.message(unquote(atom)))
      assert PhoenixKitDocumentCreator.Errors.message(unquote(atom)) != ""
    end
  end
end
```

- [ ] **Step 3: Run, expect fail**

`mix test test/phoenix_kit_document_creator/errors_test.exs` — fails since clauses don't exist (or falls through to `inspect/1` which still returns a string but you can detect by content; if your fallthrough returns a `:atom_name` string that test still passes, so tighten by asserting it does NOT start with `":"`):

```elixir
refute String.starts_with?(PhoenixKitDocumentCreator.Errors.message(unquote(atom)), ":")
```

- [ ] **Step 4: Add the clauses**

In `errors.ex`, before the catch-all fallback:

```elixir
def message(:image_not_found),
  do: gettext("Image media not found")

def message(:image_url_not_public),
  do: gettext("Image URL is not publicly accessible or exceeds 2 KB")

def message(:image_too_large),
  do: gettext("Image exceeds 50 MB or 25 megapixels")

def message(:image_insert_failed),
  do: gettext("Failed to insert images into document")

def message(:image_tag_not_found),
  do: gettext("Image placeholder tag not found in template")

def message(:missing_required_value),
  do: gettext("A required variable was not filled")
```

- [ ] **Step 5: Run, expect pass**

`mix test test/phoenix_kit_document_creator/errors_test.exs`.

- [ ] **Step 6: Commit**

```bash
git add lib/phoenix_kit_document_creator/errors.ex test/phoenix_kit_document_creator/errors_test.exs
git commit -m "feat(errors): add 6 image-pipeline error atoms"
```

---

## Task 8 — Document-tree walker: find tag ranges in body, headers, footers, table cells

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex`
- Test: `test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs` (create)

The existing `get_document_text/1` only walks `body.content` paragraph elements. The image pipeline needs **positions** (`startIndex`, `endIndex`) of each tag occurrence, and must look in headers, footers, and table cell contents too.

- [ ] **Step 1: Write the failing test with a fixture document**

Create `test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs`:

```elixir
defmodule PhoenixKitDocumentCreator.GoogleDocsClient.ImageSubstitutionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  # Mimics a minimal Google Docs JSON response.
  defp doc_with_text(text, start_index \\ 1) do
    %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{
                  "startIndex" => start_index,
                  "endIndex" => start_index + String.length(text),
                  "textRun" => %{"content" => text}
                }
              ]
            }
          }
        ]
      }
    }
  end

  describe "find_image_tag_ranges/2" do
    test "finds a single tag in body" do
      doc = doc_with_text("Logo: {{ image: logo }} done", 1)

      assert GoogleDocsClient.find_image_tag_ranges(doc, ["logo"]) == [
               %{
                 name: "logo",
                 start_index: 7,
                 end_index: 24
               }
             ]
    end

    test "finds the same tag in multiple positions" do
      doc = doc_with_text("A {{ image: x }} B {{ image: x }} C", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["x"])
      assert length(ranges) == 2
      assert Enum.all?(ranges, &(&1.name == "x"))
    end

    test "ignores tags not in the requested name list" do
      doc = doc_with_text("{{ image: yes }} {{ image: no }}", 1)
      ranges = GoogleDocsClient.find_image_tag_ranges(doc, ["yes"])
      assert Enum.map(ranges, & &1.name) == ["yes"]
    end

    test "walks into headers" do
      doc = %{
        "body" => %{"content" => []},
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "walks into footers" do
      doc = %{
        "body" => %{"content" => []},
        "footers" => %{
          "kix.f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "endIndex" => 18,
                      "textRun" => %{"content" => "{{ image: logo }}"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      assert [%{name: "logo"}] = GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end

    test "walks into table cells" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "content" => [
                          %{
                            "paragraph" => %{
                              "elements" => [
                                %{
                                  "startIndex" => 5,
                                  "endIndex" => 22,
                                  "textRun" => %{"content" => "{{ image: logo }}"}
                                }
                              ]
                            }
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%{name: "logo", start_index: 5, end_index: 22}] =
               GoogleDocsClient.find_image_tag_ranges(doc, ["logo"])
    end
  end
end
```

- [ ] **Step 2: Run, expect fail**

`mix test test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs` — `undefined function find_image_tag_ranges/2`.

- [ ] **Step 3: Implement the walker**

Add to `google_docs_client.ex` (near the bottom of the public API, before private helpers):

```elixir
@doc """
Scans a `documents.get` response for image tag occurrences.

Returns a flat list of `%{name, start_index, end_index}` covering every
occurrence in body content, headers, footers, and table cells, restricted
to the names supplied.
"""
@spec find_image_tag_ranges(map(), [String.t()]) ::
        [%{name: String.t(), start_index: integer(), end_index: integer()}]
def find_image_tag_ranges(%{} = doc, names) when is_list(names) do
  names_set = MapSet.new(names)

  body_blocks = get_in(doc, ["body", "content"]) || []
  header_blocks = doc |> Map.get("headers", %{}) |> Map.values() |> Enum.flat_map(&Map.get(&1, "content", []))
  footer_blocks = doc |> Map.get("footers", %{}) |> Map.values() |> Enum.flat_map(&Map.get(&1, "content", []))

  (body_blocks ++ header_blocks ++ footer_blocks)
  |> Enum.flat_map(&walk_block/1)
  |> Enum.flat_map(&extract_tag_ranges(&1, names_set))
end

defp walk_block(%{"paragraph" => %{"elements" => elements}}), do: elements

defp walk_block(%{"table" => %{"tableRows" => rows}}) do
  Enum.flat_map(rows, fn %{"tableCells" => cells} ->
    Enum.flat_map(cells, fn %{"content" => content} ->
      Enum.flat_map(content, &walk_block/1)
    end)
  end)
end

defp walk_block(_), do: []

defp extract_tag_ranges(%{"textRun" => %{"content" => content}, "startIndex" => base}, names_set) do
  regex = ~r/\{\{\s*(image|images)\s*:\s*(\w+)\s*\}\}/

  Regex.scan(regex, content, return: :index)
  |> Enum.flat_map(fn match ->
    [{full_start, full_len} | _] = match
    name_capture = Enum.at(match, 2)
    {name_start, name_len} = name_capture
    name = String.slice(content, name_start, name_len)

    if MapSet.member?(names_set, name) do
      [
        %{
          name: name,
          start_index: base + full_start,
          end_index: base + full_start + full_len
        }
      ]
    else
      []
    end
  end)
end

defp extract_tag_ranges(_, _), do: []
```

Notes for the implementer:
- `Regex.scan(..., return: :index)` returns byte offsets. The Google Docs `startIndex` counts **UTF-16 code units**, not bytes. For ASCII templates these are identical; for templates containing multi-byte text (Russian, emoji) outside the tag, byte and code-unit offsets diverge. Mark this as a known limitation in the function moduledoc and add an integration test in Task 16 with a Cyrillic neighbouring text to confirm the chosen offset matches Google's expectations. If they diverge in practice, switch to walking character-by-character with a counter.

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/google_docs_client.ex test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs
git commit -m "feat(docs-client): walk doc tree to find image tag ranges"
```

---

## Task 9 — Build the image-substitution batchUpdate body

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex`
- Modify: `test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs`

This task produces the pure function that converts (ranges + resolved media) into the request list. It does NOT call the API.

- [ ] **Step 1: Write the failing tests**

Append to the test file:

```elixir
describe "build_image_batch_requests/2" do
  test "single image: delete range + insert one image" do
    ranges = [%{name: "logo", start_index: 10, end_index: 27}]

    fills = %{
      "logo" => %{
        kind: :image,
        default_width_px: 400,
        separator: nil,
        media: [%{uri: "https://x/a.png", width_px: 800, height_px: 400}]
      }
    }

    [delete, insert] = GoogleDocsClient.build_image_batch_requests(ranges, fills)

    assert delete == %{
             deleteContentRange: %{range: %{startIndex: 10, endIndex: 27}}
           }

    assert insert == %{
             insertInlineImage: %{
               location: %{index: 10},
               uri: "https://x/a.png",
               objectSize: %{
                 width: %{magnitude: 400 * 9525, unit: "EMU"},
                 height: %{magnitude: 200 * 9525, unit: "EMU"}
               }
             }
           }
  end

  test "image_list with newline separator: insertions ordered last-first to preserve visual order" do
    ranges = [%{name: "photos", start_index: 5, end_index: 24}]

    fills = %{
      "photos" => %{
        kind: :image_list,
        default_width_px: 400,
        separator: :newline,
        media: [
          %{uri: "u1", width_px: 400, height_px: 400},
          %{uri: "u2", width_px: 400, height_px: 400},
          %{uri: "u3", width_px: 400, height_px: 400}
        ]
      }
    }

    requests = GoogleDocsClient.build_image_batch_requests(ranges, fills)

    # delete first, then last image, then sep, then mid, then sep, then first.
    assert [
             %{deleteContentRange: _},
             %{insertInlineImage: %{uri: "u3"}},
             %{insertText: %{text: "\n", location: %{index: 5}}},
             %{insertInlineImage: %{uri: "u2"}},
             %{insertText: %{text: "\n", location: %{index: 5}}},
             %{insertInlineImage: %{uri: "u1"}}
           ] = requests
  end

  test "image_list with :none separator: no insertText" do
    ranges = [%{name: "x", start_index: 0, end_index: 17}]

    fills = %{
      "x" => %{
        kind: :image_list,
        default_width_px: 400,
        separator: :none,
        media: [
          %{uri: "u1", width_px: 400, height_px: 400},
          %{uri: "u2", width_px: 400, height_px: 400}
        ]
      }
    }

    requests = GoogleDocsClient.build_image_batch_requests(ranges, fills)
    refute Enum.any?(requests, &Map.has_key?(&1, :insertText))
  end

  test "multiple ranges: processed in descending startIndex order" do
    ranges = [
      %{name: "a", start_index: 5, end_index: 22},
      %{name: "a", start_index: 50, end_index: 67}
    ]

    fills = %{
      "a" => %{
        kind: :image,
        default_width_px: 400,
        separator: nil,
        media: [%{uri: "u", width_px: 400, height_px: 400}]
      }
    }

    [del1, _ins1, del2, _ins2] = GoogleDocsClient.build_image_batch_requests(ranges, fills)
    assert get_in(del1, [:deleteContentRange, :range, :startIndex]) == 50
    assert get_in(del2, [:deleteContentRange, :range, :startIndex]) == 5
  end

  test "optional empty value still deletes the tag" do
    ranges = [%{name: "x", start_index: 5, end_index: 22}]

    fills = %{
      "x" => %{kind: :image, default_width_px: 400, separator: nil, media: []}
    }

    assert [%{deleteContentRange: _}] =
             GoogleDocsClient.build_image_batch_requests(ranges, fills)
  end
end
```

- [ ] **Step 2: Run, expect fail**

`undefined function build_image_batch_requests/2`.

- [ ] **Step 3: Implement**

Add to `google_docs_client.ex`:

```elixir
@px_to_emu 9525

@doc """
Builds the list of `batchUpdate` request maps to substitute image tags.

`fills` is a map keyed by variable name; each value carries `kind`,
`default_width_px`, `separator` (atom or nil), and `media` — a list of
`%{uri, width_px, height_px}`.

Empty media list = the tag is still deleted (cleared).
"""
@spec build_image_batch_requests([map()], map()) :: [map()]
def build_image_batch_requests(ranges, fills) do
  ranges
  |> Enum.sort_by(& &1.start_index, :desc)
  |> Enum.flat_map(fn %{name: name, start_index: s, end_index: e} ->
    fill = Map.fetch!(fills, name)

    delete = %{deleteContentRange: %{range: %{startIndex: s, endIndex: e}}}

    inserts =
      case fill.kind do
        :image -> single_image_inserts(fill, s)
        :image_list -> list_image_inserts(fill, s)
      end

    [delete | inserts]
  end)
end

defp single_image_inserts(%{media: []}, _index), do: []

defp single_image_inserts(%{media: [media | _], default_width_px: w}, index) do
  [insert_inline_image_request(media, w, index)]
end

defp list_image_inserts(%{media: []}, _index), do: []

defp list_image_inserts(%{media: media, default_width_px: w, separator: sep}, index) do
  # Insert in reverse so that the first media ends up at the lowest index
  # after all insertions land at the same location.
  reversed = Enum.reverse(media)

  reversed
  |> Enum.with_index()
  |> Enum.flat_map(fn {m, i} ->
    img = insert_inline_image_request(m, w, index)

    # Add a separator BEFORE every image except the first one inserted (which
    # is the last in visual order). i == 0 is the visually-last image; no sep
    # before it from this side. The sep belongs between consecutive images,
    # so we emit it after each image except the visually-first (i.e. the
    # last we insert, which has i == length - 1).
    if i < length(reversed) - 1 do
      [img, separator_request(sep, index)]
    else
      [img]
    end
  end)
  |> Enum.reject(&is_nil/1)
end

defp insert_inline_image_request(%{uri: uri, width_px: w_px, height_px: h_px}, default_width_px, index) do
  scaled_height_px = scale_height(default_width_px, w_px, h_px)

  %{
    insertInlineImage: %{
      location: %{index: index},
      uri: uri,
      objectSize: %{
        width: %{magnitude: default_width_px * @px_to_emu, unit: "EMU"},
        height: %{magnitude: scaled_height_px * @px_to_emu, unit: "EMU"}
      }
    }
  }
end

defp scale_height(_target_width, src_width, src_height) when src_width in [nil, 0],
  do: src_height || 0

defp scale_height(target_width, src_width, src_height) do
  round(target_width * src_height / src_width)
end

defp separator_request(:none, _index), do: nil

defp separator_request(sep, index) do
  text =
    case sep do
      :newline -> "\n"
      :space -> " "
    end

  %{insertText: %{text: text, location: %{index: index}}}
end
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/google_docs_client.ex test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs
git commit -m "feat(docs-client): build image substitution batch requests"
```

---

## Task 10 — Wire `substitute_images/2` orchestrator (API-calling)

**Files:**
- Modify: `lib/phoenix_kit_document_creator/google_docs_client.ex`

This is the only image function that actually calls the API. It does `documents.get` → `find_image_tag_ranges/2` → `build_image_batch_requests/2` → `batch_update/2`.

- [ ] **Step 1: Write failing test (stubbed)**

In the same test file, with Mox or a manual stub. The project doesn't appear to use Mox heavily — verify with `grep -r "import Mox" test/`. If absent, prefer an injectable client via function arg:

```elixir
describe "substitute_images/3" do
  test "no-op when there are no image fills" do
    # Pass stubs for get + batch_update; assert neither is called.
    get_fn = fn _ -> flunk("get should not be called") end
    batch_fn = fn _, _ -> flunk("batch_update should not be called") end

    assert {:ok, :noop} =
             GoogleDocsClient.substitute_images("file-id", %{}, get_fn: get_fn, batch_fn: batch_fn)
  end

  test "calls batch_update with built requests" do
    doc = %{
      "body" => %{
        "content" => [
          %{
            "paragraph" => %{
              "elements" => [
                %{
                  "startIndex" => 1,
                  "endIndex" => 18,
                  "textRun" => %{"content" => "{{ image: logo }}"}
                }
              ]
            }
          }
        ]
      }
    }

    get_fn = fn "file-id" -> {:ok, %{body: doc}} end

    batch_fn = fn "file-id", requests ->
      send(self(), {:batch, requests})
      {:ok, %{}}
    end

    fills = %{
      "logo" => %{
        kind: :image,
        default_width_px: 400,
        separator: nil,
        media: [%{uri: "u", width_px: 400, height_px: 400}]
      }
    }

    assert {:ok, _} =
             GoogleDocsClient.substitute_images("file-id", fills, get_fn: get_fn, batch_fn: batch_fn)

    assert_receive {:batch, [%{deleteContentRange: _}, %{insertInlineImage: _}]}
  end
end
```

- [ ] **Step 2: Run, expect fail**

`undefined function substitute_images/3`.

- [ ] **Step 3: Implement**

Add to `google_docs_client.ex`:

```elixir
@doc """
Two-step image substitution: GET the document, build the batch, send it.

`fills` is the same shape as `build_image_batch_requests/2`.

Options (used in tests):
  * `:get_fn` — overrides `get_document/1`
  * `:batch_fn` — overrides `batch_update/2`
"""
@spec substitute_images(String.t(), map(), keyword()) ::
        {:ok, map() | :noop} | {:error, term()}
def substitute_images(doc_id, fills, opts \\ []) when is_map(fills) do
  if map_size(fills) == 0 do
    {:ok, :noop}
  else
    get_fn = Keyword.get(opts, :get_fn, &get_document/1)
    batch_fn = Keyword.get(opts, :batch_fn, &batch_update/2)

    with {:ok, %{body: doc}} <- get_fn.(doc_id),
         ranges = find_image_tag_ranges(doc, Map.keys(fills)),
         requests = build_image_batch_requests(ranges, fills),
         {:ok, _} = result <- maybe_batch(batch_fn, doc_id, requests) do
      result
    else
      {:error, _} = err -> err
    end
  end
end

defp maybe_batch(_fn, _id, []), do: {:ok, %{}}
defp maybe_batch(fn_, id, requests), do: fn_.(id, requests)
```

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/google_docs_client.ex test/phoenix_kit_document_creator/google_docs_client/image_substitution_test.exs
git commit -m "feat(docs-client): add substitute_images orchestrator"
```

---

## Task 11 — Update `Documents.detect_variables/1` to forked shape and update callers

**Files:**
- Modify: `lib/phoenix_kit_document_creator/documents.ex:1434-1456`
- Grep for callers of `detect_variables` and `extract_variables` and update them.
- Test: extend `test/phoenix_kit_document_creator/documents_test.exs` if it exists; otherwise create a minimal one.

- [ ] **Step 1: List callers**

```bash
grep -rn "detect_variables\|extract_variables" lib test
```

Update them all in this task.

- [ ] **Step 2: Write failing test**

Decide whether to mock `get_document_text` or skip (existing test may already cover this). The minimum new test:

```elixir
# in test/phoenix_kit_document_creator/documents_test.exs (or new file)
test "detect_variables returns a forked map persisted to the template" do
  # Use existing fixtures or skip if Drive cannot be stubbed; this case
  # is fully exercised by the integration test in Task 16.
end
```

If a stub-friendly path doesn't exist, the integration test in Task 16 covers this, and Step 2 here is a no-op. Document that explicitly in the commit message.

- [ ] **Step 3: Rewrite the function**

In `documents.ex`:

```elixir
@spec detect_variables(String.t()) ::
        {:ok,
         %{
           text: [String.t()],
           image: [%{name: String.t(), kind: :image | :image_list}]
         }}
        | {:error, term()}
def detect_variables(file_id) when is_binary(file_id) do
  case GoogleDocsClient.get_document_text(file_id) do
    {:ok, text} ->
      fork = PhoenixKitDocumentCreator.Variable.extract_variables(text)

      var_defs =
        fork
        |> PhoenixKitDocumentCreator.Variable.build_definitions()
        |> Enum.map(&Map.from_struct/1)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Template
      |> where([t], t.google_doc_id == ^file_id)
      |> repo().update_all(set: [variables: var_defs, updated_at: now])

      {:ok, fork}

    {:error, _} = err ->
      err
  end
end
```

- [ ] **Step 4: Update internal callers from the grep**

For each hit from Step 1, switch from the old flat list to either `fork.text`, `fork.image`, or pass the full fork as appropriate. Common case: `create_document_modal.ex` reads variables from the DB (already as definitions), not by calling `detect_variables`; verify that's true.

- [ ] **Step 5: Run full test suite**

`mix test` — everything green.

- [ ] **Step 6: Commit**

```bash
git add lib/phoenix_kit_document_creator/documents.ex test
git commit -m "refactor(documents): detect_variables returns forked %{text:, image:}"
```

---

## Task 12 — Create `media.ex` façade for resolving media to URL + dimensions

**Files:**
- Create: `lib/phoenix_kit_document_creator/media.ex`
- Test: `test/phoenix_kit_document_creator/media_test.exs`

This task is **discovery-heavy**: the implementer must inspect PhoenixKit's media subsystem to find the public function that returns a media item by id and the fields containing public URL + width/height. Likely candidates: `PhoenixKitWeb.Live.Users.Media`, `PhoenixKit.Media` (if it exists). Look first in `phoenix_kit/lib/phoenix_kit/users/` and `phoenix_kit/lib/phoenix_kit_web/helpers/media_selector_helper.ex`.

- [ ] **Step 1: Investigate**

```bash
grep -rn "def get\|def fetch\|defstruct" /www/phoenix_kit/lib/phoenix_kit | grep -i media | head -20
grep -rn "width\|height" /www/phoenix_kit/lib/phoenix_kit/users | grep -i media | head
```

Identify: (a) the function to fetch a media by id (b) the URL accessor (c) the dimension fields.

If PhoenixKit Media does NOT store dimensions, fall back to omitting `objectSize.height` in the image batch (Google then uses natural aspect with our width). Document this fallback in the moduledoc.

If PhoenixKit Media does NOT expose a stable public URL, write the assumption violation as a `{:error, :image_url_not_public}` return and mark Task 16 (integration) as the verification step.

- [ ] **Step 2: Write failing test**

```elixir
defmodule PhoenixKitDocumentCreator.MediaTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Media

  test "returns {:error, :image_not_found} for unknown id" do
    assert {:error, :image_not_found} = Media.get_url_and_dimensions("nonexistent-uuid")
  end
end
```

- [ ] **Step 3: Implement**

Create `lib/phoenix_kit_document_creator/media.ex`:

```elixir
defmodule PhoenixKitDocumentCreator.Media do
  @moduledoc """
  Thin façade over PhoenixKit's media subsystem.

  Returns the public URL and natural dimensions for a media id. The image
  pipeline uses this to fill `InsertInlineImageRequest.objectSize` while
  preserving aspect ratio against the per-variable `default_width_px`.
  """

  # Replace the body of this function with the right PhoenixKit call once
  # confirmed in Step 1 of Task 12. Sketch:

  @spec get_url_and_dimensions(String.t()) ::
          {:ok, %{uri: String.t(), width_px: pos_integer() | nil, height_px: pos_integer() | nil}}
          | {:error, :image_not_found | :image_url_not_public}
  def get_url_and_dimensions(media_id) when is_binary(media_id) do
    # Pseudocode — replace with actual PhoenixKit API once located:
    case phoenix_kit_media().get(media_id) do
      nil ->
        {:error, :image_not_found}

      media ->
        case public_url(media) do
          url when is_binary(url) and byte_size(url) <= 2048 and binary_part(url, 0, 5) == "https" ->
            {:ok, %{uri: url, width_px: media[:width], height_px: media[:height]}}

          _ ->
            {:error, :image_url_not_public}
        end
    end
  end

  defp phoenix_kit_media, do: Application.fetch_env!(:phoenix_kit_document_creator, :media_module)
  defp public_url(media), do: media[:public_url]
end
```

Then in `config/config.exs` (or `runtime.exs`):

```elixir
config :phoenix_kit_document_creator,
  media_module: PhoenixKit.Media  # confirm the actual module name in Step 1
```

The indirection through `:media_module` lets the test pass without calling PhoenixKit at all (the test passes a UUID that the real module will return `nil` for, which is the documented `:image_not_found` path).

- [ ] **Step 4: Run, expect pass**

`mix test test/phoenix_kit_document_creator/media_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/media.ex test/phoenix_kit_document_creator/media_test.exs config/config.exs
git commit -m "feat(media): add façade over PhoenixKit media for url + dimensions"
```

---

## Task 13 — Add image-pass to `Documents.create_document_from_template/3`

**Files:**
- Modify: `lib/phoenix_kit_document_creator/documents.ex:660-676`
- Test: `test/phoenix_kit_document_creator/documents/image_pipeline_test.exs` (create)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PhoenixKitDocumentCreator.Documents.ImagePipelineTest do
  use ExUnit.Case, async: false

  alias PhoenixKitDocumentCreator.Documents

  # Integration-style: requires the GoogleDocsClient functions to be
  # injectable. If they are not yet, this task includes a refactor
  # to thread the client module through opts (default
  # `PhoenixKitDocumentCreator.GoogleDocsClient`).

  test "image variables route to substitute_images after text replaceAllText" do
    # Mock or use Process.put fake — record call order.
    # Assert: copy_file → replace_all_text → substitute_images → DB insert.
  end

  test "missing media id returns :image_not_found and does NOT create DB row" do
    # Pass a variable_values map with a non-existent media id.
    # Assert {:error, :image_not_found} and no Document row was inserted.
  end
end
```

These two tests pin down the contract. Decide on Mox vs manual stubs based on what the project already uses (`grep -r "Mox" mix.exs deps.exs`); follow the project convention.

- [ ] **Step 2: Run, expect fail**

Tests fail because `create_document_from_template` does not yet do any image work.

- [ ] **Step 3: Refactor `variable_values` shape distinction**

Before the new image flow, the function must distinguish text values from image values. Update the public docstring to reflect the new shape:

```
variable_values now accepts:
  %{
    "client_name" => "Acme",                                       # text
    "logo"        => %{"media_id" => "uuid"},                      # :image
    "photos"      => %{"media_ids" => ["uuid1", "uuid2"]}           # :image_list
  }
```

A helper `split_text_and_image_values/1` returns `{text_map, image_fills_map}`.

- [ ] **Step 4: Implement the orchestration**

Replace the body of `create_document_from_template/3`:

```elixir
def create_document_from_template(template_file_id, variable_values, opts \\ []) do
  doc_name = Keyword.get(opts, :name, "New Document")
  {text_values, image_value_specs} = split_text_and_image_values(variable_values)

  with {:ok, target} <- resolve_create_target(opts),
       {:ok, image_fills} <- resolve_image_fills(template_file_id, image_value_specs),
       {:ok, new_doc_id} <-
         GoogleDocsClient.copy_file(template_file_id, doc_name, parent: target.folder_id),
       {:ok, _} <- GoogleDocsClient.replace_all_text(new_doc_id, text_values),
       {:ok, _} <- GoogleDocsClient.substitute_images(new_doc_id, image_fills) do
    persist_created_document(
      new_doc_id,
      template_file_id,
      doc_name,
      variable_values,
      target,
      opts
    )
  end
end

defp split_text_and_image_values(values) do
  Enum.reduce(values, {%{}, %{}}, fn
    {k, %{"media_id" => _} = spec}, {t, i} -> {t, Map.put(i, k, spec)}
    {k, %{"media_ids" => _} = spec}, {t, i} -> {t, Map.put(i, k, spec)}
    {k, v}, {t, i} -> {Map.put(t, k, v), i}
  end)
end

defp resolve_image_fills(template_file_id, image_value_specs) do
  # 1. Load the template's variable definitions (from DB) for config lookup.
  defs = template_image_var_defs(template_file_id)

  # 2. For each filled image variable, resolve media → URI + dims.
  Enum.reduce_while(image_value_specs, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
    case Map.fetch(defs, name) do
      :error ->
        {:halt, {:error, :image_tag_not_found}}

      {:ok, def_} ->
        case resolve_one(spec, def_) do
          {:ok, fill} -> {:cont, {:ok, Map.put(acc, name, fill)}}
          {:error, _} = err -> {:halt, err}
        end
    end
  end)
end

defp template_image_var_defs(template_file_id) do
  # Read variables jsonb from the template row, filter to :image / :image_list,
  # and return as map by name.
  template = repo().get_by!(Template, google_doc_id: template_file_id)

  for var <- (template.variables || []),
      var["type"] in ["image", "image_list"],
      into: %{} do
    {var["name"],
     %{
       kind: String.to_existing_atom(var["type"]),
       default_width_px: get_in(var, ["config", "default_width_px"]) || 400,
       separator: get_in(var, ["config", "separator"]) |> normalize_separator()
     }}
  end
end

defp normalize_separator("newline"), do: :newline
defp normalize_separator(:newline), do: :newline
defp normalize_separator("space"), do: :space
defp normalize_separator(:space), do: :space
defp normalize_separator(_), do: :none

defp resolve_one(%{"media_id" => media_id}, def_) do
  with {:ok, m} <- PhoenixKitDocumentCreator.Media.get_url_and_dimensions(media_id) do
    {:ok,
     %{
       kind: def_.kind,
       default_width_px: def_.default_width_px,
       separator: def_.separator,
       media: [m]
     }}
  end
end

defp resolve_one(%{"media_ids" => ids}, def_) when is_list(ids) do
  ids
  |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
    case PhoenixKitDocumentCreator.Media.get_url_and_dimensions(id) do
      {:ok, m} -> {:cont, {:ok, [m | acc]}}
      err -> {:halt, err}
    end
  end)
  |> case do
    {:ok, list} ->
      {:ok,
       %{
         kind: def_.kind,
         default_width_px: def_.default_width_px,
         separator: def_.separator,
         media: Enum.reverse(list)
       }}

    err ->
      err
  end
end
```

- [ ] **Step 5: Run, expect pass**

`mix test test/phoenix_kit_document_creator/documents/image_pipeline_test.exs`.

- [ ] **Step 6: Run quality gate**

`mix format && mix credo --strict`.

- [ ] **Step 7: Commit**

```bash
git add lib/phoenix_kit_document_creator/documents.ex test/phoenix_kit_document_creator/documents/image_pipeline_test.exs
git commit -m "feat(documents): orchestrate text + image two-pass substitution"
```

---

## Task 14 — Admin form for per-variable config

**Files:**
- Create: `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex`
- Modify: wherever the templates admin page renders the variables list (likely `lib/phoenix_kit_document_creator/web/documents_live.ex` or a templates LiveView — find with `grep -rn "variables" lib/phoenix_kit_document_creator/web/`)
- Test: `test/phoenix_kit_document_creator/web/components/variable_config_form_test.exs`

- [ ] **Step 1: Locate the templates admin LiveView**

```bash
grep -rn "templates\|Template" lib/phoenix_kit_document_creator/web/
```

Identify where variables are listed. If editing-per-variable is not yet a feature in the existing admin UI, scope this task to **add a render-only summary** of image-variable config plus a **modal/edit form** that mutates `variables` jsonb. Decide based on what's there.

- [ ] **Step 2: Write a LiveView component test**

```elixir
defmodule PhoenixKitDocumentCreator.Web.Components.VariableConfigFormTest do
  use PhoenixKitDocumentCreatorWeb.ConnCase, async: true   # use the closest existing case template
  import Phoenix.LiveViewTest

  alias PhoenixKitDocumentCreator.Web.Components.VariableConfigForm

  test "renders default_width_px input for :image variable" do
    html =
      render_component(VariableConfigForm,
        id: "x",
        variable: %{name: "logo", type: :image, config: %{default_width_px: 400}}
      )

    assert html =~ "default_width_px"
    assert html =~ "400"
  end

  test "renders separator select for :image_list variable" do
    html =
      render_component(VariableConfigForm,
        id: "x",
        variable: %{
          name: "photos",
          type: :image_list,
          config: %{default_width_px: 400, separator: :newline, max_count: nil}
        }
      )

    assert html =~ "separator"
    assert html =~ "newline"
  end
end
```

- [ ] **Step 3: Implement the component**

Create `lib/phoenix_kit_document_creator/web/components/variable_config_form.ex` as a LiveComponent that renders form fields appropriate to the variable's type, emits `phx-change` events that the parent handles to persist into `phoenix_kit_doc_templates.variables`. Show the component test as the contract; full HEEx markup goes here. Keep it under 120 lines.

- [ ] **Step 4: Wire into the templates page**

In the parent LiveView, render `VariableConfigForm` for every `:image` / `:image_list` variable in the template's `variables` jsonb. On `phx-change`, merge the new config into the row's variables array and `repo().update!`.

- [ ] **Step 5: Run tests**

`mix test test/phoenix_kit_document_creator/web/components/variable_config_form_test.exs`.

- [ ] **Step 6: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/components/variable_config_form.ex \
        lib/phoenix_kit_document_creator/web/<parent-liveview>.ex \
        test/phoenix_kit_document_creator/web/components/variable_config_form_test.exs
git commit -m "feat(web): admin form for image-variable config"
```

---

## Task 15 — MediaBrowser-backed picker in document-creation modal

**Files:**
- Modify: `lib/phoenix_kit_document_creator/web/components/create_document_modal.ex`

The existing modal renders variable inputs. For `:image` / `:image_list` variables, replace the default `<input>` with a button that opens `MediaBrowser` in select mode and stores the chosen media id(s) into the form state.

- [ ] **Step 1: Inspect MediaBrowser select-mode API**

```bash
grep -rn "media_selector_url\|parse_selected_media\|get_first_selected" /www/phoenix_kit/lib/phoenix_kit_web/helpers/media_selector_helper.ex
```

Decide on the integration pattern: redirect to media selector, or render `MediaBrowser` as a `live_component` inside a daisyUI modal.

- [ ] **Step 2: Write a LiveView test**

```elixir
# in an existing or new test file for create_document_modal
test "image variable renders a 'Choose image' button" do
  # render the modal with one :image variable and assert the button + empty state.
end

test "image_list variable renders a 'Choose images' button and shows count when filled" do
  # render with two media_ids preselected, assert the count badge "2".
end
```

- [ ] **Step 3: Implement**

In `create_document_modal.ex` at `render_variables/1` (around line 85+):

- Branch on `var.type`:
  - `:text | :date | :currency | :multiline` — existing input
  - `:image` — `<button phx-click="open_media_picker" phx-value-name={var.name}>Choose image</button>` + thumbnail if filled
  - `:image_list` — `<button>Choose images</button>` + count badge

The parent LiveView handles `open_media_picker`, opens the selector, and on return writes into the form's `variable_values` either `%{"media_id" => id}` (single) or `%{"media_ids" => [...]}` (list).

- [ ] **Step 4: Run tests**

`mix test test/phoenix_kit_document_creator/web/components/create_document_modal_test.exs` (path may differ).

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_kit_document_creator/web/components/create_document_modal.ex test
git commit -m "feat(web): media picker for image variables in create-document modal"
```

---

## Task 16 — Integration test against the dev Google account

**Files:**
- Create: `test/integration/image_substitution_integration_test.exs`

This test runs only when the dev OAuth credentials are present (env-gated). It creates a real Google Doc with mixed tags, fills it, and asserts the resulting doc contains the substituted images.

- [ ] **Step 1: Decide skip rule**

```elixir
@moduletag :external
@moduletag :integration

setup_all do
  if System.get_env("PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH") in [nil, ""], do: :skip, else: :ok
end
```

- [ ] **Step 2: Write the end-to-end test**

```elixir
test "creates a doc with text and image substitutions, includes Cyrillic neighbour text" do
  # 1. Programmatically create a template doc with body:
  #    "Привет, {{ client }}! Логотип: {{ image: logo }} Конец."
  # 2. Run Documents.detect_variables on it.
  # 3. Upload a tiny test PNG via PhoenixKit Media → get media_id.
  # 4. Call Documents.create_document_from_template with
  #    variable_values: %{
  #      "client" => "Тест",
  #      "logo"   => %{"media_id" => media_id}
  #    }
  # 5. GET the new doc; assert:
  #    - No leftover "{{" / "}}" in body text.
  #    - At least one inlineObject present.
  #    - The text segment around the logo position is in the expected place.
end
```

- [ ] **Step 3: Verify UTF-16 vs byte index assumption**

If the test fails because the deletion range removed the wrong characters when the template contains Cyrillic before the tag, switch `extract_tag_ranges/2` to walk character-by-character maintaining a code-unit counter rather than relying on `Regex.scan(:index)` byte offsets. Add a unit test that recreates the failure.

- [ ] **Step 4: Run**

`PHOENIX_KIT_DOC_CREATOR_DEV_OAUTH=1 mix test --only external`.

- [ ] **Step 5: Commit**

```bash
git add test/integration/image_substitution_integration_test.exs
git commit -m "test(integration): end-to-end image substitution with Cyrillic"
```

---

## Task 17 — Milestone quality gate and changelog entry

- [ ] **Step 1: Full quality run**

`mix quality.ci` (format check + credo --strict + dialyzer).

Fix anything it surfaces, in **separate** commits per category (`chore(format)`, `chore(credo)`, `chore(types)`).

- [ ] **Step 2: Changelog**

Append to `CHANGELOG.md`:

```markdown
## Unreleased

### Added
- Image placeholders in templates: `{{ image: name }}` for single images and `{{ images: name }}` for ordered lists. Filled via PhoenixKit MediaBrowser in the create-document modal. Per-variable config (default width, separator) editable from the templates admin.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for image tag support"
```

- [ ] **Step 4: Push branch**

```bash
git push -u origin feat/image-tag-support
```

(Skip this step if pushing requires a separate auth handshake or the user hasn't requested a remote push yet.)

---

## Self-review checklist (planner)

- ✅ Every spec section maps to at least one task:
  - §3.1 regex → Tasks 3, 4
  - §3.2 detection API → Tasks 3, 4, 5, 11
  - §4 data model → Tasks 1, 2, 6
  - §5 media asking → Task 15
  - §6 pipeline (passes, ordering, empty-clear) → Tasks 8, 9, 10, 13
  - §7 errors → Task 7
  - §8 code layout → Tasks 1, 11, 12, 13, 14, 15
  - §9 risks (URL stability, dimensions, table/header traversal, multi-occurrence) → Tasks 8, 12, 16
  - §10 D1-D9 decisions → spread across all tasks
- ✅ No "TBD" / "TODO" in implementation steps.
- ✅ Function names consistent across tasks: `extract_string_variables/1`, `extract_image_variables/1`, `extract_variables/1`, `build_definitions/1`, `find_image_tag_ranges/2`, `build_image_batch_requests/2`, `substitute_images/3`, `Media.get_url_and_dimensions/1`, `Documents.create_document_from_template/3`.
- ✅ Task 12 (Media façade) flagged as discovery-heavy — implementer must verify PhoenixKit Media API before writing code.
- ✅ Task 8 / Task 16 flag the UTF-16 byte-offset risk explicitly.
- ✅ Task 11 marked as breaking-change-with-caller-updates-in-same-task.
- ✅ Quality gate at the end (Task 17).

## Known assumptions to confirm during implementation

1. **PhoenixKit Media API.** The exact function for fetching a media by id and the field names for public URL / width / height are not pinned in this plan — Task 12 Step 1 is where they get nailed down.
2. **`replace_all_text` brace style.** The existing implementation looks for `{{key}}` (no spaces); the regex in Variable allows `{{ key }}`. This pre-existing inconsistency is **out of scope** for this plan; if a template uses spaced text tags, text substitution may already silently fail. Note in the integration test (Task 16) whether this needs a follow-up.
3. **Modal context.** Task 14 (admin form) and Task 15 (modal picker) assume the existing admin page either already has variable-edit affordances or accepts adding them. If neither is true the implementer should add a minimal admin page for variable config separately and reference it from the templates list.
