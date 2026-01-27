defmodule ExClamav.Engine do
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
    call_nif(:init, [flags])
  end

  @doc """
  Create a new engine with default settings.
  """
  @spec new_engine() :: {:ok, Engine.t()} | {:error, String.t()}
  def new_engine() do
    case call_nif(:engine_new, []) do
      {:ok, ref} -> {:ok, %__MODULE__{ref: ref}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Load virus database into the engine.
  """
  @spec load_database(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def load_database(%__MODULE__{ref: ref}, database_path \\ "/var/lib/clamav") do
    call_nif(:load_database, [ref, database_path])
  end

  @doc """
  Compile the engine after loading the database.
  """
  @spec compile(t()) :: :ok | {:error, String.t()}
  def compile(%__MODULE__{ref: ref}) do
    call_nif(:compile_engine, [ref])
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
          {:ok, :clean} | {:virus, String.t()} | {:error, String.t()}
  def scan_file(%__MODULE__{ref: ref}, file_path, options \\ 0) do
    case call_nif(:scan_file, [ref, file_path, options]) do
      {:ok, :clean} = clean -> clean
      {:ok, :virus, name} -> {:virus, normalize_virus_name(name)}
      {:error, reason} -> {:error, IO.chardata_to_string(reason)}
    end
  end

  @doc """
  Scan binary data for viruses.
  """
  @spec scan_buffer(t(), binary(), non_neg_integer()) ::
          {:ok, :clean} | {:virus, String.t()} | {:error, String.t()}
  def scan_buffer(%__MODULE__{ref: ref}, buffer, options \\ 0) when is_binary(buffer) do
    case call_nif(:scan_buffer, [ref, buffer, options]) do
      {:ok, :clean} = clean -> clean
      {:ok, :virus, name} -> {:virus, normalize_virus_name(name)}
      other -> other
    end
  end

  @doc """
  Get the database version.
  """
  @spec get_database_version(t()) :: non_neg_integer() | {:error, String.t()}
  def get_database_version(%__MODULE__{ref: ref}) do
    call_nif(:get_database_version, [ref])
  end

  @doc """
  Explicitly free the engine resources.

  Note: The engine will also be freed automatically when garbage collected.
  """
  @spec free(t()) :: :ok
  def free(%__MODULE__{ref: ref}) do
    call_nif(:engine_free, [ref])
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
  def clean_buffer?(engine, buffer) when is_binary(buffer) do
    case scan_buffer(engine, buffer) do
      {:ok, :clean} -> true
      _ -> false
    end
  end

  defp normalize_virus_name(name) when is_binary(name), do: name
  defp normalize_virus_name(name) when is_list(name), do: IO.chardata_to_string(name)
  defp normalize_virus_name(_), do: ""

  defp call_nif(function, args) when is_atom(function) and is_list(args) do
    apply(ExClamav.Nif, function, args)
  end
end
