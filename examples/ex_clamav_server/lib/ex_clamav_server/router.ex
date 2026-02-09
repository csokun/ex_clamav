defmodule ExClamavServer.Router do
  @moduledoc """
  HTTP router for the ExClamavServer REST API.

  ## Endpoints

  - `POST /upload` — Upload a file for virus scanning. Returns a `reference_id`.
  - `GET /upload/:reference_id` — Query the scan status for a given reference ID.
  - `GET /health` — Service health check with virus DB version and uptime.

  ## Upload Format

  Files should be uploaded as `multipart/form-data` with a field named `file`.

  ## Response Format

  All responses are JSON with the following structure:

      # Success
      {"status": "ok", "data": { ... }}

      # Error
      {"status": "error", "error": {"code": "not_found", "message": "..."}}
  """

  use Plug.Router

  require Logger

  alias ExClamavServer.ScanJob
  alias ExClamavServer.UploadHandler

  # ---------------------------------------------------------------------------
  # Plug pipeline
  # ---------------------------------------------------------------------------

  plug Plug.RequestId
  plug Plug.Logger, log: :info

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 100 * 1024 * 1024

  plug :match
  plug :dispatch

  # ---------------------------------------------------------------------------
  # POST /upload
  # ---------------------------------------------------------------------------

  post "/upload" do
    upload = conn.params["file"]

    case UploadHandler.handle_upload(upload) do
      {:ok, response_data} ->
        conn
        |> json_response(202, %{status: "ok", data: response_data})

      {:error, {:bad_request, message}} ->
        conn
        |> json_error(400, "bad_request", message)

      {:error, {:payload_too_large, message}} ->
        conn
        |> json_error(413, "payload_too_large", message)

      {:error, {:internal_error, message}} ->
        Logger.error("Upload failed: #{message}")

        conn
        |> json_error(500, "internal_error", "An internal error occurred while processing the upload.")
    end
  end

  # ---------------------------------------------------------------------------
  # GET /upload/:reference_id
  # ---------------------------------------------------------------------------

  get "/upload/:reference_id" do
    case ScanJob.get_by_reference_id(reference_id) do
      nil ->
        conn
        |> json_error(404, "not_found", "Scan job not found for reference_id: #{reference_id}")

      %ScanJob{} = job ->
        conn
        |> json_response(200, %{status: "ok", data: ScanJob.to_api_response(job)})
    end
  end

  # ---------------------------------------------------------------------------
  # GET /health
  # ---------------------------------------------------------------------------

  get "/health" do
    health_data = build_health_response()

    status_code = if health_data.healthy, do: 200, else: 503

    conn
    |> json_response(status_code, %{status: "ok", data: health_data})
  end

  # ---------------------------------------------------------------------------
  # Catch-all
  # ---------------------------------------------------------------------------

  match _ do
    conn
    |> json_error(404, "not_found", "The requested endpoint does not exist.")
  end

  # ---------------------------------------------------------------------------
  # Health check helpers
  # ---------------------------------------------------------------------------

  defp build_health_response do
    uptime_seconds = ExClamavServer.uptime_seconds()

    {db_version, engine_healthy} = get_engine_info()

    updater_status = get_updater_status()

    %{
      healthy: engine_healthy,
      uptime_seconds: uptime_seconds,
      uptime_human: format_uptime(uptime_seconds),
      clamav: %{
        library_version: safe_clamav_version(),
        database_version: db_version,
        last_definition_update: updater_status[:last_update_at],
        last_update_result: format_update_result(updater_status[:last_result]),
        update_interval_seconds: div(updater_status[:interval_ms] || 3_600_000, 1000)
      },
      instance: ExClamavServer.ScanWorker.instance_identifier()
    }
  end

  defp get_engine_info do
    # Check engine liveness by attempting a no-op scan (empty buffer).
    # The engine is considered healthy if it responds at all, regardless of
    # the scan result (an empty buffer will likely return :clean or an error).
    try do
      _result = ExClamav.ClamavGenServer.scan_buffer(ExClamavServer.ScanEngine, "ping")

      # The database version is tracked by the DefinitionUpdater's fingerprint.
      # We extract it from the updater status instead of calling into the engine
      # directly, because ClamavGenServer doesn't expose a :get_database_version call.
      db_version = get_db_version_from_updater()
      {db_version, true}
    catch
      :exit, _ -> {"unavailable", false}
    end
  end

  defp get_db_version_from_updater do
    try do
      status = ExClamav.DefinitionUpdater.status(ExClamavServer.DefinitionUpdater)

      case status do
        %{fingerprint: fingerprint} when is_list(fingerprint) and fingerprint != [] ->
          # Return the fingerprint summary as the "version" — it contains the
          # .cvd/.cld filenames, sizes, and mtimes which uniquely identify the DB.
          fingerprint
          |> Enum.map(fn {name, _size, _mtime} -> name end)
          |> Enum.join(", ")

        _ ->
          "unknown"
      end
    catch
      :exit, _ -> "unknown"
    end
  end

  defp safe_clamav_version do
    try do
      case ExClamav.version() do
        version when is_list(version) -> List.to_string(version)
        version when is_binary(version) -> version
        other -> inspect(other)
      end
    rescue
      _ -> "unavailable"
    end
  end

  defp get_updater_status do
    try do
      ExClamav.DefinitionUpdater.status(ExClamavServer.DefinitionUpdater)
    catch
      :exit, _ ->
        %{
          last_update_at: nil,
          last_result: nil,
          interval_ms: 3_600_000
        }
    end
  end

  defp format_update_result(nil), do: nil
  defp format_update_result(:updated), do: "updated"
  defp format_update_result(:up_to_date), do: "up_to_date"
  defp format_update_result({:error, reason}), do: "error: #{reason}"
  defp format_update_result(other), do: inspect(other)

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_uptime(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}h #{minutes}m #{secs}s"
  end

  # ---------------------------------------------------------------------------
  # JSON response helpers
  # ---------------------------------------------------------------------------

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, code, message) do
    body = %{
      status: "error",
      error: %{
        code: code,
        message: message
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
