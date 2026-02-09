defmodule ExClamav.DefinitionUpdater do
  @moduledoc """
  A GenServer that periodically updates ClamAV virus definitions using `freshclam`
  and notifies subscribed listeners when definitions change.

  ## Features

  * Runs `freshclam` on a configurable interval (default: 1 hour).
  * Detects database changes by fingerprinting `.cvd` / `.cld` files.
  * Pub/sub notification — any process can subscribe and receive messages
    when definitions are updated.
  * Manual trigger via `update_now/1` for on-demand refreshes.

  ## Notifications

  Subscribed processes receive the following messages:

  * `{:clamav_definition_updated, metadata}` — definitions were successfully updated.
  * `{:clamav_definition_update_failed, metadata}` — the update attempt failed.

  Where `metadata` is a map containing:

      %{
        database_path: String.t(),
        fingerprint: list(),
        previous_fingerprint: list(),
        updated_at: DateTime.t()
      }

  ## Usage

      # Start the updater (usually under a supervisor)
      {:ok, pid} = ExClamav.DefinitionUpdater.start_link(
        database_path: "/var/lib/clamav",
        interval_ms: :timer.hours(1)
      )

      # Subscribe the current process
      ExClamav.DefinitionUpdater.subscribe(pid)

      # Trigger an immediate update
      ExClamav.DefinitionUpdater.update_now(pid)

      # Receive notifications
      receive do
        {:clamav_definition_updated, meta} ->
          IO.puts("Definitions updated!")
      end

  ## Options

  * `:database_path`       — path to ClamAV database directory (default: `"/var/lib/clamav"`).
  * `:interval_ms`         — milliseconds between update checks (default: `3_600_000` — 1 hour).
  * `:freshclam_path`      — path to the `freshclam` binary (default: auto-detected).
  * `:freshclam_config`    — optional path to a `freshclam.conf` file.
  * `:name`                — GenServer name registration (default: `ExClamav.DefinitionUpdater`).
  * `:run_on_start`        — whether to trigger an update immediately on start (default: `true`).
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────────

  @type fingerprint :: [{filename :: String.t(), size :: non_neg_integer(), mtime :: tuple()}]

  @type status :: %{
          database_path: Path.t(),
          interval_ms: pos_integer(),
          subscriber_count: non_neg_integer(),
          last_update_at: DateTime.t() | nil,
          last_result: :updated | :up_to_date | {:error, String.t()} | nil,
          fingerprint: fingerprint()
        }

  @type option ::
          {:database_path, Path.t()}
          | {:interval_ms, pos_integer()}
          | {:freshclam_path, Path.t()}
          | {:freshclam_config, Path.t()}
          | {:name, GenServer.name()}
          | {:run_on_start, boolean()}

  defstruct [
    :database_path,
    :interval_ms,
    :freshclam_path,
    :freshclam_config,
    :timer_ref,
    :last_update_at,
    :last_result,
    :run_on_start,
    fingerprint: [],
    subscribers: %{}
  ]

  @default_interval_ms :timer.hours(1)
  @default_database_path "/var/lib/clamav"

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the definition updater.

  See module documentation for available options.
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
  Returns a child spec for supervision trees.
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
      shutdown: 5_000,
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Subscribe the calling process to definition update notifications.

  The subscriber will receive:
  * `{:clamav_definition_updated, metadata}` on successful updates
  * `{:clamav_definition_update_failed, metadata}` on failed updates

  Returns `:ok`. If the process is already subscribed, this is a no-op.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Unsubscribe the calling process from definition update notifications.

  Returns `:ok`. If the process is not subscribed, this is a no-op.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @doc """
  Trigger an immediate virus definition update.

  This is asynchronous — the update runs in the background and subscribers
  are notified when it completes. Returns `:ok` immediately.
  """
  @spec update_now(GenServer.server()) :: :ok
  def update_now(server \\ __MODULE__) do
    GenServer.cast(server, :update_now)
  end

  @doc """
  Get the current status of the updater.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    database_path = Keyword.get(opts, :database_path, @default_database_path)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    freshclam_path = Keyword.get(opts, :freshclam_path, detect_freshclam())
    freshclam_config = Keyword.get(opts, :freshclam_config)
    run_on_start = Keyword.get(opts, :run_on_start, true)

    state = %__MODULE__{
      database_path: database_path,
      interval_ms: interval_ms,
      freshclam_path: freshclam_path,
      freshclam_config: freshclam_config,
      run_on_start: run_on_start,
      fingerprint: compute_fingerprint(database_path)
    }

    if run_on_start do
      {:ok, state, {:continue, :initial_update}}
    else
      timer_ref = schedule_update(interval_ms)
      {:ok, %{state | timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_continue(:initial_update, state) do
    new_state = perform_update(state)
    timer_ref = schedule_update(new_state.interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      new_subscribers = Map.put(state.subscribers, pid, ref)
      Logger.debug("DefinitionUpdater: #{inspect(pid)} subscribed")
      {:reply, :ok, %{state | subscribers: new_subscribers}}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        {:reply, :ok, state}

      {ref, new_subscribers} ->
        Process.demonitor(ref, [:flush])
        Logger.debug("DefinitionUpdater: #{inspect(pid)} unsubscribed")
        {:reply, :ok, %{state | subscribers: new_subscribers}}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      database_path: state.database_path,
      interval_ms: state.interval_ms,
      subscriber_count: map_size(state.subscribers),
      last_update_at: state.last_update_at,
      last_result: state.last_result,
      fingerprint: state.fingerprint
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:update_now, state) do
    cancel_timer(state.timer_ref)
    new_state = perform_update(state)
    timer_ref = schedule_update(new_state.interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = perform_update(state)
    timer_ref = schedule_update(new_state.interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.subscribers, pid) do
      {^ref, new_subscribers} ->
        Logger.debug("DefinitionUpdater: subscriber #{inspect(pid)} went down, removing")
        {:noreply, %{state | subscribers: new_subscribers}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  defp perform_update(state) do
    Logger.info("DefinitionUpdater: running freshclam update for #{state.database_path}")
    previous_fingerprint = state.fingerprint

    case run_freshclam(state) do
      :ok ->
        new_fingerprint = compute_fingerprint(state.database_path)
        now = DateTime.utc_now()

        if new_fingerprint != previous_fingerprint do
          Logger.info("DefinitionUpdater: virus definitions updated")

          metadata = %{
            database_path: state.database_path,
            fingerprint: new_fingerprint,
            previous_fingerprint: previous_fingerprint,
            updated_at: now
          }

          broadcast(state.subscribers, {:clamav_definition_updated, metadata})

          %{state | fingerprint: new_fingerprint, last_update_at: now, last_result: :updated}
        else
          Logger.info("DefinitionUpdater: definitions are up to date")
          %{state | last_update_at: now, last_result: :up_to_date}
        end

      {:error, reason} ->
        Logger.error("DefinitionUpdater: freshclam update failed — #{reason}")
        now = DateTime.utc_now()

        metadata = %{
          database_path: state.database_path,
          reason: reason,
          updated_at: now
        }

        broadcast(state.subscribers, {:clamav_definition_update_failed, metadata})

        %{state | last_update_at: now, last_result: {:error, reason}}
    end
  end

  defp run_freshclam(%__MODULE__{freshclam_path: nil}) do
    {:error, "freshclam binary not found. Install ClamAV or set :freshclam_path"}
  end

  defp run_freshclam(%__MODULE__{} = state) do
    args = build_freshclam_args(state)

    Logger.debug("DefinitionUpdater: executing #{state.freshclam_path} #{Enum.join(args, " ")}")

    try do
      case System.cmd(state.freshclam_path, args, stderr_to_stdout: true) do
        {output, 0} ->
          Logger.debug("DefinitionUpdater: freshclam output:\n#{output}")
          :ok

        {output, exit_code} ->
          {:error, "freshclam exited with code #{exit_code}: #{String.trim(output)}"}
      end
    rescue
      e in ErlangError ->
        {:error, "failed to execute freshclam: #{inspect(e)}"}
    end
  end

  defp build_freshclam_args(state) do
    args = ["--datadir=#{state.database_path}"]

    args =
      if state.freshclam_config do
        ["--config-file=#{state.freshclam_config}" | args]
      else
        args
      end

    ["--no-dns" | args]
  end

  @doc false
  @spec compute_fingerprint(Path.t()) :: fingerprint()
  def compute_fingerprint(database_path) do
    db_glob = Path.join(database_path, "*.{cvd,cld}")

    Path.wildcard(db_glob)
    |> Enum.sort()
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{size: size, mtime: mtime}} ->
          {Path.basename(path), size, mtime}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp schedule_update(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)

    receive do
      :tick -> :ok
    after
      0 -> :ok
    end
  end

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, message)
    end)
  end

  defp detect_freshclam do
    case System.find_executable("freshclam") do
      nil ->
        common_paths = [
          "/usr/bin/freshclam",
          "/usr/local/bin/freshclam",
          "/usr/sbin/freshclam"
        ]

        Enum.find(common_paths, &File.exists?/1)

      path ->
        path
    end
  end
end
