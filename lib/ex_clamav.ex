defmodule ExClamav do
  @moduledoc """
  High-level ClamAV interface for Elixir.

  This module provides a safe and convenient API for virus scanning using ClamAV.
  """

  alias ExClamav.Nif
  alias ExClamav.Engine

  @doc """
  Get the ClamAV library version.
  """
  @spec version() :: String.t()
  def version do
    call_nif(:get_version, [])
  end

  @doc """
  Create and initialize a new engine with a virus database.

  ## Options
    - `database_path`: Path to the virus database (default: system default)
  """
  @spec new_engine_with_database(String.t() | nil) :: {:ok, Engine.t()} | {:error, String.t()}
  def new_engine_with_database(database_path \\ nil) do
    with {:ok, engine} <- Engine.new_engine(),
         :ok <- initialize_engine(engine, database_path) do
      {:ok, engine}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Restart the engine by freeing the current engine and creating a new one with the given database.

  ## Parameters
    - `engine`: The current engine to free.
    - `database_path`: Path to the virus database (default: system default)

  ## Returns
    - `{:ok, Engine.t()} | {:error, String.t()}`
  """
  @spec restart_engine(Engine.t(), String.t() | nil) :: {:ok, Engine.t()} | {:error, String.t()}
  def restart_engine(engine, database_path \\ nil) do
    Engine.free(engine)
    new_engine_with_database(database_path)
  end

  defdelegate new_engine, to: Engine
  defdelegate scan_file(engine, file_path, options \\ 0), to: Engine
  defdelegate scan_buffer(engine, buffer, options \\ 0), to: Engine
  defdelegate free(engine), to: Engine
  defdelegate load_database(engine, database_path), to: Engine
  defdelegate compile(engine), to: Engine
  defdelegate get_database_version(engine), to: Engine

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp initialize_engine(engine, database_path) do
    path = database_path || default_database_path()

    with {:ok, _signatures} <- Engine.load_database(engine, path),
         :ok <- Engine.compile(engine) do
      :ok
    else
      {:error, _reason} = error ->
        Engine.free(engine)
        error
    end
  end

  defp call_nif(function, args) when is_atom(function) and is_list(args) do
    apply(Nif, function, args)
  end

  defp default_database_path do
    # Common database locations
    possible_paths = [
      "/var/lib/clamav",
      "/usr/local/share/clamav",
      "/usr/share/clamav"
    ]

    case Enum.find(possible_paths, &File.exists?/1) do
      # Default fallback
      nil -> "/var/lib/clamav"
      path -> path
    end
  end
end
