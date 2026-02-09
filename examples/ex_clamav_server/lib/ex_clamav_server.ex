defmodule ExClamavServer do
  @moduledoc """
  ExClamavServer - A scalable REST API server for virus scanning powered by ExClamav.

  This application provides HTTP endpoints for uploading files for virus scanning,
  checking scan status, and monitoring service health. It is designed to run as
  multiple instances behind a load balancer with shared PostgreSQL state and
  shared filesystem volumes for uploads and virus definitions.

  ## Architecture

  - **PostgreSQL** — shared scan job state across all instances
  - **Shared volume (EFS)** — uploaded files and ClamAV virus definitions
  - **ExClamav NIF** — native ClamAV engine per instance for scanning
  - **DefinitionUpdater** — periodic `freshclam` execution with engine hot-reload

  ## Endpoints

  - `POST /upload` — upload a file for scanning, returns a `reference_id`
  - `GET /upload/:reference_id` — query scan status and result
  - `GET /health` — service health, virus DB version, uptime
  """

  @doc """
  Returns the application start time (set during Application.start).
  """
  def start_time do
    Application.get_env(:ex_clamav_server, :start_time)
  end

  @doc """
  Returns uptime in seconds since the application started.
  """
  def uptime_seconds do
    case start_time() do
      nil -> 0
      %DateTime{} = t -> DateTime.diff(DateTime.utc_now(), t, :second)
    end
  end

  @doc """
  Returns the configured upload path, ensuring it exists.
  """
  def upload_path do
    path =
      Application.get_env(:ex_clamav_server, ExClamavServer.Scanner)[:upload_path] ||
        "/tmp/ex_clamav_server/uploads"

    File.mkdir_p!(path)
    path
  end

  @doc """
  Returns the configured ClamAV database path.
  """
  def database_path do
    Application.get_env(:ex_clamav_server, ExClamavServer.Scanner)[:database_path] ||
      "/var/lib/clamav"
  end
end
