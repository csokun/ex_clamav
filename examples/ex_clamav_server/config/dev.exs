import Config

# Development-specific database configuration
config :ex_clamav_server, ExClamavServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ex_clamav_server_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ex_clamav_server, ExClamavServer.Endpoint,
  port: 4000

config :ex_clamav_server, ExClamavServer.Scanner,
  database_path: "/var/lib/clamav",
  upload_path: "/tmp/ex_clamav_server/uploads"

config :ex_clamav_server, ExClamavServer.DefinitionSync,
  interval_ms: :timer.minutes(30),
  run_on_start: true

config :logger, level: :debug
