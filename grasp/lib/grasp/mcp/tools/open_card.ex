defmodule Grasp.MCP.Tools.OpenCard do
  @moduledoc """
  Open one function as a card and focus it. With `parent_card_id` an edge runs from that
  card, and the call it was opened from is marked in the caller, exactly as a click in the
  viewer would; without one the card starts at the left edge. A function already on screen
  is never drawn twice: the existing card is focused and gains an edge from the caller.

  A module's name opens that module's card, which shows its moduledoc. A module card calls
  nothing and nothing calls it, so it opens at the left edge, without a `parent_card_id`.

  Replies with the whole graph plus `card_id`, the id of the card that is now focused.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Cards
  alias Grasp.MCP.Tools
  alias Grasp.Session
  alias Grasp.Session.Forest

  @session_field Tools.session_field_description()

  schema do
    field(:session, :string,
      default: "default",
      description: @session_field
    )

    field(:function_id, :string,
      required: true,
      description:
        "The function to open, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`. A module's name, as in `SampleApp.Greeter`, opens its module card"
    )

    field(:parent_card_id, :integer,
      description: "Card that calls this one; omit to start the card at the left edge"
    )

    embeds_one :highlight, description: "What to point at inside the card; omit for nothing" do
      field(:call, :string, description: "A call the function makes, to outline")

      field(:lines, {:list, :integer},
        description: "First and last line to shade, both inside the function"
      )
    end
  end

  @impl true
  def execute(%{session: session, function_id: function_id} = params, frame) do
    asked = Map.get(params, :highlight)

    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_record(index, function_id),
         {:ok, highlight} <- Cards.validate_highlight(index, record["id"], asked),
         {:ok, forest} <- open(session, index, Map.get(params, :parent_card_id), record) do
      card_id = forest.focus
      forest = if asked, do: Session.set_highlight(session, card_id, highlight), else: forest

      Tools.reply(frame, Map.put(Forest.to_map(forest), "card_id", card_id))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp open(session, _index, nil, record) do
    with {:ok, session} <- Tools.ensure_session(session) do
      {:ok, Session.open_root(session, record["id"])}
    end
  end

  defp open(session, index, parent_card_id, record) do
    with {:ok, parent} <- Tools.fetch_card(session, parent_card_id),
         :ok <- Cards.hangs(record, parent.function_id) do
      opened_by = Cards.opened_by(index, parent.function_id, record["id"])
      {:ok, Session.open_child(session, parent_card_id, record["id"], opened_by)}
    end
  end
end
