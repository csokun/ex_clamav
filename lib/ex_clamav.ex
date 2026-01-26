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
  Create a new engine with default settings.
  """
  @spec new_engine() :: {:ok, Engine.t()} | {:error, String.t()}
  def new_engine, do: create_engine()

  @doc """
  Create and initialize a new engine with a virus database.

  ## Options
    - `database_path`: Path to the virus database (default: system default)
  """
  @spec new_engine_with_database(String.t() | nil) :: {:ok, Engine.t()} | {:error, String.t()}
  def new_engine_with_database(database_path \\ nil) do
    with {:ok, engine} <- create_engine(),
         :ok <- initialize_engine(engine, database_path) do
      {:ok, engine}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Scan a file using a temporary engine.
  """
  @spec scan_file(String.t()) :: {:ok, :clean} | {:ok, :virus, String.t()} | {:error, String.t()}
  def scan_file(file_path) do
    case new_engine_with_database() do
      {:ok, engine} ->
        result = Engine.scan_file(engine, file_path)
        Engine.free(engine)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scan binary data using a temporary engine.
  """
  @spec scan_buffer(binary()) :: {:ok, :clean} | {:virus, String.t()} | {:error, String.t()}
  def scan_buffer(buffer) when is_binary(buffer) do
    case new_engine_with_database() do
      {:ok, engine} ->
        result = Engine.scan_buffer(engine, buffer)
        Engine.free(engine)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_engine do
    case call_nif(:engine_new, []) do
      {:ok, ref} -> {:ok, %Engine{ref: ref}}
      {:error, _reason} = error -> error
    end
  end

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
