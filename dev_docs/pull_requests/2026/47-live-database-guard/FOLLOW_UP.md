# Follow-up — PR #47

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-09-13.

### IMPROVEMENT - HIGH — machine-specific guard

**Resolved.** `LiveDatabaseGuard.check!/1` now refuses any name ending in
`_dev` or `_prod`, which is Phoenix's own dev/prod naming convention. That
covers all three previously listed databases and every other `<app>_dev`.
Requiring `test` in the name was rejected because it would refuse legitimate
pre-provisioned databases such as a CI container's `postgres`. The moduledoc,
error message, test names and `test_helper.exs` comment were rewritten without
the tracker id, machine path or container wording. Unit tests now cover a
`_prod` name, `postgres` passing, and `_dev` / `_prod` appearing mid-name
passing. The wiring test exercises `phoenix_kit_dev` and `my_app_prod`.
`AGENTS.md`'s Testing section documents the guard.

### IMPROVEMENT - MEDIUM — partition suffix dropped

**Resolved.** The non-refusal wiring test passes the parent run's resolved
`Test.Repo` `:database` as `PGDATABASE`, so the subprocess boots against the
same database, partition suffix included.

### BUG - MEDIUM — HexDocs `source_ref`

**Resolved.** `source_ref: @version`, with the comment corrected to record
when the tag form changed. The 0.9.3 release is tagged bare (`0.9.3`),
matching both `source_ref` and the newest existing tag. Docs already published
for 0.8.0–0.9.2 keep their broken links; republishing them is not worth it.

### NITPICK — refute coupled to core's wording

**Not fixed.** There is no wording-independent marker to match on. A comment
next to the refute now records that a core rewording weakens it silently.

### NITPICK — test module namespaces

**Not fixed.** Cosmetic; renaming only churns history.
