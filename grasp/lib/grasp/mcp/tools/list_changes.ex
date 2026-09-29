defmodule Grasp.MCP.Tools.ListChanges do
  @moduledoc """
  List every function the branch added, modified or removed against the base ref the index
  was built with. The first call for a review of a pull request: it says what the change
  consists of, and each id can then be traced to its entry points with `find_paths`.

  `moduledocs` lists the modules whose moduledoc the branch added, modified or removed,
  sorted by module; `get_module` reads either side of one. `total` counts the functions.

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
        changes = Index.changed_functions(index)

        Tools.reply(frame, %{
          "total" => length(changes),
          "base_ref" => index.git && index.git["base_ref"],
          "changes" =>
            Enum.map(
              changes,
              &%{
                "id" => &1["id"],
                "change" => &1["change"],
                "file" => &1["file"],
                "line" => &1["span"]["start_line"],
                "module" => &1["module"]
              }
            ),
          "moduledocs" =>
            Enum.map(
              Index.changed_modules(index),
              &%{"module" => &1["name"], "change" => &1["change"]}
            )
        })
    end
  end
end
