defmodule Grasp.MCP.Cards do
  @moduledoc """
  Turns the cards an agent describes into a forest spec, or says why it cannot.

  Pure over a `Grasp.Index`: index in, `t:Grasp.Session.Forest.spec/0` list out, so the MCP
  tools stay adapters and every rule an agent can break is stated once here.

  Two things need resolving before the forest can hold a card. A function reached through
  a default-argument arity (`Greeter.greet/1`) is stored under the arity it is defined at
  (`greet/2`), so the card shows the definition. But the parent card marks the call the
  child was opened from by matching the raw target the source wrote, so `opened_by` keeps
  the caller's spelling — the canonical id only decides which call it is. A highlight
  resolves the same way: `%{"call" => target}` is stored as the raw target of the call it
  matched, because that is what the rendered card carries in `data-target`.

  A card's `function_id` may also be a module's name, which opens that module's card: its
  moduledoc. A module card calls nothing and is called by nothing, so it opens at the left
  edge and no card hangs under it; its highlight shades lines of the moduledoc, never a call.
  """

  alias Grasp.Index
  alias Grasp.Links
  alias Grasp.Paths
  alias Grasp.Session.Forest

  @typedoc """
  A card as the tool schema hands it over: atom keys, and the optional ones absent rather
  than nil when the client left them out.
  """
  @type input :: %{
          required(:key) => String.t(),
          required(:function_id) => String.t(),
          optional(:parent_key) => String.t() | nil,
          optional(:group) => String.t() | nil,
          optional(:highlight) => highlight_input()
        }
  @typedoc "A highlight as the tool schema hands it over; an empty one marks nothing."
  @type highlight_input ::
          nil | %{optional(:call) => String.t() | nil, optional(:lines) => [integer()] | nil}

  @doc """
  Validates and links `cards`, in order, into the spec `Grasp.Session.set_cards/2` takes.

  Every `function_id` must be a function or a module in the index and every `parent_key`
  must name an earlier card that is not a module card; a module card takes no `parent_key`.
  Unknown functions and modules are collected into one message so an agent fixes them in a
  single round trip rather than one per call.

  A `group` is a title rather than an id: cards carrying the same title land in one group,
  which the canvas draws as a section of its own. A blank title means no group, so a model
  that fills the field with nothing does not open an unnamed frame.
  """
  @spec prepare(Index.t(), [input()]) :: {:ok, [Forest.spec()]} | {:error, String.t()}
  def prepare(%Index{} = index, cards) when is_list(cards) do
    case Enum.filter(cards, &(Index.fetch_record(index, &1.function_id) == :error)) do
      [] -> link(index, cards)
      unknown -> {:error, unknown(unknown)}
    end
  end

  defp unknown(cards) do
    {modules, functions} =
      cards |> Enum.map(& &1.function_id) |> Enum.split_with(&Index.module_id?/1)

    [{"unknown functions: ", functions}, {"unknown functions or modules: ", modules}]
    |> Enum.reject(fn {_label, ids} -> ids == [] end)
    |> Enum.map_join("; ", fn {label, ids} -> label <> Enum.join(ids, ", ") end)
    |> Kernel.<>(if modules == [], do: "", else: " — a function id ends in /arity")
  end

  @doc """
  Checks `highlight` against the function or module card it marks.

  A call must be one the function makes, visible or hidden, and is stored as that call's
  raw target; a module card makes none. A line range must lie inside the record's span,
  which for a module is its moduledoc's lines. Nothing, or an empty highlight, marks
  nothing.
  """
  @spec validate_highlight(Index.t(), String.t(), highlight_input()) ::
          {:ok, Forest.highlight()} | {:error, String.t()}
  def validate_highlight(%Index{} = index, function_id, highlight) do
    case Grasp.MCP.Tools.fetch_record(index, function_id) do
      {:error, _message} = error -> error
      {:ok, record} -> highlight(index, record, get(highlight, :call), get(highlight, :lines))
    end
  end

  @doc """
  The raw call target on `parent_id` that opens `child_id`, or `child_id` itself.

  A call written against a default-argument arity resolves to the definition the child
  card shows, and it is the raw spelling that marks the call as open in the parent.
  """
  @spec opened_by(Index.t(), String.t(), String.t()) :: String.t()
  def opened_by(%Index{} = index, parent_id, child_id),
    do: Links.call_target(index, parent_id, child_id) || child_id

  # `opened` maps each key seen so far to the id its card shows, which is both the check
  # that a `parent_key` names an earlier card and the record `opened_by` is read from.
  defp link(index, cards) do
    cards
    |> Enum.reduce_while({[], %{}}, fn card, {specs, opened} ->
      case spec(index, opened, card) do
        {:ok, spec} -> {:cont, {[spec | specs], Map.put(opened, spec.key, spec.function_id)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      {specs, _opened} -> {:ok, Enum.reverse(specs)}
    end
  end

  defp spec(index, opened, card) do
    parent_key = get(card, :parent_key)
    # Safe because prepare/2 has already answered for every function_id in the list.
    {:ok, record} = Index.fetch_record(index, card.function_id)

    with {:ok, parent_id} <- parent(opened, parent_key),
         :ok <- hangs(record, parent_id),
         {:ok, highlight} <- validate_highlight(index, record["id"], get(card, :highlight)) do
      {:ok,
       %{
         key: card.key,
         function_id: record["id"],
         parent_key: parent_key,
         group: title(get(card, :group)),
         opened_by: parent_id && opened_by(index, parent_id, record["id"]),
         highlight: highlight
       }}
    end
  end

  @doc """
  Whether a card showing `record` may hang under the card showing `parent_id`, `nil` for no
  parent: neither of the two may be a module card, which opens at the left edge and holds
  no call for a card to be opened from.
  """
  @spec hangs(map(), String.t() | nil) :: :ok | {:error, String.t()}
  def hangs(_record, nil), do: :ok

  def hangs(%{"kind" => "module", "name" => name}, _parent_id),
    do: {:error, "#{name} is a module, whose card opens at the left edge; give it no parent"}

  def hangs(_record, parent_id) do
    if Index.module_id?(parent_id),
      do: {:error, "#{parent_id} is a module, whose card calls nothing; no card hangs under it"},
      else: :ok
  end

  defp parent(_opened, nil), do: {:ok, nil}

  defp parent(opened, key) do
    case Map.fetch(opened, key) do
      {:ok, function_id} -> {:ok, function_id}
      :error -> {:error, "unknown parent key: #{key}"}
    end
  end

  defp highlight(_index, _record, nil, nil), do: {:ok, nil}

  defp highlight(_index, record, call, lines) when not is_nil(call) and not is_nil(lines),
    do: {:error, "#{record["id"]}: a highlight names either a call or lines, not both"}

  defp highlight(index, record, call, nil) do
    target = Paths.canonical(index, call)

    case Enum.find(calls(record), &(Paths.canonical(index, &1["target"]) == target)) do
      %{"target" => raw} -> {:ok, %{"call" => raw}}
      nil -> {:error, "#{record["id"]} does not call #{call}"}
    end
  end

  defp highlight(_index, record, nil, [first, last])
       when is_integer(first) and is_integer(last) do
    case record["span"] do
      %{"start_line" => start_line, "end_line" => end_line} ->
        in_span(record, first, last, start_line, end_line)

      _no_span ->
        {:error, "#{record["id"]} has no lines to shade"}
    end
  end

  defp highlight(_index, record, nil, _lines),
    do: {:error, "#{record["id"]}: a line highlight takes two line numbers, first and last"}

  defp in_span(record, first, last, start_line, end_line) do
    if start_line <= first and first <= last and last <= end_line do
      {:ok, %{"lines" => [first, last]}}
    else
      {:error,
       "lines #{first}-#{last} fall outside #{record["id"]}, which spans #{start_line}-#{end_line}"}
    end
  end

  defp calls(record),
    do: Enum.filter(List.wrap(record["calls"]) ++ List.wrap(record["hidden_calls"]), &is_map/1)

  defp title(nil), do: nil

  defp title(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key), do: Map.get(map, key)
end
