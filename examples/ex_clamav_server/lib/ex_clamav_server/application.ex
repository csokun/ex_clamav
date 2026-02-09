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

  ## Development Notes

  On systems with AppArmor (e.g., Ubuntu), `freshclam` is restricted to reading
  config files from `/etc/clamav/` and `/tmp/`. This module automatically copies
  the project's `priv/freshclam.conf` to `/tmp/` at startup so that freshclam
  can access it regardless of the project's location on disk.

  Similarly, the ClamAV database directory must be writable by the current user
  for freshclam to update definitions. If the configured database path is not
  writable, a user-owned directory is created and seeded with existing `.cvd`/`.cld`
  files from well-known locations.
  """

  use Application

  require Logger

  @tmp_freshclam_config "/tmp/ex_clamav_server_freshclam.conf"

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

    # Prepare a writable database path (creates + seeds if needed)
    effective_db_path =
      Keyword.get(definition_sync_config, :database_path, database_path)
      |> prepare_database_path()

    # Prepare freshclam config in an AppArmor-accessible location (/tmp)
    effective_freshclam_config =
      prepare_freshclam_config(Keyword.get(definition_sync_config, :freshclam_config))

    Logger.info("Starting ExClamavServer on port #{port}")

    [
      # ClamAV virus definition updater (runs freshclam periodically)
      {ExClamav.DefinitionUpdater,
       [
         name: ExClamavServer.DefinitionUpdater,
         database_path: effective_db_path,
         interval_ms: Keyword.get(definition_sync_config, :interval_ms, :timer.hours(1)),
         run_on_start: Keyword.get(definition_sync_config, :run_on_start, true),
         freshclam_config: effective_freshclam_config
       ]},

      # ClamAV scan engine (auto-reloads when definitions update)
      {ExClamav.ClamavGenServer,
       [
         name: ExClamavServer.ScanEngine,
         database_path: effective_db_path,
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

  # ---------------------------------------------------------------------------
  # Freshclam config preparation
  # ---------------------------------------------------------------------------

  @doc false
  @spec prepare_freshclam_config(String.t() | nil) :: String.t() | nil
  defp prepare_freshclam_config(nil), do: nil

  defp prepare_freshclam_config(source_path) do
    # On systems with AppArmor (Ubuntu, etc.), freshclam is confined to reading
    # config files from /etc/clamav/ and /tmp/**. If the source config is in a
    # restricted location (e.g., under /home/), copy it to /tmp so freshclam
    # can access it.
    if String.starts_with?(source_path, "/tmp/") or
         String.starts_with?(source_path, "/etc/clamav/") do
      Logger.debug("Freshclam config already in accessible location: #{source_path}")
      source_path
    else
      case File.read(source_path) do
        {:ok, content} ->
          case File.write(@tmp_freshclam_config, content) do
            :ok ->
              Logger.info(
                "Copied freshclam config to #{@tmp_freshclam_config} (AppArmor compatibility)"
              )

              @tmp_freshclam_config

            {:error, reason} ->
              Logger.warning(
                "Failed to copy freshclam config to #{@tmp_freshclam_config}: #{inspect(reason)}. " <>
                  "Falling back to original path (may fail under AppArmor)."
              )

              source_path
          end

        {:error, reason} ->
          Logger.warning(
            "Failed to read freshclam config at #{source_path}: #{inspect(reason)}. " <>
              "freshclam will use its defaults."
          )

          nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Database path preparation
  # ---------------------------------------------------------------------------

  @doc false
  @spec prepare_database_path(String.t()) :: String.t()
  defp prepare_database_path(database_path) do
    # Ensure the database directory exists
    File.mkdir_p!(database_path)

    # Check if we can write to the directory by attempting to create a temp file
    test_file = Path.join(database_path, ".ex_clamav_server_write_test")

    case File.write(test_file, "") do
      :ok ->
        File.rm(test_file)
        maybe_seed_database(database_path)
        Logger.info("ClamAV database path is writable: #{database_path}")
        database_path

      {:error, _reason} ->
        # Directory is not writable (e.g., owned by clamav user).
        # Create a user-owned directory and seed it with existing DB files.
        fallback_path = Path.join(System.tmp_dir!(), "ex_clamav_server_db")
        Logger.warning("ClamAV database path #{database_path} is not writable by current user")
        Logger.info("Using writable fallback database path: #{fallback_path}")

        File.mkdir_p!(fallback_path)
        seed_database_from(fallback_path, database_path)
        maybe_seed_database(fallback_path)
        fallback_path
    end
  end

  # Seed the target database directory with .cvd/.cld files from a source directory
  defp seed_database_from(target_path, source_path) do
    target_has_db? =
      Path.wildcard(Path.join(target_path, "*.{cvd,cld}"))
      |> Enum.any?()

    if target_has_db? do
      Logger.debug("Database files already present in #{target_path}, skipping seed")
    else
      db_files = Path.wildcard(Path.join(source_path, "*.{cvd,cld}"))

      if db_files != [] do
        Logger.info("Seeding #{target_path} with #{length(db_files)} database file(s) from #{source_path}")

        Enum.each(db_files, fn src_file ->
          dest_file = Path.join(target_path, Path.basename(src_file))

          case File.cp(src_file, dest_file) do
            :ok ->
              Logger.debug("Copied #{Path.basename(src_file)} to #{target_path}")

            {:error, reason} ->
              Logger.warning("Failed to copy #{src_file} to #{dest_file}: #{inspect(reason)}")
          end
        end)
      else
        Logger.debug("No database files found in #{source_path} to seed from")
      end
    end
  end

  # Try to seed from well-known ClamAV database locations if the target is empty
  defp maybe_seed_database(target_path) do
    target_has_db? =
      Path.wildcard(Path.join(target_path, "*.{cvd,cld}"))
      |> Enum.any?()

    unless target_has_db? do
      well_known_paths = [
        "/var/lib/clamav",
        "/tmp/clamav",
        "/usr/local/share/clamav"
      ]

      source =
        Enum.find(well_known_paths, fn path ->
          path != target_path and
            File.dir?(path) and
            Path.wildcard(Path.join(path, "*.{cvd,cld}")) != []
        end)

      if source do
        seed_database_from(target_path, source)
      else
        Logger.warning(
          "No existing ClamAV database files found. " <>
            "freshclam will download them on first run (this may take a while)."
        )
      end
    end
  end
end
