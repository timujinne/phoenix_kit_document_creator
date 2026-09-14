# Claude Review — PR #45

Reviewed the merge diff (`d3cd921..8d00c09`) against `AGENTS.md`,
`test/test_helper.exs` and `test/phoenix_kit_document_creator_test.exs`,
following `elixir:elixir-thinking`. Every concrete claim in the rewritten
`AGENTS.md` was re-checked against `lib/`, `test/`, `mix.exs` and `config/`
(twenty claims; seventeen held, three were stale or wrong — listed below).

The preflight swap is sound. It is exactly the case this sandbox hits:
`psql -lqt` fails here because the shell user has no CONNECT privilege on the
`postgres` maintenance database, while the repo's own credentials connect
fine. The old probe would have reported "not found" and silently excluded
every `:integration` test; the new one passes and the full suite runs.

## Findings

### IMPROVEMENT - MEDIUM — the `rescue` / `catch` messages lost a line break and now make a false claim

`test/test_helper.exs` lines 96 and 104: the edit collapsed the message onto
one line (`… integration tests excluded.           The reason is printed
above.`) and the sentence itself is wrong in that branch. Those two clauses
run only after the preflight returned `:ok` (or was absent), so nothing was
printed above; the actual reason is the `Error:` line that follows.

**Resolved:** restored the two-line layout, named the database, and dropped
the "printed above" sentence in both clauses.

### IMPROVEMENT - MEDIUM — `AGENTS.md` still describes the probe this PR removed

The Testing section (lines 371–372) says the helper "probes for it with
`psql -lqt` (falling back to a connect attempt when `psql` is absent)". The
same PR replaced that with the preflight, whose fallback is a bare
`start_link`, not `psql`.

**Resolved:** rewritten to describe the preflight, its fallback, and where the
`PG*` variables are actually read (`config/test.exs`).

### IMPROVEMENT - MEDIUM — two `AGENTS.md` rules are stated more strongly than the code

- "Never call `PhoenixKit.Activity.log/1` directly from anywhere else" — three
  other guarded call sites exist (`Taxonomy.log_activity/1`,
  `GoogleDocsClient.migrate_legacy_connection/1`, and the top-level module's
  credentials migration). **Resolved:** the rule now names the four sites and
  asks new logging to go through one of the two helpers.
- "Any file using `StubIntegrations` must declare `async: false`" — the two
  `LiveCase` files relied on ExUnit's default instead of declaring it.
  **Resolved:** both now pass `async: false` explicitly with a one-line reason.
- The `mix precommit` one-liner listed `format` (it runs
  `format --check-formatted`) and omitted that the alias runs the full test
  suite. **Resolved:** corrected.

### NITPICK — stale comments in `test/test_helper.exs`

The new preflight comment cited a `~> 2.0` core floor (it was `~> 2.4`, now
`~> 2.21 and >= 2.21.3`). Older blocks in the same file still referenced Hex
`phoenix_kit ~> 1.7`, a `phoenix_kit_parent` test channel, pre-squash core
migration numbers (`V40`, `V86`, `V94`, `V110`) and "V1" for a chain that is
at V2.

**Resolved:** all replaced with the current facts (`PHOENIX_KIT_PATH` via
`pk_dep/3`, the V135 baseline, a version-keyed chain).

## Checked and confirmed

- `PostgresPreflight.check/1` accepts the raw repo config keyword and strips
  everything but connection keys (`Keyword.take(@connection_keys)`), so
  passing `db_config` wholesale — `pool`, `pool_size` included — is safe.
- The `Code.ensure_loaded?/1` guard is live: the preflight first shipped in
  core 2.22.3, and the module's floor is below that.
- The `setup_all` / `Code.ensure_loaded!/1` fix targets a real ExUnit
  behaviour (`function_exported?/3` is false for an unloaded module).
