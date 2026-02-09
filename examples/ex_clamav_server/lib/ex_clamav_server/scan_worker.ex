defmodule ExClamavServer.ScanWorker do
  @moduledoc """
  Async worker that processes scan jobs using the ClamAV engine.

  Each scan is executed as a supervised `Task` under `ExClamavServer.ScanTaskSupervisor`.
  The worker atomically claims pending jobs to prevent duplicate scanning across
  multiple instances, then delegates to the shared `ExClamav.ClamavGenServer` engine.

  ## Flow

  1. `scan_async/1` is called with a `ScanJob` struct.
  2. A supervised task is spawned to perform the scan.
  3. The task claims the job atomically (UPDATE ... WHERE status = 'pending').
  4. If the claim succeeds, the file is scanned via the NIF engine.
  5. The job status is updated to `completed` (with result) or `failed`.
  6. The uploaded file is cleaned up after scanning (optional, configurable).

  ## Instance Identity

  Each instance identifies itself using `node()` combined with the system hostname,
  so that the `scanned_by` field in the database can trace which pod handled the scan.
  """

  require Logger

  alias ExClamavServer.ScanJob

  @doc """
  Starts an async scan for the given job.

  Returns `{:ok, task_pid}` immediately. The scan runs in the background.
  """
  @spec scan_async(ScanJob.t()) :: {:ok, pid()}
  def scan_async(%ScanJob{} = job) do
    if Application.get_env(:ex_clamav_server, :skip_clamav, false) do
      # In test / skip_clamav mode the scan engine is not running.
      # Return a no-op pid so the caller still gets the expected tuple
      # shape without spawning a task that would crash immediately.
      {:ok, self()}
    else
      task =
        Task.Supervisor.async_nolink(
          ExClamavServer.ScanTaskSupervisor,
          fn -> perform_scan(job) end
        )

      {:ok, task.pid}
    end
  end

  @doc """
  Performs a synchronous scan of the given job.

  This is useful for testing or when you want to block until the scan completes.
  Returns `{:ok, updated_job}` or `{:error, reason}`.
  """
  @spec perform_scan(ScanJob.t()) :: {:ok, ScanJob.t()} | {:error, term()}
  def perform_scan(%ScanJob{} = job) do
    instance_id = instance_identifier()

    Logger.metadata(reference_id: job.reference_id)
    Logger.info("ScanWorker: claiming job #{job.reference_id} on #{instance_id}")

    case ScanJob.claim_for_scanning(job, instance_id) do
      {:ok, claimed_job} ->
        do_scan(claimed_job)

      {:error, :already_claimed} ->
        Logger.info("ScanWorker: job #{job.reference_id} already claimed by another instance")
        {:error, :already_claimed}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp do_scan(%ScanJob{} = job) do
    file_path = job.stored_path

    unless File.exists?(file_path) do
      Logger.error("ScanWorker: file not found at #{file_path}")
      {:ok, failed_job} = ScanJob.mark_failed(job, "File not found: #{file_path}")
      {:error, {:file_not_found, failed_job}}
    else
      Logger.info("ScanWorker: scanning file #{file_path} (#{job.file_size} bytes)")

      scan_start = System.monotonic_time(:millisecond)

      result =
        try do
          ExClamav.ClamavGenServer.scan_file(ExClamavServer.ScanEngine, file_path)
        rescue
          e ->
            Logger.error("ScanWorker: scan crashed — #{Exception.message(e)}")
            {:error, Exception.message(e)}
        end

      scan_duration_ms = System.monotonic_time(:millisecond) - scan_start
      Logger.info("ScanWorker: scan completed in #{scan_duration_ms}ms")

      case result do
        {:ok, :clean} ->
          Logger.info("ScanWorker: #{job.reference_id} — clean")
          {:ok, updated_job} = ScanJob.mark_completed(job, "clean")
          maybe_cleanup_file(file_path)
          {:ok, updated_job}

        {:virus, virus_name} ->
          Logger.warning("ScanWorker: #{job.reference_id} — virus found: #{virus_name}")
          {:ok, updated_job} = ScanJob.mark_completed(job, "virus_found", virus_name)
          cleanup_file(file_path)
          {:ok, updated_job}

        {:error, reason} ->
          error_msg = if is_binary(reason), do: reason, else: inspect(reason)
          Logger.error("ScanWorker: #{job.reference_id} — scan error: #{error_msg}")
          {:ok, failed_job} = ScanJob.mark_failed(job, error_msg)
          {:error, {:scan_error, failed_job}}
      end
    end
  end

  @doc """
  Returns a string identifying this instance.

  In Kubernetes, the hostname is typically the pod name (e.g., `ex-clamav-server-0`).
  """
  @spec instance_identifier() :: String.t()
  def instance_identifier do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    "#{hostname}@#{node()}"
  end

  # Clean up uploaded file after a clean scan (configurable behavior)
  defp maybe_cleanup_file(file_path) do
    if Application.get_env(:ex_clamav_server, :cleanup_after_scan, false) do
      cleanup_file(file_path)
    end
  end

  # Force delete infected files
  defp cleanup_file(file_path) do
    case File.rm(file_path) do
      :ok ->
        Logger.debug("ScanWorker: cleaned up file #{file_path}")

      {:error, reason} ->
        Logger.warning("ScanWorker: failed to clean up #{file_path} — #{inspect(reason)}")
    end
  end
end
