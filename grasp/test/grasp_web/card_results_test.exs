defmodule GraspWeb.CardResultsTest do
  use ExUnit.Case, async: true

  alias Grasp.{Index, TestResults}
  alias Grasp.Session.Forest
  alias GraspWeb.{CardResults, TestReach}

  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @reply ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
  @plain ~s|SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1|
  @verified ~s|SampleAppWeb.RoutesTest."test a verified path reaches the controller"/1|
  @handle_call "SampleApp.Counter.handle_call/3"
  @greet "SampleApp.Greeter.greet/2"

  setup do
    {:ok, index} = Index.load("test/fixtures/index.json")

    document =
      TestResults.merge(
        nil,
        %{
          @init => %{"status" => "passed"},
          @reply => %{"status" => "failed"},
          @plain => %{"status" => "excluded"},
          @verified => %{"status" => "invalid"}
        },
        %{run_id: "r1", finished_at: "2026-09-28T12:00:00Z", index: index}
      )

    forest =
      Enum.reduce([@init, @reply, @plain, @verified, @handle_call, @greet], Forest.new(), fn
        id, forest ->
          {forest, _card} = Forest.open_root(forest, id)
          forest
      end)

    %{index: index, forest: forest, snapshot: {1, document}}
  end

  test "a test reads its worn result, and a function the failures among its tests", %{
    index: index,
    forest: forest,
    snapshot: snapshot
  } do
    held = refresh(CardResults.new(), snapshot, index, forest)

    assert CardResults.for_function(held, @init) == {:result, "passed"}
    assert CardResults.for_function(held, @reply) == {:result, "failed"}
    assert CardResults.for_function(held, @handle_call) == {:failing, 1}
    # A run that loaded a test and did not run it says nothing about the test's code; a test
    # whose setup_all failed did not pass, and counts as failing.
    assert CardResults.for_function(held, @plain) == :none
    assert CardResults.for_function(held, @verified) == {:result, "invalid"}
    assert CardResults.for_function(held, @greet) == {:failing, 1}
    assert CardResults.for_function(held, "SampleApp.Nope.gone/0") == :none
  end

  test "a result recorded against another body reads stale and counts no failure", %{
    index: index,
    forest: forest,
    snapshot: {generation, document}
  } do
    document = put_in(document, ["tests", @reply, "source_hash"], "0")
    held = refresh(CardResults.new(), {generation, document}, index, forest)

    assert CardResults.for_function(held, @reply) == {:result, "stale"}
    assert CardResults.for_function(held, @handle_call) == :none
  end

  test "the same document and index hand the held readings back; another document reads again",
       %{index: index, forest: forest, snapshot: {generation, document} = snapshot} do
    held = refresh(CardResults.new(), snapshot, index, forest)

    assert refresh(held, snapshot, index, forest) === held

    passed = put_in(document, ["tests", @reply, "status"], "passed")
    again = refresh(held, {generation + 1, passed}, index, forest)

    assert CardResults.for_function(again, @reply) == {:result, "passed"}
    assert CardResults.for_function(again, @handle_call) == :none
  end

  test "a fresh failure holds its errors; a stale one and any other status hold none", %{
    index: index,
    forest: forest,
    snapshot: {generation, document}
  } do
    errors = [%{"kind" => "error", "message" => "boom", "stacktrace" => []}, "not an error"]
    document = put_in(document, ["tests", @reply, "errors"], errors)
    held = refresh(CardResults.new(), {generation, document}, index, forest)

    assert CardResults.failures(held, @reply) == [hd(errors)]
    assert CardResults.failures(held, @init) == []
    assert CardResults.failures(held, @verified) == []
    assert CardResults.failures(held, @handle_call) == []
    assert CardResults.failures(nil, @reply) == []

    stale = put_in(document, ["tests", @reply, "source_hash"], "0")
    held = refresh(held, {generation + 1, stale}, index, forest)
    assert CardResults.failures(held, @reply) == []
  end

  test "without a document every card reads as none", %{index: index, forest: forest} do
    held = refresh(CardResults.new(), nil, index, forest)
    assert CardResults.for_function(held, @init) == :none
    assert CardResults.for_function(nil, @init) == :none
  end

  defp refresh(held, snapshot, index, forest),
    do:
      CardResults.refresh(
        held,
        snapshot,
        index,
        forest,
        TestReach.refresh(TestReach.new(), index, forest)
      )
end
