# PR #63 — Compile on Erlang/OTP 28 (core 2.62.2, floor 2.43.0); stop re-running the legacy credentials migration on every boot

**Author:** Dmitri Don · **Reviewer:** Claude · **Status:** merged

Raises the `:phoenix_kit` floor to 2.43.0 (first core compiling on OTP 28), moves
the lock to 2.62.2, drops the `function_exported?`/`apply/3` compat shims around
`Integrations.find_uuid_by_provider_name/1`, fixes `already_migrated?/0`, and
adapts the test setup to core's locale/prefix settings.

## Verified

- **The `already_migrated?/0` fix is real.** The old code did
  `apply(Integrations, :find_uuid_by_provider_name, [key]) |> is_binary()`, but
  the function returns `{:ok, uuid}` / `{:error, _}`, so `is_binary/1` was always
  `false` and the short-circuit never fired. The new `match?({:ok, uuid} when
  is_binary(uuid), …)` matches the spec in core. The test now asserts
  `credentials_migration == :already_migrated`, so it would have caught this.
- The `:persistent_term` key in `test_helper.exs` matches core's
  `@url_prefix_cache_key {PhoenixKit.Config, :url_prefix}`; the old atom key was
  silently ignored.
- Floor/`@must_admit`/`@must_reject` in `core_pin_conformance_test.exs` stay
  consistent with `mix.exs` and AGENTS.md.
- `Paths.index()` replaces a hardcoded `"/admin/document-creator"` fallback,
  matching the "never hardcode a path" convention.

## Findings

### NITPICK — comments describing the removed compat layer were left behind
`migrate_legacy/0` still said Hex `~> 1.7` lacks the callback (so no `@impl`),
and `resolve_via_list_connections/1` still claimed to work "against any
phoenix_kit dep this module's mix.exs allows" because `find_uuid_by_provider_name/1`
"only exists in newer versions". Both are false at the 2.43 floor. **Fixed:**
comments rewritten and `@impl PhoenixKit.Module` added to `migrate_legacy/0`
(core's `use` declares it as an overridable callback).

### NITPICK — four `@tag :requires_unreleased_core` tags are dead
`test_helper.exs` documents that the exclusion was removed; the tags now mean
nothing and imply the tests are skipped. **Fixed:** removed.

### IMPROVEMENT - MEDIUM (not changed) — an empty pre-existing `google:default` suppresses the migration
`already_migrated?/0` is true for *any* system-scope `google:default` connection.
If an admin created that connection in the UI before boot while the legacy
`document_creator_google_oauth` row still holds credentials, the legacy
credentials are never imported and the plaintext row is never cleared. This is
the behaviour the PR's test locks in ("manual data intact"), and the previous
behaviour (overwrite) was arguably worse, so it was left as is; a narrower check
(skip only when the existing connection already has a `client_id`) is possible if
this surfaces in practice.

### NITPICK (not changed) — `resolve_via_list_connections/1` could use core's helper
It is now redundant with `find_uuid_by_provider_name/1` except for the bare
provider → `"default"` case. Left alone to keep this PR's follow-up small.

## Gate
See `FOLLOW_UP.md`.
