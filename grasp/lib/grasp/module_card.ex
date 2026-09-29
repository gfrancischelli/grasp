defmodule Grasp.ModuleCard do
  @moduledoc """
  Which views a module card offers and which one it shows.

  A module card shows a module's moduledoc: rendered as text (`:doc`), as the attribute's
  lines (`:source`), or as its diff against the base (`:diff`). Which of the three a record
  has follows from its moduledoc alone, so the viewer's card and toggle and the MCP tools
  that set a card's view read the same answer from here.
  """

  alias Grasp.Diff
  alias Grasp.Session.Forest

  @typedoc "A view a module card can render in."
  @type view :: :doc | :source | :diff

  @doc """
  The views a module card offers for `record`, in the order its toggle lists them: `:doc`
  for a module whose moduledoc is text, `@moduledoc false` or absent, since the view says
  which of the three it is; `:source` for any moduledoc the record has lines of; `:diff` when
  the moduledoc is modified, and when the branch took it off a module it keeps, where the
  diff is the base lines, every one deleted. A moduledoc that is not a literal has no text to
  render and is read as source.
  """
  @spec views(map()) :: [view()]
  def views(record) do
    doc = record["doc"]
    source? = is_binary(record["source"]) and is_map(record["span"])
    literal? = is_map(doc) and (is_binary(doc["text"]) or doc["hidden"] == true)

    views =
      cond do
        not source? -> [:doc]
        literal? -> [:doc, :source]
        true -> [:source]
      end

    if Diff.diffable?(record) or removed_moduledoc?(record),
      do: views ++ [:diff],
      else: views
  end

  @doc """
  The view a module card renders in, of the `views` it offers: the one the card holds when it
  is offered, and the first offered otherwise, which is how `:auto` reads.
  """
  @spec view(Forest.view(), [view()]) :: view()
  def view(view, [first | _rest] = views), do: if(view in views, do: view, else: first)

  @doc """
  Whether `record` is a module the branch keeps whose moduledoc it removed: such a module
  has no moduledoc lines of its own, only the base's, and its diff is those lines, every one
  deleted.
  """
  @spec removed_moduledoc?(map()) :: boolean()
  def removed_moduledoc?(record) do
    record["change"] == "removed" and record["removed"] != true and
      is_binary(record["base_source"]) and not is_binary(record["source"])
  end
end
