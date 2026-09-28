defmodule GraspWeb.TestReachTest do
  use ExUnit.Case, async: true

  alias Grasp.Index
  alias Grasp.Session.Forest
  alias GraspWeb.TestReach

  @greet "SampleApp.Greeter.greet/2"
  @reply ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
  @setup "SampleApp.TallyTest.__ex_unit_setup_0/1"

  setup do
    {:ok, index} = Index.load("test/fixtures/index.json")
    {forest, _id} = Forest.open_root(Forest.new(), @greet)
    %{index: index, forest: forest}
  end

  test "answers each function card with the tests reaching it", %{index: index, forest: forest} do
    reach = TestReach.refresh(TestReach.new(), index, forest)

    assert TestReach.for_function(reach, @greet) == Index.tests_for(index, @greet)
    assert length(TestReach.for_function(reach, @greet)) == 2
  end

  test "holds no entry for a test or a setup card", %{index: index, forest: forest} do
    {forest, _id} = Forest.open_root(forest, @reply)
    {forest, _id} = Forest.open_root(forest, @setup)

    reach = TestReach.refresh(TestReach.new(), index, forest)

    assert Map.keys(reach.tests) == [@greet]
  end

  describe "refresh/3" do
    # A held answer no walk of the index could produce: kept, it proves the index is not walked.
    setup %{index: index, forest: forest} do
      reach = TestReach.refresh(TestReach.new(), index, forest)
      %{reach: %{reach | tests: %{@greet => [%{test: "held", hops: 9}]}}}
    end

    test "keeps the answers it holds across a move and a focus", %{
      index: index,
      forest: forest,
      reach: reach
    } do
      forest = forest |> Forest.move(1, {120, 40}) |> Forest.focus(1)

      assert TestReach.refresh(reach, index, forest) === reach
    end

    test "walks again when a card of another function opens",
         %{index: index, forest: forest} = context do
      {forest, _id} = Forest.open_root(forest, "SampleApp.Counter.handle_call/3")

      refreshed = TestReach.refresh(context.reach, index, forest)

      assert TestReach.for_function(refreshed, @greet) == Index.tests_for(index, @greet)
      assert [%{hops: 1}] = TestReach.for_function(refreshed, "SampleApp.Counter.handle_call/3")
    end

    test "walks again against an index of another generation", context do
      %{index: index, forest: forest, reach: reach} = context
      {:ok, reloaded} = Index.load("test/fixtures/index.json")

      refreshed = TestReach.refresh(reach, reloaded, forest)

      assert TestReach.for_function(refreshed, @greet) == Index.tests_for(index, @greet)
      assert refreshed.generation == reloaded.generation
    end

    test "tells indexes apart by their generation alone", context do
      %{index: index, forest: forest, reach: reach} = context
      same_generation = %{index | functions: %{}, callers: %{}}

      assert TestReach.refresh(reach, same_generation, forest) === reach
    end
  end
end
