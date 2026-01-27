defmodule ExClamav.ClamavGenServer do
  @moduledoc """
  A `GenServer` wrapper around a long-lived ClamAV engine.

  This server lazily initializes (or reuses) a compiled engine and serializes scan
  requests across callers. Keeping the engine alive avoids reloading the virus
  database for every scan, which significantly reduces latency in test suites or
  services that need frequent scans.

  ## Features

  * Automatically loads and compiles the ClamAV database on boot.
  * Exposes synchronous `scan_file/2` and `scan_buffer/2` helpers.
  * Guarantees engine resources are released when the server terminates.
  """

  use GenServer

  alias ExClamav.Engine

  defstruct engine: nil, database_path: "/var/lib/clamav"

  @type t :: %__MODULE__{
          engine: Engine.t() | nil,
          database_path: Path.t() | nil
        }

  @type option ::
          {:name, GenServer.name()}
          | {:database_path, Path.t() | nil}

  @standard_scan_option 0

  @doc """
  Starts the server.

  * `:database_path` — overrides the default ClamAV database lookup path.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    genserver_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, nil} -> []
        {:ok, name} -> [name: name]
        :error -> [name: __MODULE__]
      end

    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Returns a child spec so the server can be supervised.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    id =
      case Keyword.fetch(opts, :name) do
        {:ok, nil} -> __MODULE__
        {:ok, name} -> name
        :error -> __MODULE__
      end

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 5000,
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Scan a file path using the managed engine.
  """
  @spec scan_file(GenServer.server(), Path.t()) ::
          {:ok, :clean} | {:virus, String.t()} | {:error, String.t()}
  def scan_file(server \\ __MODULE__, file_path) do
    GenServer.call(server, {:scan_file, file_path}, :infinity)
  end

  @doc """
  Scan an in-memory binary using the managed engine.
  """
  @spec scan_buffer(GenServer.server(), binary()) ::
          {:ok, :clean} | {:virus, String.t()} | {:error, String.t()}
  def scan_buffer(server \\ __MODULE__, buffer) when is_binary(buffer) do
    GenServer.call(server, {:scan_buffer, buffer}, :infinity)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    database_path = Keyword.get(opts, :database_path)

    # Initialize the default allocator (CL_INIT_DEFAULT)
    ExClamav.Engine.init(1)

    {:ok, %__MODULE__{engine: nil, database_path: database_path}, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    case ExClamav.new_engine_with_database(state.database_path) do
      {:ok, engine} ->
        {:noreply, %{state | engine: engine}}

      {:error, reason} ->
        {:stop, {:failed_to_initialize_engine, reason}}
    end
  end

  @impl true
  def handle_call({:scan_file, file_path}, _from, %__MODULE__{} = state) do
    reply = Engine.scan_file(state.engine, file_path, @standard_scan_option)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:scan_buffer, buffer}, _from, %__MODULE__{} = state) do
    reply = Engine.scan_buffer(state.engine, buffer, @standard_scan_option)
    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{engine: nil}) do
    :ok
  end

  def terminate(_reason, %__MODULE__{engine: engine}) do
    Engine.free(engine)
    :ok
  end
end
