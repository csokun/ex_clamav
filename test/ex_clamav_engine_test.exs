defmodule ExClamavEngineTest do
  use ExUnit.Case, async: false

  alias ExClamav.Engine

  setup_all do
    Engine.init()
    {:ok, engine} = ExClamav.new_engine()

    on_exit(fn ->
      Engine.free(engine)
    end)

    {:ok, _} = Engine.load_database(engine)
    :ok = Engine.compile(engine)
    {:ok, engine: engine}
  end

  test "creates and frees an engine resource", %{engine: %{ref: ref}} do
    assert is_reference(ref)
  end

  test "returns an error tuple when a file is missing", %{engine: engine} do
    tmp_path =
      Path.join(System.tmp_dir!(), "ex_clamav_missing_file_#{System.unique_integer([:positive])}")

    File.rm(tmp_path)

    assert {:error, "Can't open file or directory"} = Engine.scan_file(engine, tmp_path)
  end

  test "detects EICAR test virus string in a file", %{engine: engine} do
    tmp_path =
      Path.join(System.tmp_dir!(), "ex_clamav_eicar_test_#{System.unique_integer([:positive])}")

    eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

    File.write!(tmp_path, eicar)

    assert {:virus, "Eicar-Test-Signature"} = Engine.scan_file(engine, tmp_path)

    File.rm!(tmp_path)
  end

  test "returns clean when scanning a clean file", %{engine: engine} do
    tmp_path =
      Path.join(System.tmp_dir!(), "ex_clamav_clean_file_#{System.unique_integer([:positive])}")

    File.write!(tmp_path, "This is a clean file with no viruses.")

    assert {:ok, :clean} = Engine.scan_file(engine, tmp_path)

    File.rm!(tmp_path)
  end

  describe "engine guard rails" do
    test "scan_file errors when the database was never loaded" do
      {:ok, engine} = ExClamav.new_engine()
      tmp_path =
        Path.join(System.tmp_dir!(), "ex_clamav_uninitialized_#{System.unique_integer([:positive])}")

      File.write!(tmp_path, "guard-rail test")

      assert {:error, "Engine not initialized with database"} = Engine.scan_file(engine, tmp_path)

      File.rm!(tmp_path)
      :ok = Engine.free(engine)
    end

    test "scan_file errors when the engine has already been freed" do
      {:ok, engine} = ExClamav.new_engine()
      :ok = Engine.free(engine)

      tmp_path =
        Path.join(System.tmp_dir!(), "ex_clamav_freed_handle_#{System.unique_integer([:positive])}")

      File.write!(tmp_path, "guard-rail test")

      assert {:error, "Engine resource is invalid or has been freed"} =
               Engine.scan_file(engine, tmp_path)

      File.rm!(tmp_path)
    end
  end

end
