defmodule FakeS3Test do
  use ExUnit.Case
  doctest FakeS3

  test "greets the world" do
    assert FakeS3.hello() == :world
  end
end
