defmodule ClamavExTest do
  use ExUnit.Case, async: false

  alias ClamavEx.Engine

  setup_all do
    :ok = Engine.init(0)
    :ok
  end

  test "returns the linked ClamAV version string" do
    version = ClamavEx.version()
    version_string = to_string(version)
    assert byte_size(version_string) > 0
  end

  test "creates and frees an engine resource" do
    assert {:ok, %Engine{ref: ref} = engine} = ClamavEx.new_engine()
    assert is_reference(ref)
    assert :ok = Engine.free(engine)
  end

  test "returns an error tuple when a file is missing" do
    assert {:ok, engine} = ClamavEx.new_engine()

    tmp_path =
      Path.join(System.tmp_dir!(), "clamav_ex_missing_file_#{System.unique_integer([:positive])}")

    File.rm(tmp_path)
    assert {:error, reason} = Engine.scan_file(engine, tmp_path)
    reason_string = to_string(reason)
    assert byte_size(reason_string) > 0
    assert :ok = Engine.free(engine)
  end
end
