defmodule Grasp.MCP.Tools.RunCoverage do
  @moduledoc """
  Start a coverage run of the project's test suite with `mix grasp.cover`, which writes the
  coverage the `coverage` tool reads.

  Runs are asynchronous: this answers at once with `{"started": run}`, or with
  `{"running": run}` when another run is under way, which is left to finish. Call
  `run_status` to read the outcome, then `coverage` for what the suite ran in a function.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame), do: Tools.started(frame, Grasp.Runs.start_coverage())
end
