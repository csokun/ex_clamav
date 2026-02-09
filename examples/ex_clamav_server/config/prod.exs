import Config

# Production database is configured via runtime.exs using environment variables.
# Only set compile-time defaults here.

config :ex_clamav_server, ExClamavServer.Repo,
  pool_size: 20

config :ex_clamav_server, ExClamavServer.Endpoint,
  port: 4000

config :ex_clamav_server, ExClamavServer.Scanner,
  database_path: "/var/lib/clamav",
  upload_path: "/data/uploads"

config :ex_clamav_server, ExClamavServer.DefinitionSync,
  interval_ms: :timer.hours(1),
  run_on_start: true

config :logger, level: :info
