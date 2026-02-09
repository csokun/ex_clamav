defmodule ExClamavServer.UploadHandler do
  @moduledoc """
  Handles file upload processing for virus scanning.

  This module manages the lifecycle of an uploaded file:

  1. Validates the upload (size limits, presence of file)
  2. Generates a unique reference ID
  3. Stores the file to the shared upload volume
  4. Creates a `ScanJob` record in PostgreSQL
  5. Kicks off an async scan via `ScanWorker`

  ## File Storage Layout

  Uploaded files are stored under the configured upload path with a directory
  structure based on the reference ID to avoid filename collisions:

      <upload_path>/<reference_id>/<original_filename>

  This allows multiple instances to access the same file via a shared volume
  (e.g., EFS on EKS).

  ## Size Limits

  The maximum upload size defaults to 100 MB and can be configured via the
  `MAX_UPLOAD_SIZE` environment variable or application config.
  """

  require Logger

  alias ExClamavServer.ScanJob
  alias ExClamavServer.ScanWorker

  # Default max upload size: 100 MB
  @default_max_upload_size 100 * 1024 * 1024

  @type upload_result :: {:ok, map()} | {:error, {atom(), String.t()}}

  @doc """
  Processes an uploaded file from a Plug.Upload struct.

  Validates the upload, stores the file, creates a scan job record,
  and starts an async scan.

  Returns `{:ok, api_response_map}` on success or `{:error, {status_atom, message}}` on failure.
  """
  @spec handle_upload(Plug.Upload.t() | nil) :: upload_result()
  def handle_upload(nil) do
    {:error, {:bad_request, "No file uploaded. Send a file with the 'file' form field."}}
  end

  def handle_upload(%Plug.Upload{} = upload) do
    with :ok <- validate_upload(upload),
         {:ok, reference_id} <- generate_reference_id(),
         {:ok, stored_path} <- store_file(upload, reference_id),
         {:ok, file_size} <- get_file_size(stored_path),
         {:ok, job} <- create_scan_job(upload, reference_id, stored_path, file_size) do
      # Start async scan — fire and forget
      {:ok, _pid} = ScanWorker.scan_async(job)

      Logger.info("UploadHandler: created scan job #{reference_id} for #{upload.filename}")

      {:ok, ScanJob.to_api_response(job)}
    end
  end

  @doc """
  Processes a raw binary upload with an explicit filename.

  This is an alternative to `handle_upload/1` for cases where the file
  content is provided directly (e.g., from a binary body or base64 payload).
  """
  @spec handle_binary_upload(binary(), String.t(), String.t() | nil) :: upload_result()
  def handle_binary_upload(content, filename, content_type \\ nil)
      when is_binary(content) and is_binary(filename) do
    with :ok <- validate_binary_size(content),
         {:ok, reference_id} <- generate_reference_id(),
         {:ok, stored_path} <- store_binary(content, filename, reference_id),
         {:ok, job} <- create_scan_job_from_binary(filename, content_type, reference_id, stored_path, byte_size(content)) do
      {:ok, _pid} = ScanWorker.scan_async(job)

      Logger.info("UploadHandler: created scan job #{reference_id} for #{filename}")

      {:ok, ScanJob.to_api_response(job)}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_upload(%Plug.Upload{filename: filename}) when filename in [nil, ""] do
    {:error, {:bad_request, "Uploaded file has no filename."}}
  end

  defp validate_upload(%Plug.Upload{path: path}) do
    max_size = max_upload_size()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > max_size ->
        {:error,
         {:payload_too_large,
          "File exceeds maximum upload size of #{format_bytes(max_size)}. Got #{format_bytes(size)}."}}

      {:ok, %File.Stat{size: 0}} ->
        {:error, {:bad_request, "Uploaded file is empty."}}

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        {:error, {:internal_error, "Failed to read uploaded file: #{inspect(reason)}"}}
    end
  end

  defp validate_binary_size(content) do
    max_size = max_upload_size()
    size = byte_size(content)

    cond do
      size == 0 ->
        {:error, {:bad_request, "Uploaded content is empty."}}

      size > max_size ->
        {:error,
         {:payload_too_large,
          "Content exceeds maximum upload size of #{format_bytes(max_size)}. Got #{format_bytes(size)}."}}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # File Storage
  # ---------------------------------------------------------------------------

  defp store_file(%Plug.Upload{path: tmp_path, filename: filename}, reference_id) do
    upload_dir = job_upload_dir(reference_id)

    case File.mkdir_p(upload_dir) do
      :ok ->
        # Sanitize filename to prevent path traversal
        safe_filename = sanitize_filename(filename)
        destination = Path.join(upload_dir, safe_filename)

        case File.cp(tmp_path, destination) do
          :ok ->
            Logger.debug("UploadHandler: stored file at #{destination}")
            {:ok, destination}

          {:error, reason} ->
            Logger.error("UploadHandler: failed to store file — #{inspect(reason)}")
            {:error, {:internal_error, "Failed to store uploaded file: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        Logger.error("UploadHandler: failed to create upload dir — #{inspect(reason)}")
        {:error, {:internal_error, "Failed to create upload directory: #{inspect(reason)}"}}
    end
  end

  defp store_binary(content, filename, reference_id) do
    upload_dir = job_upload_dir(reference_id)

    case File.mkdir_p(upload_dir) do
      :ok ->
        safe_filename = sanitize_filename(filename)
        destination = Path.join(upload_dir, safe_filename)

        case File.write(destination, content) do
          :ok ->
            {:ok, destination}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to write file: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        {:error, {:internal_error, "Failed to create upload directory: #{inspect(reason)}"}}
    end
  end

  defp job_upload_dir(reference_id) do
    Path.join(ExClamavServer.upload_path(), reference_id)
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, {:internal_error, "Failed to stat file: #{inspect(reason)}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Database
  # ---------------------------------------------------------------------------

  defp create_scan_job(%Plug.Upload{filename: filename, content_type: content_type}, reference_id, stored_path, file_size) do
    attrs = %{
      reference_id: reference_id,
      original_filename: filename,
      stored_path: stored_path,
      file_size: file_size,
      content_type: content_type,
      status: "pending"
    }

    case ScanJob.create(attrs) do
      {:ok, job} ->
        {:ok, job}

      {:error, changeset} ->
        Logger.error("UploadHandler: failed to create scan job — #{inspect(changeset.errors)}")
        # Clean up the stored file on DB failure
        File.rm(stored_path)
        {:error, {:internal_error, "Failed to create scan job record."}}
    end
  end

  defp create_scan_job_from_binary(filename, content_type, reference_id, stored_path, file_size) do
    attrs = %{
      reference_id: reference_id,
      original_filename: filename,
      stored_path: stored_path,
      file_size: file_size,
      content_type: content_type,
      status: "pending"
    }

    case ScanJob.create(attrs) do
      {:ok, job} ->
        {:ok, job}

      {:error, changeset} ->
        Logger.error("UploadHandler: failed to create scan job — #{inspect(changeset.errors)}")
        File.rm(stored_path)
        {:error, {:internal_error, "Failed to create scan job record."}}
    end
  end

  # ---------------------------------------------------------------------------
  # Reference ID
  # ---------------------------------------------------------------------------

  defp generate_reference_id do
    ref_id = "scan_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
    {:ok, ref_id}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Sanitizes a filename to prevent path traversal and other issues.

  - Strips directory components
  - Replaces non-alphanumeric characters (except `.`, `-`, `_`) with underscores
  - Limits length to 255 characters
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/, "_")
    |> String.slice(0, 255)
    |> case do
      "" -> "unnamed_upload"
      name -> name
    end
  end

  defp max_upload_size do
    Application.get_env(:ex_clamav_server, :max_upload_size, @default_max_upload_size)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
