defmodule Grasp.MCP.Tools.Coverage do
  @moduledoc """
  What the test suite ran in a function, by id, from the coverage document `mix grasp.cover`
  writes: the `status` of its coverage, the lines that ran (`run`) and the lines that never
  ran (`missed`), each a sorted list of file lines, and the clauses and arms never entered
  (`gaps`, `[start_line, end_line]` ranges). `status` is `fresh` when the counts describe
  the body the index holds, `stale` when the function changed after the coverage was
  written, and `none` when the document holds nothing for it or there is no document; only
  a fresh answer carries lines and gaps. A line absent from both lists is one the coverage
  does not count. `generated_at` is when the coverage was written, `null` without a
  document. When the status is `none`, run `mix grasp.cover` in the project to write the
  coverage, then ask again. After `mix grasp.cover` finishes, call `reload_index` before
  asking: the coverage it wrote is otherwise read within a couple of seconds, and an answer
  taken in between is the previous run's.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools

  schema do
    field(:function_id, :string,
      required: true,
      description:
        "A function id, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )
  end

  @impl true
  def execute(%{function_id: id}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_function(index, id) do
      Tools.reply(frame, answer(record, Grasp.CoverageStore.get()))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp answer(record, document) do
    reading = if document, do: Grasp.Coverage.for_function(document, record), else: :none

    base = %{
      "id" => record["id"],
      "run" => [],
      "missed" => [],
      "gaps" => %{"clauses" => [], "arms" => []},
      "generated_at" => document && document["generated_at"]
    }

    case reading do
      :none ->
        Map.put(base, "status", "none")

      {:stale, _entry} ->
        Map.put(base, "status", "stale")

      {:fresh, %{lines: lines}} ->
        gaps = Grasp.Coverage.gaps(record, lines)

        %{
          base
          | "run" => for({line, count} <- lines, count > 0, do: line) |> Enum.sort(),
            "missed" => for({line, 0} <- lines, do: line) |> Enum.sort(),
            "gaps" => %{"clauses" => gaps.clauses, "arms" => gaps.arms}
        }
        |> Map.put("status", "fresh")
    end
  end
end
