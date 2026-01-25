defmodule ClamavExTest do
  use ExUnit.Case
  doctest ClamavEx

  test "greets the world" do
    assert ClamavEx.hello() == :world
  end
end
