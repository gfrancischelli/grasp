defmodule Grasp.MCP.Tools.ReloadIndex do
  @moduledoc """
  Reload the index file the viewer watches, and the coverage and test results beside it, and
  report what they now hold: the path, how many functions the index carries, how many of
  them the branch changed, the git refs it was built against, and when the loaded coverage
  was written (`coverage_generated_at`, `null` without coverage).

  Call it as soon as `mix grasp.index`, `mix grasp.cover` or `mix grasp.test` finishes —
  after an edit, or after checking out another branch — and before `list_changes`,
  `coverage` or any other read. The viewer picks a rewritten file up on its own within a
  couple of seconds, so a read taken in between answers from the file the command replaced;
  reloading first makes the next read describe what is on disk.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.{CoverageStore, Index, IndexStore, ResultsStore}
  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case IndexStore.reload() do
      :ok ->
        # A coverage or results file that cannot be read keeps the document the store holds,
        # which the store logs; the index reloaded all the same.
        _coverage = CoverageStore.reload()
        _results = ResultsStore.reload()
        index = IndexStore.get()
        git = index.git || %{}
        coverage = CoverageStore.get()

        Tools.reply(frame, %{
          "path" => IndexStore.path(),
          "functions" => length(Index.functions(index)),
          "changed" => length(Index.changed_functions(index)),
          "base_ref" => git["base_ref"],
          "branch" => git["branch"],
          "head" => git["head"],
          "coverage_generated_at" => coverage && coverage["generated_at"]
        })

      {:error, :no_path} ->
        Tools.error(frame, "no index path is being watched")

      {:error, reason} ->
        Tools.error(frame, "could not load the index: " <> inspect(reason))
    end
  end
end
