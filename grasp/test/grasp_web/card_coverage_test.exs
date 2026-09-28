defmodule GraspWeb.CardCoverageTest do
  use ExUnit.Case, async: true

  alias Grasp.{Coverage, Index}
  alias Grasp.Session.Forest
  alias GraspWeb.CardCoverage

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"
  @wrap "SampleApp.Formatter.wrap/1"

  setup do
    {:ok, index} = Index.load("test/fixtures/index.json")
    {forest, _id} = Forest.open_root(Forest.new(), @greet)

    document =
      Coverage.build(
        index,
        %{
          {"SampleApp.Greeter", "greet", 2} => %{9 => 2, 10 => 0},
          {"SampleApp.Formatter", "shout", 1} => %{10 => 0},
          {"SampleApp.Formatter", "wrap", 1} => %{6 => 1}
        },
        %{generated_at: "2026-09-28T12:00:00Z", git_head: nil}
      )

    document = put_in(document, ["functions", @wrap, "source_hash"], "0")
    %{index: index, forest: forest, snapshot: {1, document}}
  end

  test "reads a fresh function's lines and gaps, a stale one as stale", %{
    index: index,
    forest: forest,
    snapshot: snapshot
  } do
    {forest, _id} = Forest.open_root(forest, @shout)
    {forest, _id} = Forest.open_root(forest, @wrap)
    held = CardCoverage.refresh(CardCoverage.new(), snapshot, index, forest)

    assert CardCoverage.loaded?(held)

    assert CardCoverage.for_function(held, @greet) == %{
             lines: %{9 => "run", 10 => "missed"},
             gaps: %{}
           }

    assert CardCoverage.for_function(held, @shout) == %{
             lines: %{10 => "missed"},
             gaps: %{10 => "clause"}
           }

    assert CardCoverage.for_function(held, @wrap) == :stale
    assert CardCoverage.for_function(held, "SampleApp.Nope.gone/0") == :none
  end

  test "without a document nothing is loaded and every card reads as none", %{
    index: index,
    forest: forest
  } do
    held = CardCoverage.refresh(CardCoverage.new(), nil, index, forest)

    refute CardCoverage.loaded?(held)
    assert CardCoverage.for_function(held, @greet) == :none
  end

  describe "refresh/4" do
    # A held reading no document could produce: kept, it proves the function was not read again.
    setup %{index: index, forest: forest, snapshot: snapshot} do
      held = CardCoverage.refresh(CardCoverage.new(), snapshot, index, forest)
      %{held: %{held | readings: %{@greet => :held}}}
    end

    test "keeps what it holds for the same document, index and cards", %{
      held: held,
      index: index,
      forest: forest,
      snapshot: snapshot
    } do
      assert CardCoverage.refresh(held, snapshot, index, forest) == held
    end

    test "reads only the card that joined the canvas", %{
      held: held,
      index: index,
      forest: forest,
      snapshot: snapshot
    } do
      {forest, _id} = Forest.open_root(forest, @shout)
      refreshed = CardCoverage.refresh(held, snapshot, index, forest)

      assert CardCoverage.for_function(refreshed, @greet) == :held
      assert is_map(CardCoverage.for_function(refreshed, @shout))
    end

    test "reads every card again for another document or another index", %{
      held: held,
      index: index,
      forest: forest,
      snapshot: {_generation, document} = snapshot
    } do
      assert is_map(
               CardCoverage.for_function(
                 CardCoverage.refresh(held, {2, document}, index, forest),
                 @greet
               )
             )

      reindexed = %{index | generation: index.generation + 1}

      assert is_map(
               CardCoverage.for_function(
                 CardCoverage.refresh(held, snapshot, reindexed, forest),
                 @greet
               )
             )
    end
  end
end
