defmodule ExClamav.DefinitionUpdaterTest do
  use ExUnit.Case, async: false

  alias ExClamav.DefinitionUpdater

  import ExClamav.Test.FreshclamHelpers

  @moduletag :tmp_dir

  # ── Tests ────────────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts the updater with default options", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: :timer.hours(24)
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribe and unsubscribe work", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: :timer.hours(24)
        )

      :ok = DefinitionUpdater.subscribe(pid)
      assert %{subscriber_count: 1} = DefinitionUpdater.status(pid)

      :ok = DefinitionUpdater.unsubscribe(pid)
      assert %{subscriber_count: 0} = DefinitionUpdater.status(pid)

      GenServer.stop(pid)
    end

    test "subscriber is removed when it goes down", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: :timer.hours(24)
        )

      # Spawn a process that subscribes, then immediately exits
      task =
        Task.async(fn ->
          :ok = DefinitionUpdater.subscribe(pid)
        end)

      Task.await(task)
      # Give the DOWN message time to propagate
      Process.sleep(50)

      assert %{subscriber_count: 0} = DefinitionUpdater.status(pid)
      GenServer.stop(pid)
    end
  end

  describe "update_now/1" do
    test "notifies subscribers when definitions change", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir, simulate_update: true)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: :timer.hours(24)
        )

      :ok = DefinitionUpdater.subscribe(pid)
      DefinitionUpdater.update_now(pid)

      assert_receive {:clamav_definition_updated, metadata}, 5_000
      assert metadata.database_path == db_path
      assert %DateTime{} = metadata.updated_at
      assert is_list(metadata.fingerprint)

      GenServer.stop(pid)
    end

    test "notifies subscribers when update fails", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir, exit_code: 1)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: :timer.hours(24)
        )

      :ok = DefinitionUpdater.subscribe(pid)
      DefinitionUpdater.update_now(pid)

      assert_receive {:clamav_definition_update_failed, metadata}, 5_000
      assert metadata.database_path == db_path
      assert is_binary(metadata.reason)

      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "returns current status", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      freshclam = create_fake_freshclam(tmp_dir)

      {:ok, pid} =
        DefinitionUpdater.start_link(
          name: nil,
          database_path: db_path,
          freshclam_path: freshclam,
          run_on_start: false,
          interval_ms: 60_000
        )

      status = DefinitionUpdater.status(pid)

      assert status.database_path == db_path
      assert status.interval_ms == 60_000
      assert status.subscriber_count == 0
      assert status.last_update_at == nil
      assert status.last_result == nil

      GenServer.stop(pid)
    end
  end

  describe "compute_fingerprint/1" do
    test "computes fingerprint from database files", %{tmp_dir: tmp_dir} do
      db_path = create_fake_db(tmp_dir)
      fingerprint = DefinitionUpdater.compute_fingerprint(db_path)

      assert length(fingerprint) == 1
      assert {"main.cvd", _size, _mtime} = hd(fingerprint)
    end

    test "returns empty list for missing directory" do
      assert [] == DefinitionUpdater.compute_fingerprint("/nonexistent/path")
    end
  end
end
