defmodule Grasp.MCP.Tools.SetCards do
  @moduledoc """
  Lay out a whole reading of the code at once: replace every card in a review session with
  the graph you describe, so the reviewer sees the path you walked rather than the order you
  walked it in.

  Callers are given before what they call. `key` is your own name for a card, and a later
  card hangs under an earlier one by naming it in `parent_key`; a card with no `parent_key`
  starts at the left edge. A function named twice is one card with an edge from each caller,
  so a helper three functions call is read once rather than drawn three times. Each card may
  point at one thing inside it — a call it makes, or a range of its lines. Cards sharing a
  `group` title are framed together under it, which is how several flows are told apart on
  one canvas. Nothing changes unless every card is good.
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

    embeds_many :cards, required: true, description: "The cards to show, callers first" do
      field(:key, :string,
        required: true,
        description:
          "Your name for this card, which later cards point at through `parent_key`. Two entries naming the same function are one card"
      )

      field(:function_id, :string,
        required: true,
        description:
          "The function the card shows, `Module.fun/arity`; a test's id quotes its name, as in `SampleApp.CheckTest.\"test counts\"/1`"
      )

      field(:parent_key, :string,
        description:
          "`key` of the card that calls this one; omit to start the card at the left edge"
      )

      field(:group, :string,
        description:
          "Title of the group this card belongs to; cards sharing a title are drawn together under it"
      )

      embeds_one :highlight, description: "What to point at inside the card; omit for nothing" do
        field(:call, :string, description: "A call the function makes, to outline")

        field(:lines, {:list, :integer},
          description: "First and last line to shade, both inside the function"
        )
      end
    end
  end

  @impl true
  def execute(%{session: session, cards: cards}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, specs} <- Cards.prepare(index, cards),
         {:ok, session} <- Tools.ensure_session(session),
         {:ok, forest} <- Session.set_cards(session, specs) do
      Tools.reply(frame, Forest.to_map(forest))
    else
      # Cards.prepare/2 enforces the rule Forest.replace/1 does, so the unknown parent is
      # unreachable today; it is here so the two drifting apart is an error, not a crash.
      {:error, {:unknown_parent, key}} -> Tools.error(frame, "unknown parent key: #{key}")
      {:error, reason} -> Tools.error(frame, reason)
    end
  end
end
