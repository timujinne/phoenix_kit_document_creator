defmodule PhoenixKitDocumentCreator.LiveDatabaseGuardWiringTest do
  @moduledoc """
  `PhoenixKitDocumentCreator.Test.LiveDatabaseGuardTest` calls `check!/1`
  directly — it proves the logic is correct, not that `test_helper.exs`
  actually calls it. Deleting the call from `test_helper.exs` leaves that
  test green; it would prove the module still works, not that anything still
  protects a real `mix test` run.

  This test runs `test_helper.exs` for real, as a genuine `mix test`
  subprocess, with `PGDATABASE` set to a name the guard exists to refuse. It
  never lets that subprocess reach a real Postgres server, though — `PGHOST`
  points at an address nothing is listening on, so whatever the guard does or
  doesn't do, the subprocess can never touch a database of that name.

  Verified by mutation that this tells a correct refusal apart from a cut
  wiring call: with the `check!/1` call commented out, the subprocess does NOT
  fail — `test_helper.exs`'s own "can't reach the database" fallback catches
  the bogus host, prints its own warning, excludes `:integration`, and exits 0
  normally, since the targeted test file needs no database at all. A correct
  refusal looks categorically different: a nonzero exit and the guard's own
  `LiveDatabaseError` in the output, before that fallback ever runs. This test
  asserts exactly that pair (exit code, exception name) rather than looking
  for a connection-failure message that a cut wiring call turns out not to
  produce.
  """

  use ExUnit.Case, async: true

  # A loopback port nothing binds — `ECONNREFUSED` is near-instant, unlike a
  # routed-but-silent address (which would hang for a connect timeout instead
  # of failing fast).
  @unreachable_host "127.0.0.1"
  @unreachable_port "1"

  for live_db <- ~w(phoenix_kit_dev my_app_prod) do
    test "refuses before any connection attempt when PGDATABASE=#{live_db}" do
      env = [
        {"PGDATABASE", unquote(live_db)},
        {"PGHOST", @unreachable_host},
        {"PGPORT", @unreachable_port},
        {"PGUSER", "postgres"},
        {"PGPASSWORD", "postgres"},
        {"MIX_ENV", "test"}
      ]

      # One fast, unrelated test file — test_helper.exs's boot code runs
      # unconditionally as part of loading the suite, regardless of which
      # test is targeted.
      {output, exit_code} =
        System.cmd("mix", ["test", "test/live_database_guard_test.exs"],
          env: env,
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      refute exit_code == 0,
             "a boot with PGDATABASE=#{unquote(live_db)} must refuse, not succeed:\n#{output}"

      # Matches the raised-exception banner specifically
      # (`** (...LiveDatabaseError) ...`), not a bare "LiveDatabaseError"
      # substring — the module and exception name alone could show up in an
      # unrelated stack trace or log line without the guard actually having
      # fired, so anchoring on the raised-exception banner is what makes
      # this a trustworthy check.
      assert output =~
               "** (PhoenixKitDocumentCreator.Test.LiveDatabaseGuard.LiveDatabaseError)",
             "process failed, but not with the guard's own exception — some other crash " <>
               "reached this nonzero exit instead:\n#{output}"

      assert output =~ unquote(live_db),
             "refusal happened but didn't name the actual database, not the legible " <>
               "message the guard promises:\n#{output}"

      # Proves the guard runs BEFORE anything else touches the database, not
      # merely that it runs somewhere in the boot. Verified by mutation:
      # moving the `check!/1` call below the `PostgresPreflight` block in
      # `test_helper.exs` left this test's earlier assertions green (the
      # guard still fires, just too late) while the preflight's own
      # connection-refused text showed up ahead of the guard's banner in the
      # output. These refutes catch that: they fail if the preflight (or its
      # unreachable-database fallback) got a chance to run first. The first
      # string is core's wording, so a core rewording would quietly weaken
      # that one refute — not break the test.
      refute output =~ "No PostgreSQL server answered",
             "the preflight attempted a connection before the guard refused:\n#{output}"

      refute output =~ "Cannot reach test database",
             "test_helper's unreachable-database fallback ran before the guard refused:\n#{output}"

      refute output =~ "Could not start the test database",
             "test_helper's repo-start fallback ran before the guard refused:\n#{output}"
    end
  end

  test "an isolated test database name is not refused — the guard does not block a real run" do
    # No PGHOST/PGUSER/PGPASSWORD overrides here on purpose: the subprocess
    # inherits this run's ambient connection settings, so this tracked file
    # never needs to know a password or a machine-specific host. The database
    # name is the one this run already resolved (PGDATABASE, or the default
    # with its MIX_TEST_PARTITION suffix), so the subprocess boots against the
    # same database the parent is using rather than a partition-less default.
    database =
      Application.fetch_env!(:phoenix_kit_document_creator, PhoenixKitDocumentCreator.Test.Repo)[
        :database
      ]

    {output, exit_code} =
      System.cmd("mix", ["test", "test/live_database_guard_test.exs"],
        env: [{"PGDATABASE", database}],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert exit_code == 0,
           "a boot against the real isolated test database must succeed, not be blocked " <>
             "by the live-database guard:\n#{output}"

    refute output =~ "** (PhoenixKitDocumentCreator.Test.LiveDatabaseGuard.LiveDatabaseError)",
           "the guard fired on a database it must not refuse:\n#{output}"
  end
end
