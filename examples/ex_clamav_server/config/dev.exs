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

# Use a user-writable path for the ClamAV database in development.
# The application will automatically seed this directory with .cvd/.cld files
# from well-known locations (/var/lib/clamav, /tmp/clamav) on first startup.
config :ex_clamav_server, ExClamavServer.Scanner,
  database_path: "/tmp/ex_clamav_server_db",
  upload_path: "/tmp/ex_clamav_server/uploads"

# freshclam configuration for development.
#
# NOTE: On systems with AppArmor (e.g., Ubuntu), freshclam is confined and can
# only read config files from /etc/clamav/ and /tmp/**. The application will
# automatically copy this config to /tmp/ex_clamav_server_freshclam.conf at
# startup so freshclam can access it regardless of the project's location.
config :ex_clamav_server, ExClamavServer.DefinitionSync,
  interval_ms: :timer.minutes(30),
  run_on_start: true,
  database_path: "/tmp/ex_clamav_server_db",
  freshclam_config: Path.expand("../priv/freshclam.conf", __DIR__)

config :logger, level: :debug
