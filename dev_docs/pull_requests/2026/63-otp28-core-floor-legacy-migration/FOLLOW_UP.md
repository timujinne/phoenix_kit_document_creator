# Follow-up — PR #63

Resolutions for `CLAUDE_REVIEW.md`, applied 2026-10-17.

### NITPICK — stale compat comments / missing `@impl`
**Fixed.** Comments rewritten; `@impl PhoenixKit.Module` on `migrate_legacy/0`.

### NITPICK — dead `:requires_unreleased_core` tags
**Fixed.** Removed from `active_integration_test.exs`.

### IMPROVEMENT - MEDIUM — empty pre-existing connection suppresses migration
**Not changed.** Matches the behaviour the PR's test asserts; revisit if a host reports unmigrated legacy credentials.

### NITPICK — `resolve_via_list_connections/1` redundancy
**Not changed.**

## GPT / Codex second review — 2026-10-17

Resolutions for `GPT_REVIEW.md`; Claude's findings above describe the earlier
review state.

### BUG - HIGH — empty connections suppress credential migration

**Fixed.** An empty `google:default` is reused by UUID and receives the legacy
credentials. Any existing non-empty credential field, including stored
ciphertext that cannot currently be decrypted, still prevents an overwrite.
Removed the obsolete assumption that core rejects duplicate connection names.
This also resolves Claude's deferred empty-connection finding.

### BUG - MEDIUM — partial migration and false success on write failure

**Fixed.** Credential, folder, and cleanup writes commit together in a host-repo
transaction. A failed write preserves the legacy source, rolls back prior
writes, and emits no migration-success activity. Error logs expose the
exception type rather than exception messages or arbitrary save-error payloads.

### Validation

New regression tests reproduced three failures before the fixes. The initial
focused run after the fixes passed all 26 tests.

Final `mix precommit` passed on Erlang/OTP 28 and Elixir 1.19.5 against the
locked Hex dependencies: warnings-as-errors compilation, unused-lock check,
Hex audit, formatting, strict Credo, Dialyzer, and the full database-backed
suite (**1107 tests, 0 failures, 1 skipped**). This includes eight new migration
regressions. The first gate run caught SQL alias style issues in the new test
file; those were corrected before the successful run.
