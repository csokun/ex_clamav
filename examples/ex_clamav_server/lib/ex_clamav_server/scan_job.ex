defmodule ExClamavServer.ScanJob do
  @moduledoc """
  Ecto schema and changesets for virus scan jobs.

  A scan job tracks the lifecycle of a file upload through virus scanning.
  Jobs are stored in PostgreSQL so that any instance can query status.

  ## States

  - `pending`     — file uploaded, scan not yet started
  - `in_progress` — scan engine is actively scanning the file
  - `completed`   — scan finished successfully (result will be set)
  - `failed`      — scan encountered an error

  ## Results (only set when status is `completed`)

  - `clean`       — no virus detected
  - `virus_found` — virus or malware detected (virus_name will be set)
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias ExClamavServer.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          reference_id: String.t(),
          original_filename: String.t(),
          stored_path: String.t(),
          file_size: non_neg_integer(),
          content_type: String.t() | nil,
          status: String.t(),
          result: String.t() | nil,
          virus_name: String.t() | nil,
          error_message: String.t() | nil,
          scanned_by: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "scan_jobs" do
    field :reference_id, :string
    field :original_filename, :string
    field :stored_path, :string
    field :file_size, :integer
    field :content_type, :string
    field :status, :string, default: "pending"
    field :result, :string
    field :virus_name, :string
    field :error_message, :string
    field :scanned_by, :string

    timestamps()
  end

  @required_fields [:reference_id, :original_filename, :stored_path, :file_size]
  @optional_fields [:content_type, :status, :result, :virus_name, :error_message, :scanned_by]

  @valid_statuses ~w(pending in_progress completed failed)
  @valid_results ~w(clean virus_found)

  @doc """
  Changeset for creating a new scan job.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:file_size, greater_than_or_equal_to: 0)
    |> unique_constraint(:reference_id)
  end

  @doc """
  Changeset for updating scan job status and results.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = job, attrs) do
    job
    |> cast(attrs, [:status, :result, :virus_name, :error_message, :scanned_by])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:result, @valid_results)
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new scan job record in the database.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs
    |> create_changeset()
    |> Repo.insert()
  end

  @doc """
  Finds a scan job by its reference_id.
  """
  @spec get_by_reference_id(String.t()) :: t() | nil
  def get_by_reference_id(reference_id) do
    Repo.get_by(__MODULE__, reference_id: reference_id)
  end

  @doc """
  Marks a scan job as in_progress.
  """
  @spec mark_in_progress(t(), String.t() | nil) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_in_progress(%__MODULE__{} = job, scanned_by \\ nil) do
    job
    |> update_changeset(%{status: "in_progress", scanned_by: scanned_by})
    |> Repo.update()
  end

  @doc """
  Marks a scan job as completed with the given result.
  """
  @spec mark_completed(t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%__MODULE__{} = job, result, virus_name \\ nil) do
    job
    |> update_changeset(%{status: "completed", result: result, virus_name: virus_name})
    |> Repo.update()
  end

  @doc """
  Marks a scan job as failed with an error message.
  """
  @spec mark_failed(t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%__MODULE__{} = job, error_message) do
    job
    |> update_changeset(%{status: "failed", error_message: error_message})
    |> Repo.update()
  end

  @doc """
  Atomically claims a pending job for scanning by this instance.

  Uses an UPDATE ... WHERE to prevent two instances from scanning the same file.
  Returns `{:ok, job}` if the claim succeeded, `{:error, :already_claimed}` otherwise.
  """
  @spec claim_for_scanning(t(), String.t()) :: {:ok, t()} | {:error, :already_claimed}
  def claim_for_scanning(%__MODULE__{id: id}, scanned_by) do
    query =
      from(j in __MODULE__,
        where: j.id == ^id and j.status == "pending",
        select: j
      )

    case Repo.update_all(query, set: [status: "in_progress", scanned_by: scanned_by, updated_at: DateTime.utc_now()]) do
      {1, [job]} -> {:ok, job}
      {0, _} -> {:error, :already_claimed}
    end
  end

  @doc """
  Returns pending scan jobs (for recovery or reprocessing).
  """
  @spec list_pending(non_neg_integer()) :: [t()]
  def list_pending(limit \\ 100) do
    from(j in __MODULE__,
      where: j.status == "pending",
      order_by: [asc: j.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Generates a unique reference ID for a scan job.

  Format: `scan_<base62_encoded_uuid>` — URL-safe and human-friendly.
  """
  @spec generate_reference_id() :: String.t()
  def generate_reference_id do
    "scan_" <> Ecto.UUID.generate() |> String.replace("-", "")
  end

  @doc """
  Returns a JSON-serializable map of the scan job for API responses.
  """
  @spec to_api_response(t()) :: map()
  def to_api_response(%__MODULE__{} = job) do
    response = %{
      reference_id: job.reference_id,
      original_filename: job.original_filename,
      file_size: job.file_size,
      status: job.status,
      created_at: job.inserted_at
    }

    response =
      if job.status == "completed" do
        result_detail =
          case job.result do
            "virus_found" -> %{result: "virus_found", virus_name: job.virus_name}
            result -> %{result: result}
          end

        Map.merge(response, result_detail)
      else
        response
      end

    response =
      if job.status == "failed" do
        Map.put(response, :error_message, job.error_message)
      else
        response
      end

    response
  end
end
