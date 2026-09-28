defmodule Grasp.MCP.CoverageToolTest do
  # The coverage document lives in :persistent_term, so loading one would be seen by every
  # other test running at the same time.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.{Coverage, CoverageStore, IndexStore}
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @shout "SampleApp.Formatter.shout/1"
  @wrap "SampleApp.Formatter.wrap/1"
  @generated_at "2026-09-28T12:00:00Z"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp coverage(id) do
    {:reply, resp, _} = Tools.Coverage.execute(%{function_id: id}, %Frame{})
    refute resp.isError
    json!(resp)
  end

  setup do
    path = CoverageStore.path()

    on_exit(fn ->
      File.rm(path)
      :ok = CoverageStore.reload()
    end)

    %{path: path}
  end

  describe "with coverage loaded" do
    setup %{path: path} do
      document =
        Coverage.build(
          IndexStore.get(),
          %{
            {"SampleApp.Greeter", "greet", 2} => %{9 => 2, 10 => 0, 11 => 3},
            {"SampleApp.Formatter", "shout", 1} => %{9 => 1, 10 => 0},
            {"SampleApp.Formatter", "wrap", 1} => %{6 => 4}
          },
          %{generated_at: @generated_at, git_head: nil}
        )

      # wrap/1's entry is written against a body other than the one the index holds.
      document = put_in(document, ["functions", @wrap, "source_hash"], "0")
      :ok = Coverage.write(document, path)
      :ok = CoverageStore.reload()
    end

    test "a fresh function answers the lines that ran and missed, sorted, under its canonical id" do
      assert coverage("SampleApp.Greeter.greet/1") == %{
               "id" => @greet,
               "status" => "fresh",
               "run" => [9, 11],
               "missed" => [10],
               "gaps" => %{"clauses" => [], "arms" => []},
               "generated_at" => @generated_at
             }
    end

    test "a clause whose every counted line ran zero times is a gap" do
      assert %{"status" => "fresh", "run" => [9], "missed" => [10]} = body = coverage(@shout)
      assert body["gaps"] == %{"clauses" => [[10, 10]], "arms" => []}
    end

    test "a stale function answers no lines and no gaps" do
      assert coverage(@wrap) == %{
               "id" => @wrap,
               "status" => "stale",
               "run" => [],
               "missed" => [],
               "gaps" => %{"clauses" => [], "arms" => []},
               "generated_at" => @generated_at
             }
    end

    test "a function the document holds nothing for is none" do
      assert %{"status" => "none", "run" => [], "missed" => [], "generated_at" => @generated_at} =
               coverage(@greet_all)
    end
  end

  test "without a document every function is none, written at no time" do
    assert CoverageStore.get() == nil

    assert coverage(@greet) == %{
             "id" => @greet,
             "status" => "none",
             "run" => [],
             "missed" => [],
             "gaps" => %{"clauses" => [], "arms" => []},
             "generated_at" => nil
           }
  end
end
