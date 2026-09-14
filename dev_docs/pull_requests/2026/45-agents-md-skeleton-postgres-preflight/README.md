# PR #45: Standardize AGENTS.md onto the shared module skeleton

**Author**: @mdon
**Reviewer**: Claude
**Status**: Merged
**Commits**: `021dd27`, `ba034d2`, `ce95d4d`, `ef45766` (merged at `8d00c09`)
**Date**: 2026-09-08 (reviewed 2026-09-13)

## Goal

Bring `AGENTS.md` onto the eleven-heading skeleton every `phoenix_kit_*` repo
shares, re-verifying each claim against the code instead of carrying it over.
Three follow-ups ride along: a `setup_all` that loads the module before
`function_exported?/3` assertions, dropping a customer name from the docs, and
replacing the `psql -lqt` database probe in `test_helper.exs` with core's
`PhoenixKit.TestSupport.PostgresPreflight`.

## What Was Changed

| File | Change |
|------|--------|
| `AGENTS.md` / `CLAUDE.md` | Rewritten onto the shared skeleton; `CLAUDE.md` becomes a symlink to `AGENTS.md`. |
| `test/phoenix_kit_document_creator_test.exs` | `setup_all` calls `Code.ensure_loaded!/1` so `function_exported?/3` is deterministic under a random seed. |
| `test/test_helper.exs` | `PostgresPreflight.check/1` (guarded by `Code.ensure_loaded?/1`) replaces the `psql -lqt` listing; the "not found" message now defers to the preflight's printed reason. |

## Review

See `CLAUDE_REVIEW.md`. Findings were fixed on `main` directly, so there is
no separate `FOLLOW_UP.md`; the resolution is recorded inline per finding.
