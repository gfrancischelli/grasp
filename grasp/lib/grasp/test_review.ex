defmodule Grasp.TestReview do
  @moduledoc """
  Reads a test's assertions from a parse of its source, and compares a modified test's
  assertions with those of its base to say whether the branch weakened them.

  An assertion is a call named `assert` or `refute`, or one whose name starts with `assert_`
  or `refute_`, written as a local or imported call or as a stage of a `|>` pipeline, whose
  source is then the whole pipeline. Signature mode renders the same calls, so both read
  one walk of the parse: `assertion_calls/1`.

  Assertions are compared by a canonical form of their parsed node: the node printed by
  `Macro.to_string/1` with its metadata and Sourceror's literal wrappers taken off, so
  layout, line breaks and comments make no difference while the contents of a string do.
  The source with its whitespace collapsed is what a reason shows.

  A modified test is weakened when it takes strength away: the head makes fewer assertion
  calls than the base, calls an `assert_*`/`refute_*` function fewer times, or turns an
  `assert left == right` (or `===`) into one that accepts more — `left =~ …`, `left in …`, a
  `match?/2` on `left`, or a bare `assert left`. An edit that keeps the number of
  assertions, such as a different expected value or timeout, is not a weakening unless it
  drops an `assert_*`/`refute_*` call or loosens an equality: `assert_receive` renamed to
  `assert_received`, or an `assert_*` helper replaced by a plain `assert`, keeps the count
  and still reads `dropped:`. An added test with no assertion at all asserts nothing. A source that does not parse is
  never marked, since nothing can be said of what it asserts.
  """

  @typedoc "An assertion call as the parse holds it: its name, its range and its node."
  @type call :: %{name: String.t(), range: Sourceror.Range.t(), node: Macro.t()}

  @typedoc """
  An assertion as the review compares it: its name and whitespace-collapsed text, and for
  an `assert` whose argument is a binary operator, the operator and its left side's text.
  """
  @type assertion :: %{
          required(:name) => String.t(),
          required(:text) => String.t(),
          optional(:op) => atom(),
          optional(:left) => String.t()
        }

  @typedoc "What `review/1` answers for a test record."
  @type verdict :: :ok | :asserts_nothing | {:weakened, [String.t()]}

  @loose_ops [:=~, :in]
  @strict_ops [:==, :===]

  @doc """
  The assertion calls of `source`, in source order, or `:error` when it does not parse.

  A pipeline ending in an assertion is one call spanning the pipeline, named after its
  last stage; an assertion nested in another's arguments is a call of its own. A call
  the parse holds no range for is left out.
  """
  @spec assertion_calls(String.t()) :: {:ok, [call()]} | :error
  def assertion_calls(source) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, calls} =
          Macro.prewalk(ast, [], fn node, acc ->
            case assertion_call(node) do
              {name, stage_args} ->
                acc =
                  case Sourceror.get_range(node) do
                    %Sourceror.Range{} = range -> [%{name: name, range: range, node: node} | acc]
                    nil -> acc
                  end

                {descend(node, stage_args), acc}

              nil ->
                {node, acc}
            end
          end)

        {:ok, Enum.sort_by(calls, &{&1.range.start[:line], &1.range.start[:column]})}

      {:error, _reason} ->
        :error
    end
  end

  @doc """
  The assertions of `source`, in source order, each as `%{name, text}` — `text` being the
  call's source with every run of whitespace collapsed to one space — and, for an `assert`
  whose argument is a binary operator, its `op` and the `left` side's text, collapsed the
  same way. A source that does not parse gives `[]`.
  """
  @spec assertions(String.t()) :: [assertion()]
  def assertions(source) when is_binary(source) do
    case read(source) do
      {:ok, assertions} ->
        Enum.map(assertions, &Map.drop(&1, [:key, :arg, :matched, :left_key]))

      :error ->
        []
    end
  end

  @doc """
  The review of a test record.

  A modified test (`"change" => "modified"`, kind `"test"`, with a `"base_source"`) answers
  `{:weakened, reasons}` when the head, against the base:

    * makes fewer assertion calls — `"removed: <text>"` for each assertion of the base the
      head makes fewer times, by canonical form;
    * calls an `assert_*`/`refute_*` name fewer times — `"dropped: <name>"`;
    * holds, for an `assert left == right` or `===` of the base with no canonical
      counterpart at the head, an assertion using `=~` or `in` on `left`, a `match?/2` on
      `left`, or a bare `assert left` — `"loosened: <text>"`, `text` being the base
      assertion's.

  Reasons come in that order, each kind in the order the base makes them. An added test
  (`"change" => "added"`) with no assertion answers `:asserts_nothing`. Anything else,
  and a source or base that does not parse, answers `:ok`.
  """
  @spec review(map()) :: verdict()
  def review(%{"kind" => "test", "change" => "modified", "base_source" => base} = record)
      when is_binary(base) do
    with head when is_binary(head) <- record["source"],
         {:ok, base} <- read(base),
         {:ok, head} <- read(head) do
      case weakened(base, head) do
        [] -> :ok
        reasons -> {:weakened, reasons}
      end
    else
      _unreadable -> :ok
    end
  end

  def review(%{"kind" => "test", "change" => "added", "source" => source})
      when is_binary(source) do
    case read(source) do
      {:ok, []} -> :asserts_nothing
      _asserts_or_unreadable -> :ok
    end
  end

  def review(_record), do: :ok

  defp weakened(base, head) do
    head_keys = Enum.frequencies_by(head, & &1.key)

    unmatched =
      for {key, count} <- Enum.frequencies_by(base, & &1.key),
          Map.get(head_keys, key, 0) < count,
          into: MapSet.new(),
          do: key

    removed_reasons =
      if length(head) < length(base) do
        for %{key: key, text: text} <- Enum.uniq_by(base, & &1.key),
            MapSet.member?(unmatched, key),
            do: "removed: " <> text
      else
        []
      end

    base_names = base |> Enum.filter(&suffixed?(&1.name)) |> Enum.frequencies_by(& &1.name)
    head_names = Enum.frequencies_by(head, & &1.name)

    dropped_reasons =
      for name <- base |> Enum.map(& &1.name) |> Enum.uniq(),
          Map.get(head_names, name, 0) < Map.get(base_names, name, 0),
          do: "dropped: " <> name

    loosened_reasons =
      for %{name: "assert", op: op, left_key: left, key: key, text: text} <- base,
          op in @strict_ops,
          MapSet.member?(unmatched, key),
          Enum.any?(head, &looser?(&1, left)),
          uniq: true,
          do: "loosened: " <> text

    removed_reasons ++ dropped_reasons ++ loosened_reasons
  end

  defp looser?(%{name: "assert"} = assertion, left) do
    (assertion[:op] in @loose_ops and assertion[:left_key] == left) or
      left in assertion.matched or assertion.arg == left
  end

  defp looser?(_assertion, _left), do: false

  defp suffixed?("assert_" <> _rest), do: true
  defp suffixed?("refute_" <> _rest), do: true
  defp suffixed?(_name), do: false

  # Each assertion with what the comparison reads beyond `assertions/1`: its canonical form,
  # and those of an `assert`'s first argument, of its left side and of the expressions its
  # `match?/2` calls test.
  defp read(source) do
    with {:ok, calls} <- assertion_calls(source) do
      lines = String.split(source, "\n")
      {:ok, Enum.map(calls, &assertion(&1, lines))}
    end
  end

  defp assertion(%{name: name, range: range, node: node}, lines) do
    call = %{name: name, text: slice(lines, range), key: canonical(node), arg: nil, matched: []}

    case {name, node} do
      {"assert", {:assert, _meta, [arg | _rest]}} ->
        call = %{call | arg: canonical(arg), matched: matched(arg)}

        case arg do
          {op, _op_meta, [left, _right]} when is_atom(op) ->
            if Macro.operator?(op, 2),
              do:
                Map.merge(call, %{op: op, left: text_of(left, lines), left_key: canonical(left)}),
              else: call

          _other ->
            call
        end

      _other ->
        call
    end
  end

  defp matched(arg) do
    {_arg, matched} =
      Macro.prewalk(arg, [], fn
        {:match?, _meta, [_pattern, expression]} = node, acc ->
          {node, [canonical(expression) | acc]}

        node, acc ->
          {node, acc}
      end)

    matched
  end

  defp text_of(node, lines) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{} = range -> slice(lines, range)
      nil -> node |> Sourceror.to_string() |> collapse()
    end
  end

  # Sourceror wraps a literal in a one-element `:__block__` to carry its token and comments;
  # taking the wrapper and every node's metadata off leaves the plain quoted form the printer
  # reads. A form the printer cannot read is compared by its stripped term instead.
  defp canonical(node) do
    stripped =
      Macro.postwalk(node, fn
        {:__block__, _meta, [single]} -> single
        {form, meta, args} when is_list(meta) -> {form, [], args}
        other -> other
      end)

    try do
      Macro.to_string(stripped)
    rescue
      _unprintable -> inspect(stripped, limit: :infinity)
    end
  end

  # Sourceror's columns count codepoints from 1, and a range ends on the column after its
  # last character.
  defp slice(lines, %Sourceror.Range{start: start, end: finish}) do
    {first, last} = {start[:line], finish[:line]}
    {from, to} = {start[:column], finish[:column]}

    text =
      if first == last do
        lines |> Enum.at(first - 1, "") |> String.slice((from - 1)..(to - 2)//1)
      else
        head = lines |> Enum.at(first - 1, "") |> String.slice((from - 1)..-1//1)
        middle = lines |> Enum.slice(first..(last - 2)//1)
        tail = lines |> Enum.at(last - 1, "") |> String.slice(0..(to - 2)//1)
        Enum.join([head | middle] ++ [tail], "\n")
      end

    collapse(text)
  end

  defp collapse(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The name of an assertion `node` is, and the arguments of the stage it ends with when it
  # is a pipeline, or nil when it is not an assertion.
  defp assertion_call({:|>, _meta, [_subject, {name, _call_meta, args}]})
       when is_atom(name) and is_list(args) do
    if assertion_name?(name), do: {Atom.to_string(name), args}
  end

  defp assertion_call({name, _meta, args}) when is_atom(name) and is_list(args) do
    if assertion_name?(name), do: {Atom.to_string(name), nil}
  end

  defp assertion_call(_node), do: nil

  # A pipeline's last stage is the call already counted as the pipeline, so the walk goes
  # on into its arguments without meeting the stage again.
  defp descend(node, nil), do: node

  defp descend({:|>, meta, [subject, _stage]}, stage_args),
    do: {:|>, meta, [subject, {:__block__, [], stage_args}]}

  defp assertion_name?(name) do
    case Atom.to_string(name) do
      "assert" -> true
      "refute" -> true
      "assert_" <> _rest -> true
      "refute_" <> _rest -> true
      _other -> false
    end
  end
end
