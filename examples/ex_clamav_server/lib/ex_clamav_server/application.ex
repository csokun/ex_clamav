defmodule ExClamavServer.Application do
  @moduledoc """
  OTP Application for ExClamavServer.

  Starts the supervision tree including:
  - Ecto Repo (PostgreSQL)
  - ClamAV DefinitionUpdater (periodic freshclam)
  - ClamAV GenServer (scan engine with auto-reload)
  - ScanWorker task supervisor (async scan processing)
  - Bandit HTTP server

  ## Test Mode

  Set `config :ex_clamav_server, :skip_clamav, true` to start only the Repo
  and Task.Supervisor (no ClamAV engine, no freshclam, no HTTP server).
  This is the default in `config/test.exs`.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Record application start time for uptime reporting
    Application.put_env(:ex_clamav_server, :start_time, DateTime.utc_now())

    # Ensure upload directory exists
    upload_path = ExClamavServer.upload_path()
    File.mkdir_p!(upload_path)
    Logger.info("Upload path: #{upload_path}")

    database_path = ExClamavServer.database_path()
    Logger.info("ClamAV database path: #{database_path}")

    skip_clamav? = Application.get_env(:ex_clamav_server, :skip_clamav, false)

    children =
      [
        # PostgreSQL connection pool
        ExClamavServer.Repo,

        # Task supervisor for async scan jobs
        {Task.Supervisor, name: ExClamavServer.ScanTaskSupervisor}
      ] ++ runtime_children(skip_clamav?, database_path)

    opts = [strategy: :rest_for_one, name: ExClamavServer.Supervisor]

    Logger.info("Starting ExClamavServer#{if skip_clamav?, do: " (skip_clamav mode)"}")

    Supervisor.start_link(children, opts)
  end

  # ---------------------------------------------------------------------------
  # Child specs
  # ---------------------------------------------------------------------------

  defp runtime_children(true = _skip?, _database_path), do: []

  defp runtime_children(false = _skip?, database_path) do
    definition_sync_config =
      Application.get_env(:ex_clamav_server, ExClamavServer.DefinitionSync, [])

    port =
      Application.get_env(:ex_clamav_server, ExClamavServer.Endpoint, [])
      |> Keyword.get(:port, 4000)

    Logger.info("Starting ExClamavServer on port #{port}")

    [
      # ClamAV virus definition updater (runs freshclam periodically)
      {ExClamav.DefinitionUpdater,
       [
         name: ExClamavServer.DefinitionUpdater,
         database_path: Keyword.get(definition_sync_config, :database_path, database_path),
         interval_ms: Keyword.get(definition_sync_config, :interval_ms, :timer.hours(1)),
         run_on_start: Keyword.get(definition_sync_config, :run_on_start, true),
         freshclam_config: Keyword.get(definition_sync_config, :freshclam_config)
       ]},

      # ClamAV scan engine (auto-reloads when definitions update)
      {ExClamav.ClamavGenServer,
       [
         name: ExClamavServer.ScanEngine,
         database_path: database_path,
         auto_reload: true,
         updater: ExClamavServer.DefinitionUpdater
       ]},

      # HTTP server
      {Bandit,
       plug: ExClamavServer.Router,
       port: port,
       scheme: :http}
    ]
  end
end
