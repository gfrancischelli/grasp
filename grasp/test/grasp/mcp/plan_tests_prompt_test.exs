defmodule Grasp.MCP.PlanTestsPromptTest do
  # The index lives in :persistent_term and the store is a singleton, so taking the index
  # away would be seen by every other test running at the same time.
  use ExUnit.Case, async: false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Grasp.MCP.Prompts.PlanTests

  @fixture Path.expand("../../fixtures/index.json", __DIR__)

  test "with no index loaded, a plan of the changes is refused as a plan of a function is" do
    missing =
      Path.join(System.tmp_dir!(), "grasp-unwritten-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> restart_store(@fixture) end)
    restart_store(missing)

    for target <- ["changes", "SampleApp.Greeter.greet/2"] do
      assert {:error, %Error{message: "no index loaded"}, _frame} =
               PlanTests.get_messages(%{target: target, session: "plan-1"}, Frame.new())
    end
  end

  defp restart_store(path) do
    Application.put_env(:grasp, :index_path, path)
    :ok = Supervisor.terminate_child(Grasp.Supervisor, Grasp.IndexStore)
    {:ok, _pid} = Supervisor.restart_child(Grasp.Supervisor, Grasp.IndexStore)
    :ok
  end
end
