import Config

# Skip ClamAV engine, freshclam, and Bandit in test mode.
# Only the Repo and Task.Supervisor are started.
config :ex_clamav_server, :skip_clamav, true

# Test database configuration
config :ex_clamav_server, ExClamavServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ex_clamav_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ex_clamav_server, ExClamavServer.Endpoint,
  port: 4002

config :ex_clamav_server, ExClamavServer.Scanner,
  database_path: "/var/lib/clamav",
  upload_path: System.tmp_dir!() |> Path.join("ex_clamav_server_test/uploads")

config :ex_clamav_server, ExClamavServer.DefinitionSync,
  interval_ms: :timer.hours(24),
  run_on_start: false

config :logger, level: :warning
