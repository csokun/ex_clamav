# Architecture Summary
## Subscription Flow
```
┌────────────────────┐     :tick / :update_now      ┌──────────┐
│  DefinitionUpdater │ ──── runs freshclam ───────► │ freshclam│
│    (GenServer)     │ ◄──── exit code + output ─── │ (system) │
│                    │                              └──────────┘
│  subscribers: %{}  │
│  fingerprint: [..] │──── compares fingerprints
└─────────┬──────────┘
          │ {:clamav_definition_updated, meta}
          ▼
┌──────────────────┐     ┌──────────────────────┐
│ ClamavGenServer  │     │ YourApp.Listener     │
│ (auto_reload)    │     │ (uses Listener       │
│ restarts engine  │     │  behaviour)          │
└──────────────────┘     └──────────────────────┘
```

### Key Design Decisions

1. **Fingerprint-based change detection** — Instead of parsing `freshclam` output (which varies across versions), the updater computes a fingerprint from the `.cvd`/`.cld` file sizes and modification times. If anything changes after `freshclam` runs, subscribers are notified.

2. **Monitor-based subscriber cleanup** — Each subscriber is `Process.monitor`'d. If a subscriber crashes, its entry is automatically removed from the subscriber map via the `:DOWN` handler.

3. **Timer management** — `update_now/1` cancels the pending periodic timer before running, then reschedules it, so you never get double-fires.

4. **`ClamavGenServer` auto-reload** — When `:auto_reload` is true, the scan server subscribes to the updater and calls `ExClamav.restart_engine/2` to swap in a fresh engine with the new definitions. Scans are serialized through `GenServer.call`, so no scan can run during the reload.

5. **Listener behaviour** — The `use ExClamav.DefinitionUpdater.Listener` macro gives you a full GenServer that subscribes automatically and dispatches `on_definition_updated/1` and `on_definition_update_failed/1` callbacks with error isolation.

### Example Supervision Tree

```elixir
# In your Application module:
children = [
  # 1. The definition updater runs freshclam every hour
  {ExClamav.DefinitionUpdater,
   database_path: "/var/lib/clamav",
   interval_ms: :timer.hours(1)},

  # 2. The scan server auto-reloads when definitions change
  {ExClamav.ClamavGenServer,
   auto_reload: true,
   updater: ExClamav.DefinitionUpdater},

  # 3. Optional: your own listener for custom actions (alerts, logging, etc.)
  {MyApp.ClamAVListener, updater: ExClamav.DefinitionUpdater}
]

Supervisor.start_link(children, strategy: :rest_for_one)

```
