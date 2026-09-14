defmodule PhoenixKitDocumentCreator.Test.LiveDatabaseGuard do
  @moduledoc """
  Refuses to boot the suite against a development or production database.

  `config/test.exs` honors `PGDATABASE` — precisely so the suite can target an
  already-provisioned database when the running role lacks `CREATEDB`. The
  flip side is that a `PGDATABASE` exported for a dev shell (conventionally
  `<app>_dev`) silently becomes the test database, and `test_helper.exs` then
  runs core's migrations and this module's chain against it before a single
  test is sandboxed.

  The refusal is by name, on Phoenix's own naming convention: a database
  ending in `_dev` or `_prod` is never a test database. Two alternatives were
  rejected:

    * A `schema_migrations` ownership marker (the `SchemaOwnerGuard` pattern
      used elsewhere in the ecosystem) only recognises a database some
      guard-carrying package has already stamped. A dev database built by a
      plain `mix ecto.migrate` carries no marker and would pass.
    * Requiring `test` in the name would refuse legitimate pre-provisioned
      databases, such as a CI service container's default `postgres`.
  """

  @non_test_suffixes ~w(_dev _prod)

  defmodule LiveDatabaseError do
    defexception [:message]
  end

  @doc """
  Raises `LiveDatabaseError` if `database` ends in `_dev` or `_prod`.

  Takes the already-resolved name (what `config/test.exs` put in
  `Application.get_env/2`), not `PGDATABASE` itself — the config file's own
  fallback-when-unset logic is the single source of truth for what the suite
  will actually connect to, and duplicating it here would drift the moment
  either copy changed.
  """
  @spec check!(String.t()) :: :ok
  def check!(database) when is_binary(database) do
    if String.ends_with?(database, @non_test_suffixes) do
      raise LiveDatabaseError,
        message: """
        Test database resolved to #{inspect(database)}, which by its name is a \
        development or production database — the test boot would run \
        migrations against it. PGDATABASE is honored by config/test.exs; \
        unset it, or point it at a dedicated test database instead.\
        """
    else
      :ok
    end
  end
end
