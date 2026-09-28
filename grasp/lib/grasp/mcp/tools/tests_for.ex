defmodule Grasp.MCP.Tools.TestsFor do
  @moduledoc """
  List the tests that reach a function, by id, nearest first: each test with its name, its
  `describe`, its file and the number of call edges between it and the function. A test
  calling the function directly is one hop away; a setup reaching it counts for every test
  of its module. Use it to see what exercises a function before trusting a change to it.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Index
  alias Grasp.MCP.Tools

  schema do
    field(:function_id, :string,
      required: true,
      description:
        "A function id, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
    )

    field(:max_hops, :integer,
      default: 4,
      min: 1,
      max: 8,
      description: "How many call edges a test may be away; default 4, maximum 8"
    )
  end

  @impl true
  def execute(%{function_id: id} = params, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_function(index, id) do
      tests =
        index
        |> Index.tests_for(record["id"], Map.get(params, :max_hops, 4))
        |> Enum.map(fn %{test: test_id, hops: hops} ->
          test = index.functions[test_id]

          %{
            "id" => test_id,
            "name" => get_in(test, ["test", "name"]),
            "describe" => get_in(test, ["test", "describe"]),
            "file" => test["file"],
            "hops" => hops
          }
        end)

      Tools.reply(frame, %{"id" => record["id"], "tests" => tests})
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
