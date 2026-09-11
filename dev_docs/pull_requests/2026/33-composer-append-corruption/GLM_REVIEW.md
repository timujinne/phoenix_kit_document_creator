I've completed a thorough review. Here are my findings.

---

## PR Review: phoenix_kit_document_creator (fix/batch-update-silent-400)

I read the full diff, all 10 commit messages, `AGENTS.md`, and traced every changed code path against the actual source (`google_docs_client.ex`, `documents.ex`, `taxonomy.ex`, `documents_live.ex`) plus the LiveView error handler and the three `move_file` callers.

### What's correct (verified, not just asserted)

- **The 404-semantics split is sound and safe (focus area 2).** `move_file/2` (`google_docs_client.ex:1384`) does a GET `files/{id}?fields=parents` *then* a PATCH. The GET-404 → `:drive_file_not_found` path is the only one that can trigger orphan-delete, and a GET 404 with a valid token genuinely means the file is gone/not-found (a 403 permission revocation falls through to `:get_file_parents_failed`, *not* orphan-delete). So **the orphan-delete path cannot DB-trash a file the bot can positively see.** PATCH-404 → `:move_failed` correctly fails the delete (file is live, destination folder missing), which is exactly the resurrection scenario the commit says it's guarding against. The atom change ripples cleanly: `move_from_deleted_folder` (restore, `documents.ex:1905`) uses a generic `error -> error` catch, and `documents_live.ex:359` keeps `:drive_file_not_found`-on-restore friendly while `:move_failed` falls to the generic flash — no broken matches.
- **`batchUpdate` status check + empty-`insertText` skip.** Both are correct. The status check closes the silent-400 hole; the empty-value `delete`-only mirrors the image path. Atomic-batch reasoning is right.
- **UTF-16 arithmetic** (`utf16_units/1`, `find_table_marker_ranges/1`, marker regex) is correct — surrogate pairs counted as 2, byte→code-unit conversion done the same way as the existing `find_text_var_ranges/2`.
- **`match_new_tables/3` + the `el["startIndex"]` (not `el["table"]["startIndex"]`) fix** is the right root-cause for the cross-section table corruption, and the regression test genuinely reproduces it.
- **`get_active_type/1`, stale-ref placeholders, qualified type filter** are all correct for the `phx-change` flow (there's no full-form submit that could "silently clear" — that comment is defensive, not an active bug).

### Findings

**1. MAJOR — test-design: the append pipeline's index arithmetic is validated only by self-consistent mocks, not by the suite (focus area 1 & 4).**
`lib/phoenix_kit_document_creator/google_docs_client.ex` — `append_template/3` (Phase 0 request list, `content_start = insert_index + 2`), `finish_append_template/6`, `cell_paragraph_spans/2`'s "natural length" trick.
The injected `batch_fn` is a no-op returning `{:ok, %{}}` and the per-phase `get_fn` returns hand-built `doc1`/`doc2`/`final_doc` snapshots that the test author constructed *from the same offset model the implementation uses*. The Docs API applies a batch's requests **sequentially, each shifting indices for the next**, and the mock simulates none of that. Consequently the load-bearing assumptions are unverified by any test:
 - `insertPageBreak` shifts indices by exactly **1** (which is what makes `content_start = insert_index + 2`, not `+1`, correct);
 - the ascending-order Phase 0 inserts (`"\n"` at `insert_index`, page break at `+1`, text at `+2`) where each index pre-pays for the prior shift;
 - the leading `"\n"` actually splitting the target's last paragraph so `updateParagraphStyle`/`createParagraphBullets` don't reformat the preceding section;
 - a cell paragraph's *un-stripped* length landing exactly on the bare cell's pre-existing trailing newline.
*Failure scenario:* a future edit nudges the page-break accounting (e.g. someone "simplifies" `content_start` back to `insert_index + 1`). Every existing test still passes — the mock never applied the shift, and the fixtures were built assuming `+2`. Production composed documents silently mis-locate the appended section and apply character/paragraph styles to the wrong ranges. The author's live verification (extensively documented in commits 262a4c9/459b824/55cb044) is the *only* thing covering this; it isn't captured in CI. *Fix:* add a fake `batch_fn`/`get_fn` harness that actually mutates an in-memory doc model (applies insertText/insertPageBreak/insertTable/deleteContentRange by shifting indices), so the index math is checked end-to-end rather than asserted. Short of that, at least one non-BMP (surrogate-pair) fixture through `find_table_marker_ranges` would exercise the UTF-16 path the ASCII tests skip.

**2. MINOR — taxonomy position defaulting has a benign TOCTOU race (focus area 3).**
`lib/phoenix_kit_document_creator/taxonomy.ex` — `next_category_position/0` / `next_type_position/1` (≈ :763).
`SELECT max(position) … ` then `+1`, outside any transaction, with no unique constraint. *Failure scenario:* two admins (or a double-click) create a category concurrently; both read the same max and insert the same position, tying for last place instead of sequencing. This is benign — position has no unique index and ties were already universal under the old default-0 — but if stable ordering matters, compute-and-insert atomically (`INSERT … RETURNING` with a CTE, or a partial unique index on `(category_uuid, position) where status = 'active'`). Worth a one-line comment noting the race is accepted.

**3. MINOR — `finish_soft_delete/4` swallows DB-write failures and reports `:ok`.**
`lib/phoenix_kit_document_creator/documents.ex:1807-1817`.
`update_file_by_google_doc_id/2` and `stamp_deleted_data/3` return values are both discarded; the function unconditionally returns `:ok`. *Failure scenario:* Drive move succeeds but the DB write hits a transient error — the user sees "deleted" (and the success activity log fires), yet the row keeps its old `status`/`path`, so it reappears and is stale. Pre-existing (the old `with` block ignored it too), but this PR refactored it into `finish_soft_delete`, so it's in scope. Pattern-match the update result and return `{:error, _}` on failure.

### On the ~2900 test lines (focus area 4)
Genuinely behavior-asserting (good): the flatten extraction/marker tests, the marker round-trip slice, the two-section cross-contamination regression, the column-width Phase-2 placement, and all the taxonomy/`get_active_type` integration tests. Implementation-mirroring (acceptable as regression locks, not as oracles): the exact-request-map unit tests for `text_style_requests/2`, `paragraph_style_requests/2`, `table_skeleton_requests/2`, and the full-batch index assertions. The mirroring is the right shape for pure request-builders; the problem is only that the *orchestration* tests (Finding 1) can't see through the no-op mock.

### Verdict

**APPROVE.** No critical or major *code* defects — the three fixes driving the PR (batchUpdate status handling, table `startIndex` read from the block, GET-vs-PATCH 404 split) are correct and well-reasoned, and the orphan-delete path is provably unable to DB-trash a live file. The major finding is a test-fidelity gap on the riskiest new code, mitigated for now by the author's live verification; address it as a follow-up rather than a blocker.
