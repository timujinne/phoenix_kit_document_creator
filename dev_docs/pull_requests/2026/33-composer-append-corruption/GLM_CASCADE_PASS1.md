Verified. Line 2565 `|> Enum.reverse()` confirms the bullet-creates do emit descending (the commit's claim holds up). The `clear_inherited_bullets` range also checks out — since `insertPageBreak` is inline (per commit 459b824), the page break lives inside the first content paragraph, which the `[content_start, ...]` delete overlaps, so there's no uncovered stray-bullet paragraph. I'm dropping that earlier hunch.

All verification complete. Here is the review.

---

## Review — PR #33: composer append pipeline, delete/restore, taxonomy

**Scope verified:** read `diff.patch` (all 5220 lines) + all 16 commit messages; then read the actual implementation in `google_docs_client.ex`, `documents.ex`, `taxonomy.ex`, `documents_live.ex`, `composer.ex`, `stub_integrations.ex`, and the new test file — not the commit narratives. Where a commit *claimed* a property (descending order, UTF-16 correctness, lost-gating), I read the code to confirm or refute it.

**Headline:** the index arithmetic is sound and self-consistent. I specifically did *not* trust the descending-order claim and confirmed it at `google_docs_client.ex:2565` (`Enum.reverse()` after the ascending build). The UTF-16 conversion, marker-offset bookkeeping, positional table matching, ragged-row padding, empty-cell paragraph replay, and the GET-404 vs PATCH-404 / lost-gating split all hold up under direct read. No blocker or major functional defect found. What remains is one real (narrow) fidelity bug plus doc/test-quality items.

---

### Findings

**1. (minor) `resolve_bullet_preset` misclassifies numbered lists that use `LOWER_ALPHA` / `LOWER_ROMAN` glyphs — they replay as bullets.**
`lib/phoenix_kit_document_creator/google_docs_client.ex:2232`
Allowlist is `~w(DECIMAL ZERO_DECIMAL UPPER_ALPHA ALPHA UPPER_ROMAN ROMAN)`; the catch-all `_` at `:2248` maps anything else to `BULLET_DISC_CIRCLE_SQUARE`. Google's `GlyphType` enum also includes `LOWER_ALPHA` (a,b,c) and `LOWER_ROMAN` (i,ii,iii) — the standard glyphs for 2nd/3rd-level *numbered* lists. *Failure scenario:* a template contains a multi-level numbered list (1 → a → i); the level-1 paragraphs carry `glyphType: "LOWER_ALPHA"`. On append, `resolve_bullet_preset` returns `BULLET_DISC_CIRCLE_SQUARE`, so `createParagraphBullets` renders that numbered sub-list as bullets — the section's numbering family is silently wrong. This directly undercuts the "reproduces glyph *family*" guarantee commit 55cb044 claims. Narrow trigger, no data loss, in a documented approximation zone — hence minor, but it's the one finding worth fixing around merge. (Broader fragility in the same function: the numbered/bulleted decision keys on `glyphType` being *present at all*; if a numbered list's nesting level omits `glyphType` in favour of `glyphFormat`, it also falls through to BULLET. The test fixtures always set `glyphType`, so this path is unexercised.)

**2. (nit) Stale references to the removed `fill_table_cells_text/2` in the new test file's own docs.**
`test/phoenix_kit_document_creator/google_docs_client_append_tables_test.exs:9` (@moduledoc) and `:204` (a helper comment).
Commit 722af77 removed `fill_table_cells_text/2` and its message claims "doc references that still called it Phase 2 — those docs now name the functions actually in the call path." It fixed the lib-side docs but missed the two references in this test file (grep confirms the function exists nowhere under `lib/`). *Failure scenario:* a reader follows the moduledoc's "Phase 2 — `fill_table_cells_text/2`" pointer and finds no such function — the very half-fixed doc rot the commit set out to clear. This is exactly the "previous round's fix itself left a gap" category.

**3. (nit / observation — test quality) The append tests assert internal self-consistency, not real Docs-API behaviour.**
`test/phoenix_kit_document_creator/google_docs_client_append_tables_test.exs` (the `get_fn`/`batch_fn` injection strategy throughout).
Every flow test injects a mock that encodes the *same* Docs-API model the implementation assumes — e.g. that `insertTable` shifts the resulting `startIndex` by +1 (the "implicit paragraph break" of commit 262a4c9), that a bare cell carries a trailing `"\n"` at `insert_index+1`, that pre-existing tables surface `startIndex` on the block (commit 2a51aec). *Failure scenario:* if any of those model assumptions is wrong against the live API, the mock still returns exactly what the implementation expects, the test goes green, and the bug only surfaces in production — as in fact already happened with the nested-`table`/`startIndex` bug, where the original mocks "mirrored the bug instead of the real API shape." Consequently the suite's green run is weak evidence of correctness; the actual validation weight rests on the per-commit "verified live" claims (262a4c9, 2a51aec, 459b824, 55cb044), which a code review cannot re-run. Flagging so the next pass calibrates confidence on the live-verification claims rather than the ~3300 test lines. Not a defect to fix in-code; a known limit of mock-driven testing of a third-party API.

**4. (nit) `phoenix_kit` requirement widened to `>= 1.7.189 and < 3.0.0`.**
`mix.exs` (commit 7230c5b).
Deliberate and documented, so not blocking — just noting the forward-compat risk: the cap protects only against a `3.0` break, so an as-yet-unreleased `2.x` with a contract change (e.g. a `PhoenixKit.Module` callback arity or `Utils.Routes` shape) would resolve cleanly and fail at runtime. Acceptable for a Hex-published module that's asserting contract stability, but worth a CI run against core's tip before each `2.x` lands upstream.

---

**Out of scope (pre-existing, not introduced by this PR):** `substitute_all_sections`'s image-phase re-reads the document and computes image-insert ranges against a snapshot that the just-run text substitutions have already shifted; for templates whose `{{var}}` substitutions change text length *and* that carry images, image insert indices can be stale. This predates the PR's branch and isn't touched here — noting only so it isn't mistaken for a regression.

**Vereat:** APPROVE — the core corruption fix (index arithmetic, UTF-16, table matching, delete/restore gating) is correct under direct verification; the four items above are a narrow bullet-family misclassification worth a fast-follow plus doc/test-quality nits, none of which block merge.
