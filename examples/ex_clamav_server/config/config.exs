import Config

config :ex_clamav_server,
  ecto_repos: [ExClamavServer.Repo]

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
  interval_ms: :timer.hours(1),
  run_on_start: true

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :reference_id]

import_config "#{config_env()}.exs"
