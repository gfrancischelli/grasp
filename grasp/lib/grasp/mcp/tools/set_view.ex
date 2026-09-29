defmodule Grasp.MCP.Tools.SetView do
  @moduledoc """
  Show a card as its source or as its diff against the base ref, which is how you point at
  what a pull request did to one function rather than at the function.

  Only a modified function has two sides: asking for the diff of anything else is an error,
  and `source` is always available.

  A module card shows its moduledoc, and offers `doc` for the rendered text, `source` for
  the moduledoc's lines and `diff` for a moduledoc the branch modified or removed, as far as
  the moduledoc has each; a view it does not offer is an error. A function card has no
  `doc` view.

  `context` says how much of that diff is drawn — the changed hunks with three lines around
  them, or every line — and is remembered whichever view the card is in, so setting it
  alongside `source` decides what the card shows the next time it is swapped back.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.Diff
  alias Grasp.MCP.Tools
  alias Grasp.ModuleCard
  alias Grasp.Session
  alias Grasp.Session.Forest

  @session_field Tools.session_field_description()

  schema do
    field(:session, :string,
      default: "default",
      description: @session_field
    )

    field(:card_id, :integer, required: true, description: "Id of the card to swap")

    field(:view, :string,
      required: true,
      enum: ["doc", "source", "diff"],
      description:
        "`source` for the branch's version, `diff` for the change against the base, " <>
          "`doc` for a module card's rendered moduledoc"
    )

    field(:context, :string,
      enum: ["hunks", "full", "auto"],
      description:
        "How much of the diff to draw: `hunks` for the changed lines with three lines of " <>
          "context, `full` for every line, `auto` for hunks past 100 lines. Left alone when omitted"
    )
  end

  @impl true
  def execute(%{session: session, card_id: card_id, view: asked} = params, frame) do
    with {:ok, view} <- view(asked),
         {:ok, context} <- context(Map.get(params, :context)),
         {:ok, card} <- Tools.fetch_card(session, card_id),
         :ok <- comparable(view, card.function_id) do
      forest = Session.set_view(session, card_id, view)
      forest = if context, do: Session.set_context(session, card_id, context), else: forest
      Tools.reply(frame, Forest.to_map(forest))
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  # The session holds the view as an atom, and a name it has none for is the client's
  # error rather than a card that quietly stays as it was.
  defp view("doc"), do: {:ok, :doc}
  defp view("source"), do: {:ok, :source}
  defp view("diff"), do: {:ok, :diff}
  defp view(other), do: {:error, "unknown view: #{other}"}

  # An absent `context` leaves the card's own preference standing, which is what makes the
  # field optional rather than defaulted.
  defp context(nil), do: {:ok, nil}
  defp context("hunks"), do: {:ok, :hunks}
  defp context("full"), do: {:ok, :full}
  defp context("auto"), do: {:ok, :auto}
  defp context(other), do: {:error, "unknown context: #{other}"}

  # A function card's source needs no record: it is the view a card whose function has left
  # the index still has.
  defp comparable(:source, function_id) do
    if Grasp.Index.module_id?(function_id), do: comparable_record(:source, function_id), else: :ok
  end

  defp comparable(:doc, function_id) do
    if Grasp.Index.module_id?(function_id),
      do: comparable_record(:doc, function_id),
      else: {:error, "no doc view for #{function_id}"}
  end

  defp comparable(view, function_id), do: comparable_record(view, function_id)

  defp comparable_record(view, function_id) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_record(index, function_id) do
      offered(view, record)
    end
  end

  defp offered(view, %{"kind" => "module", "id" => id} = record) do
    if view in ModuleCard.views(record),
      do: :ok,
      else: {:error, "no #{view} for #{id}"}
  end

  defp offered(:doc, record), do: {:error, "no doc view for #{record["id"]}"}

  defp offered(:diff, record),
    do: if(Diff.diffable?(record), do: :ok, else: {:error, "no diff for #{record["id"]}"})
end
