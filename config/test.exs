import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_document_creator_test
config :phoenix_kit_document_creator, ecto_repos: [PhoenixKitDocumentCreator.Test.Repo]

config :phoenix_kit_document_creator, PhoenixKitDocumentCreator.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database:
    System.get_env(
      "PGDATABASE",
      "phoenix_kit_document_creator_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitDocumentCreator.Test.Repo

# Pin `PhoenixKit.Config.url_prefix/0` to "/" so route helpers don't try
# to read the prefix from a missing settings table during LV mounts.
config :phoenix_kit, url_prefix: "/"

# Use the test PubSub server started by test_helper.exs so taxonomy
# broadcasts don't crash with "unknown registry" errors.
config :phoenix_kit, pubsub: PhoenixKit.PubSub

# Test endpoint so `Phoenix.LiveViewTest` can drive `DocumentsLive` /
# `GoogleOAuthSettingsLive` through `live/2`. Not what the host app
# uses in production — this is an ad-hoc shim for the LV smoke tests.
config :phoenix_kit_document_creator, PhoenixKitDocumentCreator.Test.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+W4z6L3kQ7rRnJW3VbZkV2kqKmF5LrPoT6qDyPzYx9GdN3TfV1eA1CxRn+8wCSdh",
  server: false,
  live_view: [signing_salt: "doc-creator-test-lv-salt"]

config :logger, level: :warning
