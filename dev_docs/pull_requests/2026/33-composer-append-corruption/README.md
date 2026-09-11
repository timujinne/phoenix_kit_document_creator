# PR #33 — Composer append corruption fixes

**PR:** https://github.com/BeamLabEU/phoenix_kit_document_creator/pull/33
**Head:** `timujinne:fix/composer-batchupdate` (cut fresh from upstream/main; byte-identical to the working branch `fix/batch-update-silent-400`)
**Opened:** 2026-08-10 · 10 commits · +4146 / −63 across 9 files

## What

Eight fixes for the Google Docs composer and admin UX, developed against production corruption incidents, plus two integration commits:

1. Silent batchUpdate failures — check HTTP status, skip empty insertText
2. Silently dropped tables on section append (three-phase flatten → skeleton → fill pipeline)
3. Cross-section table corruption — `startIndex` read from the block, not nested under `"table"`
4. Column widths + character styling preserved in appended sections
5. Delete succeeds for orphaned rows whose Drive file is already gone (GET-404 vs PATCH-404 split)
6. Category/type taxonomy UX gaps
7. Paragraph-level formatting preserved in appended sections
8. Real paragraph break at section boundaries (no formatting bleed)
9. Restore PATCH-404 test updated to the new `:move_failed` contract
10. mix.lock prune (unused igniter set aborted `deps.unlock --check-unused` on main itself)

## Validation

- `pk-test` full suite (integration included, real DB): **800 tests, 0 failures** (4 excluded = `:requires_unreleased_core`)
- `mix precommit` in a clean worktree of the PR branch: **exit 0** (compile -W, deps.unlock check, hex.audit, format-check, credo --strict, dialyzer, unit tests)

## Reviews (2026-08-10, pre-merge)

- [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md) — Claude Opus, reviewer agent with console + Tidewave access. **NEEDS-WORK**: 13 findings, gating F1 (blocker: `create_type` with `""` category crashes the LiveView — confirmed live), F2 (ragged/merged-cell source tables silently shift cell content), F3 (`get_document/1` unchecked HTTP status feeds the append index math). Extensive "checked, OK" list clearing the core arithmetic.
- [GLM_REVIEW.md](GLM_REVIEW.md) — GLM 5.2 (`ask-glm -r elixir-review`), full diff + repo read access. **APPROVE**: core fixes verified correct; major finding is test-fidelity (orchestration tests use self-consistent no-op mocks, so the `+2` index model is CI-invisible — overlaps Claude's F5/F10/F11); minors: position-defaulting TOCTOU (= F13), `finish_soft_delete/4` swallows DB-write errors.

Where the two disagree, the delta is coverage, not contradiction: GLM did not exercise the blank-`category_uuid` path or the `get_document` status gap that Claude found; both independently cleared the 404-split delete semantics, the `startIndex` fix, and the UTF-16 helpers.

## Review response (2026-08-10, same day)

Five follow-up commits pushed to the PR, addressing every gating finding plus the reviewer's suggested merge path:

- **F1** → `Reject blank or malformed category_uuid before create_type's position lookup` — `Ecto.UUID.cast` guard before the max-position query; blank/malformed uuid falls back to position 0 and the changeset's validation error is restored. Tests: `""` and `"not-a-uuid"` both return `{:error, changeset}`.
- **F3 + F5** → `Check HTTP status in get_document/1 and cover the batchUpdate contract` — non-2xx `documents.get` now fails loudly with `:get_document_failed` (message in `Errors`); the upstream test pinning the old surface-the-error-body contract updated. Adds the missing batchUpdate coverage: 400 → `:batch_update_failed`, and blank-variable → delete-only request shape, asserted via a new request recorder on `StubIntegrations`.
- **F2** → `Pad ragged table rows to the declared column count when capturing cells` — chose the structural fix (pad/trim each captured row to exactly `columns`) over the loud-guard variant, so merged-header templates keep composing with per-row alignment intact. Capture-level regression tests for both the pad and trim directions.
- **F4** → `Restrict orphan soft-delete to rows sync already marked lost` — the reviewer's one-line version: the proceed-anyway branch requires `status == "lost"`. Tests: lost+404 soft-deletes, published+404 and no-row+404 fail without touching the row.
- User-requested (not review-driven): `Widen phoenix_kit requirement to >= 1.7.189 and < 3.0.0`.

Post-batch verification: full suite 811 tests, 0 failures (was 800 — 11 new); `mix precommit` exit 0 on the PR branch.

## Second follow-up batch (2026-08-10): F6–F11, F13

One commit (`Address review follow-ups: bullets, empty cells, dead API, UTF-16 coverage`):

- **F6** — `deleteParagraphBullets` over the inserted body before the create requests, clearing the bullet the "\n" split inherits from a list-item tail paragraph.
- **F7** — `paragraph_bullet_requests/2` emits descending (createParagraphBullets strips leading tabs, shifting later ranges); covers the within-cell path too.
- **F8** — empty cells replay their captured paragraph style against the pre-existing bare paragraph instead of being skipped entirely.
- **F9** — `fill_table_cells_text/2` removed (dead since the styled fill path landed); the four stale "Phase 2" doc references now name the real call path. `flatten_template_with_table_markers/1` and `get_active_type/1` deliberately kept: the former is the documented plain-capture entry point, the latter is host-facing context API.
- **F10** — first non-ASCII fixtures: Estonian diacritics and a surrogate-pair emoji pin marker positions and style-run offsets in UTF-16 units (separates `utf16_units/1` from `byte_size/1` AND `String.length/1`).
- **F11** — the cross-table fill assertion pins exact descending order instead of a sorted-set comparison.
- **F13** — the accepted read-then-insert position race is documented at the query site.

Deliberately not done: **F12** (per-render taxonomy queries — moving the toolbar's inline queries into assigns needs a refresh on every taxonomy mutation path; stale-filter risk outweighs a per-render query at current data sizes, stays a follow-up), the in-memory doc-model test harness (GLM major / the orchestration-mock gap — future work), and GLM's `finish_soft_delete/4` swallowed-DB-errors minor — **rejected on verification**: `Repo.update_all/2` raises on DB errors rather than returning an error tuple, so the "transient failure reports :ok" scenario cannot occur; a raise propagates to the LiveView's rescue and shows the failure flash.

Post-batch verification: full suite 813 tests, 0 failures; `mix precommit` exit 0 on the PR branch.

## Cascade review (2026-08-10, pre-merge sign-off)

Two-pass cascading GLM review of the full 16-commit diff: pass 1 ([GLM_CASCADE_PASS1.md](GLM_CASCADE_PASS1.md)) produced findings; pass 2 adversarially re-verified each against the code and the Docs API spec, then synthesized the publication review ([GLM_CASCADE_FINAL.md](GLM_CASCADE_FINAL.md), posted to the PR).

- **Verdict: APPROVE, zero code findings.** The cascade's verified-clean list independently re-confirms the descending bullet creates, the inherited-bullet sweep coverage, UTF-16 unit math, and the lost-gating.
- Pass 1's one code finding (`resolve_bullet_preset` allegedly missing `LOWER_ALPHA`/`LOWER_ROMAN`) was **refuted in pass 2 and independently by us** against the authoritative Docs API discovery document: the GlyphType enum has no such values — lowercase letters are `ALPHA`, lowercase Roman is `ROMAN`, both already in the allowlist. A reminder that external-reviewer API claims need spec-level verification before acting.
- Pass 1's stale-test-doc finding was real and fixed (`Point the append test docs at the real cell-fill path`) before publication, so the posted review's "no stale references" statement is true of the PR head.
- Carried observations (non-blocking): the mock-driven append tests validate self-consistency rather than live API behaviour (long-standing; the in-memory applying-mock harness remains the structural answer), and the widened `phoenix_kit` cap guards 3.0 but not a contract-breaking 2.x.
