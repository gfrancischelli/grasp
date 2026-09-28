defmodule Grasp.MCP.Tools.UntestedChanges do
  @moduledoc """
  List the application functions the branch added or modified that no test reaches within
  four call edges, sorted by id. Tests, setups and functions under the project's test paths
  are left out, and so are removed functions. Each id can then be read with `get_function`
  and its nearest tests confirmed absent with `tests_for`.

  Empty for an index built without a base ref, which has nothing to compare against.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Tools.index() do
      {:error, response} ->
        {:reply, response, frame}

      {:ok, index} ->
        Tools.reply(frame, %{
          "functions" =>
            Enum.map(
              Index.untested_changes(index),
              &%{"id" => &1["id"], "file" => &1["file"], "change" => &1["change"]}
            )
        })
    end
  end
end
