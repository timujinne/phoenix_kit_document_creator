# PR #47: Add an in-repo guard against PGDATABASE pointing test runs at a live DB

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `107ea88` (merged at `b8653ed`)
**Date**: 2026-09-13

## Goal

`config/test.exs` honors `PGDATABASE` so the suite can target a
pre-provisioned database. A `PGDATABASE` exported for a dev shell therefore
becomes the test database, and `test_helper.exs` runs core's migrations and
this module's chain against it before any test is sandboxed. The PR makes
`test_helper.exs` refuse such a database before anything connects.

## What Was Changed

### Files Added / Modified

| File | Change |
|------|--------|
| `test/support/live_database_guard.ex` | `LiveDatabaseGuard.check!/1` raising `LiveDatabaseError` for a database name on a fixed list. |
| `test/test_helper.exs` | Calls `check!/1` on the resolved database name, ahead of the `PostgresPreflight` connection attempt. |
| `test/live_database_guard_test.exs` | Unit coverage of the refusal decision (exact match, no substring match). |
| `test/live_database_guard_wiring_test.exs` | Runs `mix test` as a subprocess with `PGDATABASE` set to a refused name and `PGHOST` unreachable, asserting a nonzero exit with the guard's exception banner and no preflight output ahead of it; plus one subprocess boot against the real test database that must succeed. |

## Review

See `CLAUDE_REVIEW.md`; resolutions in `FOLLOW_UP.md`.
