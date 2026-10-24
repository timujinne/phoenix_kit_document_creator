# PR #21: image-columns config in the template editor + Categories tab last

**Author**: @timujinne
**Reviewer**: @claude (Dmitri Don)
**Status**: Merged
**Commit**: `d2e0798` (merge); feature commits `c8b0128`, `6fbefce`
**Date**: 2026-05-21

## Goal

Two changes stacked on top of [#20](/dev_docs/pull_requests/2026/20-image-columns-helpers-trash-tabs/).
The first lets template authors choose a default column count (1–4) per
`image_list` variable, which the multi-column renderer added in #20 then consumes.
The second is a one-line sidebar ordering fix.

## What Was Changed

### 1. `columns` field on `image_list` variable config

| File | Change |
|------|--------|
| `variable.ex` | `default_image_config(:image_list)` gains `columns: 1`. |
| `documents.ex` | `coerce_config/1` parses + clamps `columns` to 1..4; `image_slots_for_template/1` now returns `%{name, kind, config}` so consumers read `columns`/`max_count`/etc. without re-querying. Merged config is normalised to string keys. |
| `web/components/variable_config_form.ex` | A Columns `<select>` (1..4) for `:image_list` variables, styled like the existing `separator`/`max_count` fields. |

The selected value flows: template editor → `variables[*].config.columns` → consumer
(a host app's order document picker) → `image_params[slot]["columns"]` → `google_docs_client`'s
column-aware dispatch (`cols >= 2` ⇒ table grid, `cols == 1` ⇒ inline).

### 2. Sidebar: Categories tab moved last

`lib/phoenix_kit_document_creator.ex` — child tabs sort by ascending `priority`. Categories
had `647` (before Documents 648 / Templates 649); bumped to `651` so it sorts after both.

## Implementation Details

- **No migration.** `columns` lives in the existing `template.variables[*].config` jsonb.
- **No breaking API change.** `image_slots_for_template/1`'s map grows a `:config` key;
  callers that pattern-match `%{name, kind}` still match. `column_overrides` on the wire
  are additive.

## Testing

- [x] `coerce_config` clamping covered by existing config tests.
- [x] `image_slots_for_template/1` shape — see follow-up; the integration test asserting
      the old `%{name, kind}` shape was updated to account for `:config`.

## Related

- Base PR: [#20](/dev_docs/pull_requests/2026/20-image-columns-helpers-trash-tabs/)
- Combined review + post-merge fixes live under #20's
  [`CLAUDE_REVIEW.md`](/dev_docs/pull_requests/2026/20-image-columns-helpers-trash-tabs/CLAUDE_REVIEW.md)
  and [`FOLLOW_UP.md`](/dev_docs/pull_requests/2026/20-image-columns-helpers-trash-tabs/FOLLOW_UP.md).
