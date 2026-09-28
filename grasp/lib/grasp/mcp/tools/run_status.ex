defmodule Grasp.MCP.Tools.RunStatus do
  @moduledoc """
  Read what `run_tests` and `run_coverage` started. Answers one of:

  - `{"running": run}` while a run is under way, `run.output` holding its last 50 lines of
    output, oldest first, and `run.line_count` how many it has printed in all;
  - `{"last": run}` once none is, for the last run that finished: its `exit_status` (`0`
    when every test passed, `null` for a cancelled run) and `cancelled`, and for a test
    run `tests`, each test it ran with its `status` in the results document: `passed`,
    `failed`, `skipped`, `excluded`, `invalid`, `stale` for a result recorded against
    another version of the test, or `none` when the run recorded nothing for it — as a
    project that does not compile records nothing. A failed test carries `error`, its
    first error's `message`, and for an assertion `left` and `right` as ExUnit prints them,
    with `frame`, the deepest frame of its stacktrace in a function the index holds
    (`id`, `file`, `line`), `null` when none is;
  - `{"idle": true}` before any run.

  A test's id quotes its name, as in `SampleApp.CheckTest."test counts"/1`; read it, or
  the function its failure's frame names, with `get_function`.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools
  alias Grasp.TestFailure
  alias Grasp.TestResults

  @output_lines 50

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Grasp.Runs.status() do
      %{current: :idle, last: nil} ->
        Tools.reply(frame, %{"idle" => true})

      %{current: :idle, last: %{kind: :tests} = last} ->
        case Tools.index() do
          {:ok, index} ->
            run = Map.put(Tools.run(last), "tests", tests(index, last))
            Tools.reply(frame, %{"last" => run})

          {:error, response} ->
            Tools.error(frame, response)
        end

      %{current: :idle, last: last} ->
        Tools.reply(frame, %{"last" => Tools.run(last)})

      %{current: run} ->
        output = Enum.take(run.output, -@output_lines)
        Tools.reply(frame, %{"running" => Map.put(Tools.run(run), "output", output)})
    end
  end

  # A test run's argv names its tests after the `--` ending the task's switches.
  defp tests(index, run) do
    ids =
      case Enum.split_while(run.argv, &(&1 != "--")) do
        {_switches, ["--" | ids]} -> ids
        {_argv, []} -> []
      end

    document = Grasp.ResultsStore.get() || TestResults.new()

    Enum.map(ids, fn id ->
      case Grasp.Index.fetch_function(index, id) do
        {:ok, record} -> result(index, record, TestResults.for_test(document, record), run)
        :error -> %{"id" => id, "status" => "none"}
      end
    end)
  end

  defp result(index, record, reading, run) do
    base = %{"id" => record["id"]}

    case reading do
      {:fresh, result} ->
        if recorded_since?(result, run.started_at),
          do: Map.merge(base, outcome(index, record, result)),
          else: Map.put(base, "status", "none")

      {:stale, _result} ->
        Map.put(base, "status", "stale")

      :none ->
        Map.put(base, "status", "none")
    end
  end

  # A result recorded before the run started belongs to an earlier run: this one recorded
  # nothing for the test.
  defp recorded_since?(%{"finished_at" => finished_at}, started_at) when is_binary(finished_at) do
    case DateTime.from_iso8601(finished_at) do
      {:ok, finished_at, _offset} -> DateTime.compare(finished_at, started_at) != :lt
      {:error, _reason} -> false
    end
  end

  defp recorded_since?(_result, _started_at), do: false

  defp outcome(index, record, %{"status" => "failed"} = result) do
    error =
      case result["errors"] do
        [%{} = first | _] ->
          %{
            "message" => first["message"],
            "left" => first["left"],
            "right" => first["right"],
            "frame" => indexed_frame(index, record, first)
          }

        _none ->
          nil
      end

    %{"status" => "failed", "error" => error}
  end

  defp outcome(_index, _record, %{"status" => status}), do: %{"status" => status}

  defp indexed_frame(index, record, error) do
    case Enum.find(TestFailure.trace(index, record, error), & &1.id) do
      nil -> nil
      frame -> %{"id" => frame.id, "file" => frame.file, "line" => frame.line}
    end
  end
end
