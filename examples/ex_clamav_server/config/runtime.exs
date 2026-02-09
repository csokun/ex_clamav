import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :ex_clamav_server, ExClamavServer.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    ssl: System.get_env("DATABASE_SSL", "false") == "true",
    socket_options: if(System.get_env("DATABASE_IPV6", "false") == "true", do: [:inet6], else: [])

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ex_clamav_server, ExClamavServer.Endpoint,
    port: port

  database_path = System.get_env("CLAMAV_DB_PATH") || "/var/lib/clamav"
  upload_path = System.get_env("UPLOAD_PATH") || "/data/uploads"

  config :ex_clamav_server, ExClamavServer.Scanner,
    database_path: database_path,
    upload_path: upload_path

  update_interval_hours =
    System.get_env("CLAMAV_UPDATE_INTERVAL_HOURS") || "1"

  interval_ms = String.to_integer(update_interval_hours) * 3_600_000

  config :ex_clamav_server, ExClamavServer.DefinitionSync,
    interval_ms: interval_ms,
    run_on_start: System.get_env("CLAMAV_UPDATE_ON_START", "true") == "true",
    database_path: database_path,
    freshclam_config: System.get_env("FRESHCLAM_CONFIG")

  # Configure log level at runtime
  log_level =
    case System.get_env("LOG_LEVEL", "info") do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end

  config :logger, level: log_level
end
