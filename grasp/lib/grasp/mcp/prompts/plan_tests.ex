defmodule Grasp.MCP.Prompts.PlanTests do
  @moduledoc """
  Plan tests for a function, or for the review's changes, on the canvas of a review session:
  the functions under test grouped with the tests that reach them, and a comment on every
  clause, arm and function no test covers, saying what a test would have to exercise. The
  plan stops short of writing a test, so the reader reviews it first.

  Answers one user message: the request, the recipe of `Grasp.TestPlan`, and the session
  its cards and comments go to. A function id the index does not hold is an error.
  """

  use Anubis.Server.Component, type: :prompt

  alias Anubis.MCP.Error
  alias Anubis.Server.Response
  alias Grasp.Session.Disk
  alias Grasp.TestPlan

  schema do
    field(:target, :string,
      required: true,
      description:
        "A function id, `Module.fun/arity`, or `changes` for the functions the review changed"
    )

    field(:session, :string,
      required: true,
      description: "The review session the plan's cards and comments go to; #{Disk.name_rule()}"
    )
  end

  @impl true
  def get_messages(%{target: target, session: session}, frame) do
    with {:ok, session} <- session(session),
         {:ok, target} <- target(target) do
      text = """
      #{TestPlan.request(target)}.

      #{TestPlan.recipe()}

      The Grasp viewer session to lay the plan out in is "#{session}". Pass session: "#{session}" to every grasp card tool and every comment tool.
      """

      {:reply, Response.user_message(Response.prompt(), String.trim_trailing(text)), frame}
    else
      {:error, message} -> {:error, Error.execution(message), frame}
    end
  end

  defp session(session) do
    if Disk.valid_name?(session), do: {:ok, session}, else: {:error, Disk.name_rule()}
  end

  defp target("changes"), do: {:ok, :changes}

  defp target(function_id) do
    case Grasp.IndexStore.get() do
      nil ->
        {:error, "no index loaded"}

      index ->
        with {:ok, record} <- Grasp.MCP.Tools.fetch_function(index, function_id),
             do: {:ok, record["id"]}
    end
  end
end
