defmodule ClamavExTest do
  use ExUnit.Case, async: false

  test "returns the linked ClamAV version string" do
    version = ClamavEx.version()
    version_string = to_string(version)
    assert byte_size(version_string) > 0
  end
end
