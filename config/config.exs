import Config

config :ueberauth, Ueberauth, providers: %{}

config :phoenix_kit,
  parent_app_name: :phoenix_kit_document_creator,
  parent_module: PhoenixKitDocumentCreator,
  url_prefix: "/phoenix_kit"

# Configure rate limiting with Hammer
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       # Cleanup expired rate limit buckets every 60 seconds
       expiry_ms: 60_000,
       # Cleanup interval (1 minute)
       cleanup_interval_ms: 60_000
     ]}

# Configure rate limits for authentication endpoints
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  # Login: 5 attempts per minute per email
  login_limit: 5,
  login_window_ms: 60_000,
  # Magic link: 3 requests per 5 minutes per email
  magic_link_limit: 3,
  magic_link_window_ms: 300_000,
  # Password reset: 3 requests per 5 minutes per email
  password_reset_limit: 3,
  password_reset_window_ms: 300_000,
  # Registration: 3 attempts per hour per email
  registration_limit: 3,
  registration_window_ms: 3_600_000,
  # Registration IP: 10 attempts per hour per IP
  registration_ip_limit: 10,
  registration_ip_window_ms: 3_600_000

# Configure Oban for PhoenixKit background jobs (dev / prod standalone only).
# Tests must not start Oban here: `PhoenixKitDocumentCreator.Repo` is not a
# real module (host apps supply their own repo via their own Oban config),
# so loading it in :test would crash `Application.start/2` before any test
# can run. Host apps override the entire `:phoenix_kit_document_creator,
# Oban` keyword to their own repo, so this block is irrelevant when this
# library runs as a dependency.
if config_env() != :test do
  config :phoenix_kit_document_creator, Oban,
    repo: PhoenixKitDocumentCreator.Repo,
    queues: [
      default: 10,
      file_processing: 20,
      posts: 10,
      scheduled_jobs: 1,
      sitemap: 5,
      newsletters_delivery: 10
    ],
    plugins: [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
      {Oban.Plugins.Cron,
       crontab: [
         {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
         {"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob},
         {"0 4 * * *", PhoenixKit.Notifications.PruneWorker}
       ]}
    ]
end

if config_env() == :test do
  import_config "test.exs"
end
