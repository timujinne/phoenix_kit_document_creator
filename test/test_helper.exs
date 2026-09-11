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

# S014: refuse before anything else touches the database — see
# PhoenixKitDocumentCreator.Test.LiveDatabaseGuard's moduledoc for why this
# exists alongside (not instead of) the external `pk-test` wrapper.
PhoenixKitDocumentCreator.Test.LiveDatabaseGuard.check!(db_name)

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above.
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

      # The module-owned chain (V1: documents.project_uuid), version-keyed
      # so a bump re-applies — the projects-repo pattern.
      Ecto.Migrator.run(
        TestRepo,
        [
          {PhoenixKitDocumentCreator.Migrations.Schema.current_version(),
           PhoenixKitDocumentCreator.Test.SchemaMigration}
        ],
        :up,
        all: true,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
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
# `:requires_unreleased_core` used to be excluded by default: the tagged
# tests exercise `PhoenixKit.Integrations.add_connection/3`'s strict-UUID
# return shape (`{:ok, %{uuid: _}}`), which at the time existed only in
# unpublished core, so a standalone Hex `~> 1.7` run emitted shape
# mismatches. The comment said to drop the exclusion "once the matching
# core version is published" — that happened at core 2.0, and this package
# has pinned `{:phoenix_kit, "~> 2.0"}` since. Every version the pin can
# resolve carries the shape, so the exclusion had stopped protecting
# anything and was simply hiding four passing tests from every run.
exclude = if repo_available, do: [], else: [:integration]

# `:requires_phoenix_kit_i18n_api` gates tests that use
# `PhoenixKit.Dashboard.Tab.localized_label/1` (the gettext_backend
# API introduced by phoenix_kit#522). Standalone runs against a Hex
# `phoenix_kit` that pre-dates the API would crash with
# `UndefinedFunctionError`; the conditional skip below lets the suite
# stay green until the consumer upgrades.
exclude =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
    exclude
  else
    require Logger

    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
        "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships the gettext_backend API."
    )

    [:requires_phoenix_kit_i18n_api | exclude]
  end

ExUnit.start(exclude: exclude)
