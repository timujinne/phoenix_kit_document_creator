# Test helper for PhoenixKitDocumentCreator test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_document_creator_test

alias PhoenixKitDocumentCreator.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect
db_config = Application.get_env(:phoenix_kit_document_creator, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_document_creator_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not on PATH (sandboxes, CI images without the client) —
    # fall through to the connect attempt instead of crashing the suite.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations —
      # same call the host app makes in production. Core's V40 creates
      # the `uuid-ossp` / `pgcrypto` extensions + `uuid_generate_v7()`
      # function; V03/V04 create `phoenix_kit_settings`; V86/V94/V110
      # create this module's `phoenix_kit_doc_*` tables; V90 creates
      # `phoenix_kit_activities`. No module-owned DDL.
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies
      # any newly-shipped Vxxx migrations on every boot by passing a
      # fresh wall-clock version to Ecto.Migrator. Replaces the
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`
      # pattern, which silently stopped re-applying once `0` was
      # recorded in `schema_migrations` — see
      # `dev_docs/migration_cleanup.md` for the staleness story.
      #
      # Standalone runs against Hex `phoenix_kit ~> 1.7` may fail at
      # boot if the published Hex version pre-dates `ensure_current/2`
      # itself or a column this module's schemas reference. CI greens
      # once core 1.7.105 publishes and `mix deps.update phoenix_kit`
      # bumps the lock. The canonical local test channel is via
      # `phoenix_kit_parent` (path-dep `override: true` resolves
      # `phoenix_kit` to the local checkout). See ~/.claude memory
      # `feedback_run_tests_via_parent.md`.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_document_creator, :test_repo_available, repo_available)

# Pin `PhoenixKit.Config.url_prefix/0` to "/" via :persistent_term so
# tests that boot before any settings read get a stable value (the LV
# routes use `Routes.path/1`, which reads this).
:persistent_term.put(:phoenix_kit_url_prefix, "/")

# Start minimal PhoenixKit services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# `Documents.fetch_thumbnails_async/2` and other async paths spawn
# children under `PhoenixKit.TaskSupervisor`. Without it started in
# the test VM, those paths fail with `:noproc` exits during LV tests.
case Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Start the LiveView test endpoint (used by LV smoke tests). The
# endpoint depends on PubSub, so spin that up first if it isn't already
# running.
{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, _} = Application.ensure_all_started(:phoenix_live_view)
{:ok, _} = PhoenixKitDocumentCreator.Test.Endpoint.start_link()

# `PhoenixKit.PubSubHelper.broadcast/2` derives its PubSub server from the
# host app's config; tests run without a parent app, so start the fallback
# `PhoenixKit.PubSub` registry to exercise broadcast paths (e.g. the
# `Documents.register_existing_document/2` pubsub option).
case Supervisor.start_link(
       [{Phoenix.PubSub, name: PhoenixKit.PubSub}],
       strategy: :one_for_one,
       name: PhoenixKitDocumentCreator.Test.PubSubSupervisor
     ) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
  {:error, reason} -> raise "PubSub test supervisor failed to start: #{inspect(reason)}"
end

# Exclude integration tests when DB is not available.
#
# `:requires_unreleased_core` is also excluded by default — those tests
# exercise `PhoenixKit.Integrations.add_connection/3`'s strict-UUID
# return shape (`{:ok, %{uuid: _}}`) which only exists in unpublished
# core. The canonical test channel for those is via `phoenix_kit_parent`
# (path-dep override). Standalone Hex `~> 1.7` runs would emit shape
# mismatches; opt-in via `mix test --include requires_unreleased_core`
# once the matching core version is published.
exclude = [:requires_unreleased_core]
exclude = if repo_available, do: exclude, else: [:integration | exclude]

ExUnit.start(exclude: exclude)
