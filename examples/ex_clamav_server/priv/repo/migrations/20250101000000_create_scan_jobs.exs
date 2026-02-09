defmodule ExClamavServer.Repo.Migrations.CreateScanJobs do
  use Ecto.Migration

  def change do
    create table(:scan_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reference_id, :string, null: false
      add :original_filename, :string, null: false
      add :stored_path, :string, null: false
      add :file_size, :bigint, null: false
      add :content_type, :string
      add :status, :string, null: false, default: "pending"
      add :result, :string
      add :virus_name, :string
      add :error_message, :text
      add :scanned_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scan_jobs, [:reference_id])
    create index(:scan_jobs, [:status])
    create index(:scan_jobs, [:status, :inserted_at])
    create index(:scan_jobs, [:inserted_at])
  end
end
