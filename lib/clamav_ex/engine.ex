defmodule ClamavEx.Engine do
  @moduledoc """
  Engine struct and operations for ClamAV scanning.

  This module manages the lifecycle of a ClamAV engine.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}

  @doc """
  Initialize the ClamAV library.

  ## Flags
    - `1`: Initialize the default allocator (CL_INIT_DEFAULT)
    - `2`: Use system memory allocator (CL_INIT_MEMSYSTEM)
    - `4`: Use standard malloc (CL_INIT_STDALLOC)
  """
  @spec init(non_neg_integer()) :: :ok | {:error, String.t()}
  def init(flags \\ 1) do
    ClamavEx.Nif.init(flags)
  end

  @doc """
  Load virus database into the engine.
  """
  @spec load_database(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def load_database(%__MODULE__{ref: ref}, database_path) do
    ClamavEx.Nif.load_database(ref, database_path)
  end

  @doc """
  Compile the engine after loading the database.
  """
  @spec compile(t()) :: :ok | {:error, String.t()}
  def compile(%__MODULE__{ref: ref}) do
    ClamavEx.Nif.compile_engine(ref)
  end

  @doc """
  Scan a file for viruses.

  ## Options
    - `0`: Standard options
    - `1`: Scan archives (CL_SCAN_ARCHIVE)
    - `2`: Scan mail files (CL_SCAN_MAIL)
    - `4`: Scan OLE2 containers (CL_SCAN_OLE2)
    - `8`: Block broken executables (CL_SCAN_BLOCKBROKEN)
    - etc. (see ClamAV documentation)
  """
  @spec scan_file(t(), String.t(), non_neg_integer()) ::
          {:ok, :clean} | {:ok, :virus, String.t()} | {:error, String.t()}
  def scan_file(%__MODULE__{ref: ref}, file_path, options \\ 0) do
    ClamavEx.Nif.scan_file(ref, file_path, options)
  end

  @doc """
  Scan binary data for viruses.
  """
  @spec scan_buffer(t(), binary(), non_neg_integer()) ::
          {:ok, :clean} | {:ok, :virus, String.t()} | {:error, String.t()}
  def scan_buffer(%__MODULE__{ref: ref}, buffer, options \\ 0) when is_binary(buffer) do
    ClamavEx.Nif.scan_buffer(ref, buffer, options)
  end

  @doc """
  Get the database version.
  """
  @spec get_database_version(t()) :: non_neg_integer() | {:error, String.t()}
  def get_database_version(%__MODULE__{ref: ref}) do
    ClamavEx.Nif.get_database_version(ref)
  end

  @doc """
  Explicitly free the engine resources.

  Note: The engine will also be freed automatically when garbage collected.
  """
  @spec free(t()) :: :ok
  def free(%__MODULE__{ref: ref}) do
    ClamavEx.Nif.engine_free(ref)
  end

  @doc """
  Check if a file is clean.
  """
  @spec clean?(t(), String.t()) :: boolean()
  def clean?(engine, file_path) do
    case scan_file(engine, file_path) do
      {:ok, :clean} -> true
      _ -> false
    end
  end

  @doc """
  Check if a buffer is clean.
  """
  @spec clean_buffer?(t(), binary()) :: boolean()
  def clean_buffer?(engine, buffer) do
    case scan_buffer(engine, buffer) do
      {:ok, :clean} -> true
      _ -> false
    end
  end
end
