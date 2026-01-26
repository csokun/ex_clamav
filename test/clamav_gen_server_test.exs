defmodule ClamavEx.ClamavGenServerTest do
  use ExUnit.Case, async: false

  alias ClamavEx.ClamavGenServer
  alias ClamavEx.Engine

  @moduletag :tmp_dir

  @eicar "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

  setup_all do
    :ok = Engine.init()
    %{server: start_supervised!({ClamavGenServer, name: nil})}
  end

  describe "scan_file/2" do
    test "returns {:ok, :clean} for clean files", %{server: server, tmp_dir: tmp_dir} do
      tmp_path = Path.join(tmp_dir, "clean_file")
      File.write!(tmp_path, "harmless content")

      assert {:ok, :clean} = ClamavGenServer.scan_file(server, tmp_path)
    end

    test "returns {:virus, name} for infected files", %{server: server, tmp_dir: tmp_dir} do
      tmp_path = Path.join(tmp_dir, "eicar_file")
      File.write!(tmp_path, @eicar)

      assert {:virus, "Eicar-Test-Signature"} = ClamavGenServer.scan_file(server, tmp_path)
    end
  end

  describe "scan_buffer/2" do
    test "reuses the long-lived engine for buffer scans", %{server: server} do
      assert {:virus, "Eicar-Test-Signature"} = ClamavGenServer.scan_buffer(server, @eicar)
      assert {:ok, :clean} = ClamavGenServer.scan_buffer(server, "totally safe data")
    end
  end

  describe "termination" do
    test "frees engine resources when the server stops" do
      {:ok, pid} = ClamavGenServer.start_link(name: nil)
      ref = Process.monitor(pid)

      assert :ok = GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end
end
