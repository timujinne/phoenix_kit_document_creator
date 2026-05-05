# PR #12 Follow-Up — fixes applied post-merge

PR #12 was reviewed in `CLAUDE_REVIEW.md`. The findings below were fixed
directly on `main` after merge to keep them moving without bouncing the work
back to the original author. Behavior changes (§1.2) and cross-version
coordination concerns (§1.3) were left alone — they deserve a fresh
discussion.

## Fixes applied

### §1.1 — Legacy plaintext OAuth secrets are wiped after migration **[security]**

`lib/phoenix_kit_document_creator.ex` — `do_migrate_oauth_credentials/1` now
calls a new `clear_legacy_oauth_key/0` helper after the activity log emission.
The legacy `document_creator_google_oauth` row is reset to `%{}` so
`client_secret` / `access_token` / `refresh_token` don't survive the move to
encrypted Integrations storage. Failure to clear is best-effort — logs a
warning, doesn't roll back the migration.

New test: `test/integration/active_integration_test.exs` →
`"credentials migration: clears the legacy oauth key after success"`. Tagged
`:requires_unreleased_core` like the other strict-UUID integration tests.

README + AGENTS.md updated to document the wipe as part of the migration
contract.

### §1.4 — `migrate_legacy/0` `with` block dropped

The `with creds_result <- ..., refs_result <- ...` chain produced no
short-circuit (no `else`, no `{:ok,_}` pattern) and just shadowed two plain
assignments. Replaced with sequential bindings. Both inner functions still
have their own `rescue`, the outer one still wraps the result, so behavior is
identical and the elixir-thinking "with-without-purpose" smell is gone.

### §1.5 — `uuid_shape?` regex / comment mismatch + duplication

The regex matches any RFC 4122-shaped UUID, not specifically v7. Two fixes:

1. Comment in `google_docs_client.ex` updated to say "RFC 4122-shaped UUID"
   and explicitly call out that the version digit isn't enforced (the guard
   only needs to discriminate "promoted" from "legacy `google` / `google:name`"
   inputs).
2. Duplicate regex in `phoenix_kit_document_creator.ex` removed. New
   `GoogleDocsClient.uuid?/1` is the shared helper; the boot-time sweep in
   `migrate_legacy_connection_references/0` now calls it instead of carrying
   its own copy of the regex.

### §1.6 — Misleading `uuid` variable name in `active_integration_uuid/0`

The pattern `%{"google_connection" => uuid}` matched any binary, including
legacy non-uuid strings. Renamed to `stored` so the `uuid?(stored)` check
reads as "is this stored value a uuid" rather than the tautological "is this
uuid a uuid".

### §1.8 — Hex-shape failing tests are now tagged

The three tests in `test/integration/active_integration_test.exs` that call
`PhoenixKit.Integrations.add_connection/3` directly (and the new §1.1 test
that exercises the migration path) are tagged `@tag :requires_unreleased_core`.

`test/test_helper.exs` excludes `:requires_unreleased_core` by default. To
opt in once core publishes the matching version:

```bash
mix test --include requires_unreleased_core
```

Standalone `mix test` against Hex `~> 1.7` now exits clean — no shape-mismatch
red herrings.

## Findings deferred / not addressed

| Finding | Reason |
|---------|--------|
| ~~§1.2 — boot vs lazy fallback asymmetry for bare `"google"`~~ | **Closed in Batch 2 (2026-05-05).** Picked the conservative branch: both paths require an exact `provider:name` match; on no match the setting is cleared and the admin gets the "not configured" prompt. The "any connected row of this provider" silent-pick fallback is gone. Activity log + warning fire on both paths' failure side. |
| ~~§1.3 — `already_migrated?/0` queries via legacy string key~~ | **Closed in Batch 2 (2026-05-05).** Prefers `Integrations.find_uuid_by_provider_name/1` (core 1.7.105+) via a `function_exported?/3` runtime guard + `apply/3` to dodge the compile-time warning on older cores. Falls back to the legacy `provider:name` string lookup. The fallback can be deleted once `~> 1.7.105` is the floor. |
| ~~§1.7 — Lazy on-read writes mutate the DB during GET requests~~ | Reaffirmed (no change). Documented in code; relevant only if reads ever go to a replica. Persists as a forward-looking caveat; not actionable today. |
| ~~§1.9 — Test stub uses `:named_table` ETS (implicit global)~~ | **Closed in Batch 2 (2026-05-05).** Subsumed by PR #11's M2 fix — `claim!/0` / `release!/0` enforce `async: false` at runtime via an owner-pid registration. The named table stays (cross-process LV→test boundary requires it) but concurrent access raises loudly. |

## Batch 2 — close all deferred findings 2026-05-05

Issue #13 (per-template language picker) bundled the residual
deferred decisions from Batch 1 into the same PR. Each was
closed mechanically:

### §1.2 — Boot vs lazy fallback symmetry restored

`GoogleDocsClient.migrate_legacy_connection/1` (the lazy path)
no longer falls back to picking the first connection of any name
when the exact `provider:name` match fails. Pre-fix, an admin
with `"google"` stored in `document_creator_settings` AND a
multi-account install (`google:work` + `google:personal`) would
have one of those connections silently chosen. Post-fix, the
lookup either finds an exact match (cleanly migrates the
setting to that uuid) or fails loudly (clears the setting,
admin sees the integration picker).

Both paths now also emit `integration.legacy_migrated` activity
rows on BOTH success and failure (with `migration_kind=
reference_migration_failed` on the failure side). The boot path
in `phoenix_kit_document_creator.ex:resolve_and_persist/1`
gained the failure-side activity log too. Symmetry rule:
nothing the legacy migration does is unobservable in the audit
feed.

### §1.3 — Uuid-strict already_migrated?

`already_migrated?/0` now prefers
`Integrations.find_uuid_by_provider_name/1` (core 1.7.105+)
over the legacy `get_integration("provider:name")` shim. Runtime
guard via `function_exported?/3`; the `apply/3` call dodges the
compile-time "undefined function" warning on older cores. The
fallback arm can be removed once core 1.7.105 is the floor in
`mix.exs`.

### §1.9 — StubIntegrations claim/release

The PR #11 M2 fix landed in this same commit batch and
subsumes §1.9 — `claim!/0` registers the calling pid as the ETS
table's owner; concurrent calls from a different live pid raise
`:concurrent_stub_use`. Tests using the stub must already
declare `async: false`; the runtime check makes accidental
concurrent use impossible to miss instead of silently racing.

### Files touched (Batch 2)

| File | Change |
|------|--------|
| `lib/phoenix_kit_document_creator/google_docs_client.ex` | §1.2 (drop silent fallback + audit log on failure) |
| `lib/phoenix_kit_document_creator.ex` | §1.2 (audit log on boot-side failure) + §1.3 (find_uuid_by_provider_name preference) |
| `test/support/stub_integrations.ex` | §1.9 (claim/release) — landed under PR #11 M2 |
| `test/integration/active_integration_test.exs` | Updated two pre-existing tests to match new symmetric behavior; new test for the "no exact match" failure branch |

### Verification (Batch 2)

- `mix precommit` clean
- `mix test` — 414 tests, 0 failures, 4 excluded; 5/5 random
  seeds stable
- Browser smoke on `phoenix_kit_parent` confirms the symmetric
  behavior: bare `"google"` setting with no `"default"`-named
  connection clears the setting and renders the "Google Account
  Not Connected" empty state, instead of silently picking a
  random connection.

## Verification

- `mix compile` — clean (two pre-existing warnings about
  `migrate_legacy/0` callback and `find_uuid_by_provider_name/1` are
  Hex-shape drift unchanged from PR #12)
- `mix format --check-formatted` — clean
- `mix test` — 187 tests, 0 failures (207 excluded — adds one to
  PR #12's 206 because of the new §1.1 test)
