# Claude Review — PR #47

Reviewed the merge diff (`31412ed..107ea88`, merged at `b8653ed`) against
`test/test_helper.exs`, `config/test.exs`, core's
`PhoenixKit.Migration.ensure_current/2` and
`PhoenixKit.TestSupport.PostgresPreflight`, following `elixir:elixir-thinking`
and this repo's `AGENTS.md`.

## Findings

### IMPROVEMENT - HIGH — the guard only protected one machine, and committed that machine's details upstream

`@known_live_databases` was `~w(phoenix_kit_dev decor_3d_print_dev
phoenixkit_hello_world_dev)`: the dev databases of one development container,
two of them belonging to unrelated projects. Any other contributor whose shell
exports `PGDATABASE=my_app_dev` was not protected, which is the exact failure
the PR exists to prevent. The moduledoc, test names and `test_helper.exs`
comment also carried a private session-tracker id (`S014`), a path on that
machine (`/root/bin/pk-test`) and repeated "this container" wording. The
moduledoc itself argues a repo shared with an external maintainer must not
carry machine-specific material.

The exact-match-over-substring decision was sound and is kept.

### IMPROVEMENT - MEDIUM — the non-refusal wiring test dropped `MIX_TEST_PARTITION`

`System.get_env("PGDATABASE", "phoenix_kit_document_creator_test")` rebuilt
`config/test.exs`'s fallback without the partition suffix. Under
`mix test --partitions N`, the subprocess booted against a different database
than its parent: it ran core's migrations there, or fell into the unreachable
fallback, and stayed green either way. That is the same duplicated fallback
logic the guard's own `@doc` warns against.

### BUG - MEDIUM (pre-existing, found during review) — HexDocs source links 404 since 0.8.0

`mix.exs` set `source_ref: "v#{@version}"`, with a comment saying tags are
v-prefixed. Tags were v-prefixed only through `v0.7.0`; `0.8.0`, `0.9.0`,
`0.9.1` and `0.9.2` are bare, and GitHub returns 404 for
`refs/tags/v0.9.2`. Every "view source" link in those HexDocs releases is
broken. `AGENTS.md`'s release step already says to tag in the newest existing
form, so `source_ref` and the tagging rule disagreed.

### NITPICK — one ordering refute is coupled to core's wording

`refute output =~ "No PostgreSQL server answered"` matches core's preflight
header text. If core rewords it, that refute passes vacuously and the
"guard runs before the preflight" check weakens without failing. There is no
wording-independent signal in the output. The other two refutes use this
repo's own strings.

### NITPICK — test module namespaces differ

The unit test is `PhoenixKitDocumentCreator.Test.LiveDatabaseGuardTest`, a
namespace otherwise used for support modules; the wiring test is
`PhoenixKitDocumentCreator.LiveDatabaseGuardWiringTest`. Cosmetic.

## Checked and fine

- **Ordering.** `check!/1` sits after `db_name` is resolved and before the
  `PostgresPreflight` block, so a refused name never reaches a connection
  attempt or `ensure_current/2`.
- **The wiring test really proves wiring.** Re-ran the mutation after the
  fixes: with the `check!/1` call commented out of `test_helper.exs`, both
  refusal cases fail (`3 tests, 2 failures`), and the subprocess exits 0
  through the unreachable fallback as the moduledoc describes.
- **No recursion.** Subprocesses target only `live_database_guard_test.exs`,
  never the wiring test itself.
- **Cost.** The subprocess boots add about 3–4 s to the suite (measured), with
  nothing stale to compile.
- **The refusal subprocess cannot reach a database.** `PGHOST=127.0.0.1`,
  `PGPORT=1` fails with `ECONNREFUSED` immediately.
- **Side effect of the non-refusal case.** It runs `ensure_current/2` against
  the shared test database, which records one extra `schema_migrations` row
  per suite run. That is harmless and matches what every normal boot does.
