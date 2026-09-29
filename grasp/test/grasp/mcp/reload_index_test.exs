defmodule Grasp.MCP.Tools.ReloadIndexTest do
  # A successful reload broadcasts `:index_reloaded` to every mounted view, which recomputes
  # its sidebar defaults and empties its selection, so this must not run beside them.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.{Coverage, CoverageStore, Index, IndexStore}
  alias Grasp.MCP.Tools

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  test "re-reads the watched file and reports what it now holds" do
    {:reply, resp, _frame} = Tools.ReloadIndex.execute(%{}, %Frame{})

    refute resp.isError
    body = json!(resp)

    index = IndexStore.get()

    assert body["path"] == IndexStore.path()
    assert body["functions"] == length(Index.functions(index))
    assert body["changed"] == length(Index.changed_functions(index))
    assert body["functions"] > 0
    assert body["changed"] > 0
    assert body["base_ref"] == "main"
    assert Map.has_key?(body, "branch") and Map.has_key?(body, "head")
  end

  test "re-reads a coverage document rewritten since the store last read it" do
    path = CoverageStore.path()
    on_exit(fn -> File.rm(path) && CoverageStore.reload() end)

    written = fn generated_at, counts ->
      IndexStore.get()
      |> Coverage.build(%{{"SampleApp.Formatter", "shout", 1} => counts}, %{
        generated_at: generated_at,
        git_head: nil
      })
      |> Coverage.write(path)
    end

    :ok = written.("2026-09-28T12:00:00Z", %{9 => 1, 10 => 0})
    :ok = CoverageStore.reload()
    :ok = written.("2026-09-28T12:05:00Z", %{9 => 1, 10 => 1})

    {:reply, resp, _frame} = Tools.ReloadIndex.execute(%{}, %Frame{})
    refute resp.isError
    assert json!(resp)["coverage_generated_at"] == "2026-09-28T12:05:00Z"

    {:reply, resp, _frame} =
      Tools.Coverage.execute(%{function_id: "SampleApp.Formatter.shout/1"}, %Frame{})

    assert %{"generated_at" => "2026-09-28T12:05:00Z", "missed" => []} = json!(resp)
  end
end
