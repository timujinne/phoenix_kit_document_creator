# Preset Management UI — Design

Date: 2026-05-17
Module: `phoenix_kit_document_creator`
Status: Approved — Stage 1

## Problem

Template presets (`TemplatePreset`) already exist at the schema and context
level (`save_preset/1`, `list_presets/1`, `apply_preset/1`), but there is no
user interface for them. Admins cannot see, create, edit, or remove presets.

Presets must be managed per **document category**: a preset belongs to one
category, and within a category presets are grouped by **document type**.
Management lives on the same admin page that already manages the
Category → Type hierarchy (`CategoriesLive`).

## Constraints

- **Stage 1 ships with zero database migrations.** Only the existing
  `TemplatePreset` fields are used.
- All new user-facing strings go through Gettext and are translated into the
  three active locales: **en, et, ru**.

## Current state (verified)

`TemplatePreset` (table `phoenix_kit_doc_template_presets`) fields:
`uuid`, `name`, `description`, `scope_type`, `scope_id`, `sections`
(`{:array, :map}` JSONB), `created_by_uuid`, timestamps.

- There is **no** free-form `data :map` field (unlike `Category`/`Type`).
- There is **no** `status` field — so no soft-delete column is available.
- `sections` is a JSONB array of section descriptor maps; each map has
  `template_uuid`, `position`, `variable_values`, `image_params`.

Context functions today: `save_preset/1` (insert only), `list_presets/1`
(filters by `scope_type`/`scope_id`, orders by name), `apply_preset/1` (drops
sections whose `template_uuid` no longer exists in the DB), `recipe_for/1`.

`Template` belongs_to `Category` and `Type` (nullable FKs), has a `status`
field (`published`/`trashed`/`lost`/`unfiled`) and a `variables` JSONB array.

## Design

### Storage convention (no migration)

A preset is associated with a category and an optional type by repurposing the
generic scope pair:

| Field        | Holds                                        |
|--------------|----------------------------------------------|
| `scope_id`   | `category_uuid` — owning category            |
| `scope_type` | `type_uuid`, or `nil`/empty — owning type    |
| `name`       | preset name                                  |
| `description`| preset description                           |
| `sections`   | ordered JSONB array of section descriptors   |
| `created_by_uuid` | acting admin                            |

This convention must be documented in the `TemplatePreset` moduledoc.
Presets with no type land in an "Untyped" group in the UI.

### 1. Presets panel on `CategoriesLive`

`CategoriesLive` gains a full-width **Presets** panel below the existing
Categories | Types two-column grid.

- The panel is shown only when a category is selected (same gating as the
  Types column).
- It lists presets of the selected category, **grouped by type**: a type
  heading, then its preset rows. Presets without a type appear under an
  "Untyped" heading.
- A **"New preset"** action opens `PresetFormLive` in `:new` mode for the
  selected category.
- Each preset row shows: name, section count, and a row menu
  (Edit / Delete).
- **Delete** is a hard delete guarded by a DaisyUI confirm modal. There is no
  Trash in Stage 1.
- **Stale flag:** if any of a preset's sections references a template that is
  missing or has `status in [trashed, lost]`, the row shows a warning badge
  `⚠ N broken templates`.

The panel subscribes to nothing new; it reloads alongside the existing
category/type reload paths.

### 2. `PresetFormLive` — form and section editor

Create/edit happens on a dedicated LiveView reached by route, mirroring
`CategoryFormLive` / `TypeFormLive`. New routes are added to
`web/routes.ex` in both the localized and non-localized blocks.

Form fields:

- `name`, `description` — text inputs.
- Category — fixed (carried from the originating selection / preset).
- Type — a select populated with the category's types, plus an "Untyped"
  option.

Section editor:

- An ordered list of sections with drag-to-reorder via the existing
  `SortableGrid` hook (same hook `CategoriesLive` uses).
- Each section row:
  - Template select — options filtered to the preset's category. A missing
    or trashed/lost template is marked with `⚠`.
  - Default `variable_values` — one value input per template variable.
  - Default `image_params` — for image-typed variables, reusing the existing
    `image_picker` / `variable_config_form` components.
  - Add section / remove section / drag handle.
- Saving writes the `sections` JSONB array with `template_uuid`, `position`,
  `variable_values`, and `image_params` per section.

### 3. Context logic (`documents.ex`)

- `list_presets/1` — already filters by `scope_id`/`scope_type`; used to load
  a category's presets.
- **New** `update_preset/2` — update an existing preset from attrs.
- **New** `delete_preset/1` — hard delete a preset.
- **New** `preset_stale_info/1` — given a preset, return the list of broken
  sections (template missing, or template `status in [trashed, lost]`) used
  to render the stale badge and per-section markers.
- `apply_preset/1` is unchanged in Stage 1.

### Gettext

Every new string in `CategoriesLive`, `PresetFormLive`, and any new
components is wrapped in `gettext/1`. After implementation, extract messages
and provide complete translations in:

- `priv/gettext/en/LC_MESSAGES/default.po`
- `priv/gettext/et/LC_MESSAGES/default.po`
- `priv/gettext/ru/LC_MESSAGES/default.po`

No `msgid` may be left with an empty `msgstr` in et and ru.

## Out of scope (Stage 1) — Future development roadmap

Recorded here as the probable evolution; **not** implemented now:

1. Migration: add a `data :map` (JSONB) column to `TemplatePreset` for
   flexible fields and statuses without further migrations.
2. Migration: replace the repurposed `scope_*` pair with real
   `category_uuid` / `type_uuid` foreign keys.
3. Trash / soft-delete for presets (`active`/`deleted`), stored in the new
   `data` map — reusing the existing status vocabulary, no new status concept.
4. Multilingual translatable fields (`name`, `description`) stored inside the
   JSONB `data` map.
5. Make `apply_preset/1` status-aware so it also drops sections whose
   template is `trashed`/`lost`, not only missing ones.

## Testing

- Context tests for `update_preset/2`, `delete_preset/1`, `preset_stale_info/1`.
- LiveView tests for the Presets panel (grouping by type, stale badge, delete
  confirm) and `PresetFormLive` (create, edit, section add/remove/reorder).
