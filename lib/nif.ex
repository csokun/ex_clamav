defmodule ClamavEx.Nif do
  @moduledoc """
  NIF interface to libclamav.

  This module provides direct bindings to the ClamAV C library.
  """

  @on_load :load_nifs

  def load_nifs do
    path = :filename.join(:code.priv_dir(:clamav_ex), ~c"clamav_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> raise "failed to load NIF library, reason: #{inspect(reason)}"
    end
  end

  # Initialize ClamAV library
  @spec init(non_neg_integer) :: :ok | {:error, String.t()}
  def init(_flags) do
    raise "NIF init/1 not implemented"
  end

  # Create a new engine
  @spec engine_new() :: {:ok, reference()} | {:error, String.t()}
  def engine_new() do
    raise "NIF engine_new/0 not implemented"
  end

  # Free an engine (mainly for explicit cleanup)
  @spec engine_free(reference()) :: :ok
  def engine_free(_engine_ref) do
    raise "NIF engine_free/1 not implemented"
  end

  # Load virus database
  @spec load_database(reference(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def load_database(_engine_ref, _database_path) do
    raise "NIF load_database/2 not implemented"
  end

  # Compile the engine
  @spec compile_engine(reference()) :: :ok | {:error, String.t()}
  def compile_engine(_engine_ref) do
    raise "NIF compile_engine/1 not implemented"
  end

  # Scan a file
  @spec scan_file(reference(), String.t(), non_neg_integer()) ::
          {:ok, :clean} | {:ok, :virus, String.t()} | {:error, String.t()}
  def scan_file(_engine_ref, _file_path, _options \\ 0) do
    raise "NIF scan_file/3 not implemented"
  end

  # Scan a buffer
  @spec scan_buffer(reference(), binary(), non_neg_integer()) ::
          {:ok, :clean} | {:ok, :virus, String.t()} | {:error, String.t()}
  def scan_buffer(_engine_ref, _buffer, _options \\ 0) do
    raise "NIF scan_buffer/3 not implemented"
  end

  # Get ClamAV version
  @spec get_version() :: String.t()
  def get_version() do
    raise "NIF get_version/0 not implemented"
  end

  # Get database version
  @spec get_database_version(reference()) :: non_neg_integer() | {:error, String.t()}
  def get_database_version(_engine_ref) do
    raise "NIF get_database_version/1 not implemented"
  end
end
