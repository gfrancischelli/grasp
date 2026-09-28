defmodule Grasp.MCP.Tools.RunTests do
  @moduledoc """
  Start a run of the project's tests with `mix grasp.test`: the tests named by id in
  `test_ids`, or, with `changed: true`, the tests the branch added or modified against the
  index's base ref. Pass exactly one of the two. A test's id quotes its name, as in
  `SampleApp.CheckTest."test counts"/1`, and every id must name a test the index holds; the
  ids it holds no test for are answered as an error, and nothing starts.

  Runs are asynchronous: this answers at once with `{"started": run}`, or with
  `{"running": run}` when another run is under way, which is left to finish. Call
  `run_status` to read the outcome — the output while it runs, and each test's result once
  it has finished.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools
  alias Grasp.Runs

  schema do
    field(:test_ids, {:list, :string},
      description:
        "The tests to run, by id; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )

    field(:changed, :boolean,
      description: "true to run the tests the branch added or modified, in place of `test_ids`"
    )
  end

  @impl true
  def execute(params, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, ids} <- selection(index, Map.get(params, :test_ids), Map.get(params, :changed)) do
      Tools.started(frame, Runs.start_tests(ids))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp selection(index, [_ | _] = ids, changed) when changed in [nil, false] do
    ids = Enum.uniq(ids)

    case Enum.reject(ids, &test?(index, &1)) do
      [] ->
        {:ok, ids}

      unknown ->
        {:error, "the index holds no test for " <> Enum.map_join(unknown, ", ", &inspect/1)}
    end
  end

  defp selection(index, ids, true) when ids in [nil, []] do
    cond do
      get_in(index.git || %{}, ["base_ref"]) == nil ->
        {:error, "the index has no base ref; run mix grasp.index --base REF first"}

      (ids = Index.changed_test_ids(index)) != [] ->
        {:ok, ids}

      true ->
        {:error, "the branch added or modified no test"}
    end
  end

  defp selection(_index, _ids, _changed),
    do: {:error, "pass either test_ids, a non-empty list of test ids, or changed: true"}

  defp test?(index, id) do
    case Index.fetch_function(index, id) do
      {:ok, %{"kind" => "test", "id" => ^id} = record} -> record["removed"] != true
      _not_a_test -> false
    end
  end
end
