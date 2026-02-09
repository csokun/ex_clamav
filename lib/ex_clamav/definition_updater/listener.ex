defmodule ExClamav.DefinitionUpdater.Listener do
  @moduledoc """
  A behaviour and GenServer that subscribes to `ExClamav.DefinitionUpdater`
  and dispatches callbacks when virus definitions are updated.

  ## Implementing a Listener

  Implement the `ExClamav.DefinitionUpdater.Listener` behaviour in your own module:

      defmodule MyApp.ClamAVListener do
        use ExClamav.DefinitionUpdater.Listener

        @impl true
        def on_definition_updated(metadata) do
          IO.puts("Definitions updated at \#{metadata.updated_at}")
          # Reload engines, send notifications, etc.
        end

        @impl true
        def on_definition_update_failed(metadata) do
          IO.puts("Update failed: \#{metadata.reason}")
          # Alert ops, retry, etc.
        end
      end

  Then start it under a supervisor:

      children = [
        {ExClamav.DefinitionUpdater, database_path: "/var/lib/clamav"},
        {MyApp.ClamAVListener, updater: ExClamav.DefinitionUpdater}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)
  """

  @doc """
  Called when virus definitions have been successfully updated.
  """
  @callback on_definition_updated(metadata :: map()) :: any()

  @doc """
  Called when a virus definition update attempt has failed.
  """
  @callback on_definition_update_failed(metadata :: map()) :: any()

  @doc """
  Makes the current module a `DefinitionUpdater.Listener` GenServer.

  Options passed to `start_link/1`:
  * `:updater` — the `DefinitionUpdater` server to subscribe to (default: `ExClamav.DefinitionUpdater`)
  * `:name`    — GenServer name registration
  """
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour ExClamav.DefinitionUpdater.Listener

      use GenServer

      require Logger

      def start_link(opts \\ []) do
        genserver_opts =
          case Keyword.fetch(opts, :name) do
            {:ok, nil} -> []
            {:ok, name} -> [name: name]
            :error -> [name: __MODULE__]
          end

        GenServer.start_link(__MODULE__, opts, genserver_opts)
      end

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

      @impl GenServer
      def init(opts) do
        updater = Keyword.get(opts, :updater, ExClamav.DefinitionUpdater)
        :ok = ExClamav.DefinitionUpdater.subscribe(updater)
        {:ok, %{updater: updater}}
      end

      @impl GenServer
      def handle_info({:clamav_definition_updated, metadata}, state) do
        try do
          on_definition_updated(metadata)
        rescue
          e ->
            Logger.error(
              "Listener #{inspect(__MODULE__)} on_definition_updated raised: #{inspect(e)}"
            )
        end

        {:noreply, state}
      end

      def handle_info({:clamav_definition_update_failed, metadata}, state) do
        try do
          on_definition_update_failed(metadata)
        rescue
          e ->
            Logger.error(
              "Listener #{inspect(__MODULE__)} on_definition_update_failed raised: #{inspect(e)}"
            )
        end

        {:noreply, state}
      end

      def handle_info(_msg, state), do: {:noreply, state}

      defoverridable start_link: 1, child_spec: 1, init: 1
    end
  end
end
