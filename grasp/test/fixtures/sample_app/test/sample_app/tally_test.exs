defmodule SampleApp.TallyTest do
  use ExUnit.Case, async: true

  alias SampleApp.Counter

  setup do
    {:ok, start: 41}
  end

  describe "handle_call/3" do
    @tag :tally
    test "replies with the next number", %{start: start} do
      assert {:reply, 42, 42} = Counter.handle_call(:next, self(), start)
    end
  end

  test "init keeps the start count" do
    assert init_with(7) == {:ok, 7}
  end

  defp init_with(count), do: Counter.init(count)
end
