defmodule Grasp.MCP.Server do
  @moduledoc """
  The MCP server exposing the loaded index as read tools.

  Mounted at `/mcp` over Streamable HTTP by `GraspWeb.Router`; one `component` line per
  tool, whose name clients see is the module's basename in snake case.
  """

  use Anubis.Server,
    name: "grasp",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  alias Grasp.MCP.Tools

  component(Tools.SearchFunctions)
  component(Tools.GetFunction)
  component(Tools.GetCallers)
  component(Tools.GetCallees)
  component(Tools.FindPaths)
  component(Tools.ListEntryPoints)
  component(Tools.ListChanges)
  component(Tools.TestsFor)
  component(Tools.UntestedChanges)
  component(Tools.TestReview)
  component(Tools.Coverage)
  component(Tools.RunTests)
  component(Tools.RunCoverage)
  component(Tools.RunStatus)
  component(Tools.ReloadIndex)
  component(Tools.ListModules)
  component(Tools.ListSessions)
  component(Tools.GetSession)
  component(Tools.SetCards)
  component(Tools.OpenCard)
  component(Tools.CloseCard)
  component(Tools.FocusCard)
  component(Tools.HighlightCard)
  component(Tools.SetView)
  component(Tools.GroupCards)
  component(Tools.UngroupCards)
  component(Tools.RenameGroup)
  component(Tools.ListComments)
  component(Tools.AddComment)
  component(Tools.ReplyComment)
  component(Tools.ResolveComment)
  component(Tools.PublishComments)
end
