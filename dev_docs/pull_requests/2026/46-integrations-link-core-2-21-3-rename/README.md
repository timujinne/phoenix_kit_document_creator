# PR #46: Follow core's 2.21.3 integrations rename

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `2fcecf9` (merged at `d19ee5b`)
**Date**: 2026-09-11

## Goal

PR #44 pointed this module's two "manage connections" links at
`/admin/settings/integrations/website[/new]` — the website-wide scope this
module actually reads and writes, as opposed to the personal
`/admin/settings/integrations[/new]` (later moved to `/profile/...`) scope.
Core 2.21.3 then renamed the website-wide page from
`/admin/settings/integrations/website` to `/admin/settings/integrations`,
since the `/website` segment only existed to disambiguate it from the personal
page, which has since moved to `/profile/settings/integrations`. This left
PR #44's links pointing at a path that doesn't 404 — it matches core's
`/admin/settings/integrations/:uuid` edit route with `uuid = "website"`,
raises `Ecto.Query.CastError`, and surfaces as a LiveView reload loop. This PR
follows the rename.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/paths.ex` | New `Paths.integrations/0` and `Paths.new_integration/0` helpers pointing at core's renamed `/admin/settings/integrations[/new]`, with a doc comment recording why this module's connections are always website-scoped (never `{:user, uuid}`) and why the link lives in a helper instead of inline in a template. |
| `lib/phoenix_kit_document_creator/web/google_oauth_settings_live.ex` | The connection-picker's `empty_url` and the "Manage your Google connections in" link now call `Paths.new_integration()` / `Paths.integrations()` instead of hardcoding `Routes.path("/admin/settings/integrations/website[/new]")`. |
| `test/paths_test.exs` | Two new tests: one pins the two new helpers apart from each other and from the personal `/profile/...` page; one pins that neither carries a stale `/website` segment, with a comment explaining the silent-failure mode (`CastError` → reload loop) that made this worth a regression test rather than a one-line fix. |

## Review

See `CLAUDE_REVIEW.md`.
