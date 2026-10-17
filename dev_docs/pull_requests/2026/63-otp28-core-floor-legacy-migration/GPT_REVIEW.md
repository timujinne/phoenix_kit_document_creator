# PR #63 — second review of the merge and Claude's follow-up

**Author:** mdon · **Reviewer:** GPT / Codex · **Date:** 2026-10-17

Reviewed merge `23371c5`, lockfile follow-up `101506f`, and Claude's review/fixes
in `f5cb9cb` against the surrounding migration code and locked core 2.62.2.

Claude's callback annotation, stale-comment cleanup, and dead-tag removal are
correct. The PR fixes the tuple-return mismatch in the old migration guard,
keeps the core requirement open to later 2.x releases, and corrects the test
URL-prefix cache key. The remaining migration issues below are now fixed.

## BUG - HIGH — an interrupted migration can be skipped forever

`already_migrated?/0` checked only whether a `google:default` row existed.
Connection creation and credential saving were separate writes, so a failure
after creation left an empty row which every later boot treated as migrated.
An empty connection created manually produces the same failure. Claude noted
the manual case as an improvement; the interrupted-write case makes this a
recovery bug as well.

**Fixed:** skip only when the existing row contains at least one OAuth setup
or token field. Check the stored values so even a temporarily undecryptable
secret remains protected. Reuse the empty row's UUID when resuming: current
core permits duplicate names, so the old `add_connection/3` → `:already_exists`
fallback would instead create a second connection and leave existing UUID
references pointing at the empty one.

Tests cover resumption without a duplicate, UUID preservation, successful
folder migration and plaintext cleanup, repeated execution, and preservation
of each individual credential field and unreadable ciphertext.

## BUG - MEDIUM — failed folder migration or cleanup still reports success

`migrate_legacy_folders/1` swallowed exceptions and its result was ignored.
The migration could clear the only legacy copy of folders after failing to
save them. `clear_legacy_oauth_key/0` also ignored error tuples and swallowed
exceptions; a cleanup failure still returned `:migrated` and emitted a success
activity, then the new guard prevented cleanup on subsequent boots.

**Fixed:** connection creation/reuse, credential saving, folder saving, and
legacy cleanup share one host-repo transaction. Error tuples roll it back;
exceptions unwind it before the existing migration rescue reports the error.
The success activity is emitted only after commit. Migration failure logs no
longer interpolate exception messages or arbitrary save errors, which can
carry database values.

Database-backed regressions inject actual write failures with sandbox-local
triggers. They verify rollback of a new connection and folders on cleanup
failure, preservation of an existing empty connection on folder failure,
absence of a success activity, and successful retry once the failure is gone.

## Retained behavior

An independently configured connection remains authoritative. If legacy
credentials coexist with it, they are left intact: automatically importing
them could replace an admin's setup, and automatically clearing them could
discard credentials for a different account. This review fixes the empty-row
case without trying to resolve that conflict automatically.

The boot reference resolver's use of `list_connections/1` remains unchanged;
its exact `default` match for a bare provider is intentional.

## Validation

The new regressions failed in three cases against `f5cb9cb`. After the fixes,
the original integration tests and initial regressions passed together
(26 tests). Final project gate results are recorded in `FOLLOW_UP.md`.
