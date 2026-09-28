defmodule Grasp.Highlight do
  @moduledoc """
  Renders a function record as syntax-highlighted HTML with a clickable span over every
  resolved call.

  Lumis (tree-sitter) emits one `div.l-line` per source line whose children are text runs
  and `span.l-*` runs that may nest — an interpolation is a `span.l-function-call` inside
  a `span.l-string`. Each text run becomes a piece carrying the class of its innermost
  span, positioned by counting characters along the line.

  A record whose file ends in `.heex` is a template and is read with the heex grammar; every
  other record with the elixir one, whose HEEx injection tokenises a `~H` body as markup, so
  a component tag is a run of its own on both sides.

  A call range (from the index, `{line, column}` pairs with an exclusive end column, in
  file coordinates) may start or end inside a run and may span lines; run text is
  therefore split at range boundaries, and consecutive pieces inside the same range on the
  same line are wrapped together. Ranges may sit inside one another — a call written in a
  route attribute's `~p` sigil is inside the attribute's range — and the narrowest range
  covering a piece is the one that wraps it, so the inner call keeps a span of its own and
  the outer range is drawn as the parts either side of it. Output is one `span.line` per
  source line so the viewer can address lines, with Lumis' classes on highlighted runs and
  bare text elsewhere. A call that is not a function call carries a `data-kind` and a `title`
  naming what it reaches — `"route"` with the verb and path the router matched, `"enqueue"`
  with the worker and the queue it runs on — so a hop over HTTP or onto a queue is told from
  a function call on the card and on the edge leaving it.

  `lines/2` and `diff_lines/2` hand those lines back one at a time as `%{side, line, html}`,
  the side telling a line of the current source from one the branch deleted, so a caller can
  place markup of its own between them; `render/2` and `render_diff/2` join the same list.
  Every line's gutter is the comment control: the `span.ln` holding the number carries
  `phx-click="comment_start"` with the card, the side and the line number, so clicking a
  number starts a comment against that line.

  tree-sitter is super-linear on deeply nested binary-operator trees — a twenty-step `|>`
  pipeline parses in tens of milliseconds, a forty-step one in hundreds — and a card
  re-renders on every LiveView pass, so the parse is memoised per function id in the
  `:grasp_highlight_cache` ETS table. Only the source-derived pieces are cached; the range
  split and call wrapping depend on `card_id` and `open_calls` and stay per render. The
  table is owned by `Grasp.IndexStore`, which clears it on every index reload — a cached
  piece list carries absolute line numbers, so a stale entry would outlive the span it was
  computed for. Without the table (a unit test with no store running) every render parses.

  A card's `highlight` — the call to outline or the range of lines to shade — is applied
  as the HTML is built, after the cache, and so is never part of what is memoised.

  `signature/1` renders a single line — the function's head, which is all a far-out card
  shows — from the same cached pieces, without the gutter and without the call spans.
  `assertions/1` renders a test's assertions the same way, each over the lines it spans,
  which is what a far-out test card shows in place of a head.

  `render_diff/2` renders the same lines against the record's `base_source`, interleaving
  the lines the branch deleted. The base side is a second parse memoised under the function
  id suffixed `@base`, so a card switched between its source and its diff parses each side
  once.
  """

  require Logger

  @cache :grasp_highlight_cache

  @definition_prefixes [
    "def ",
    "defp ",
    "defmacro ",
    "defmacrop ",
    "defguard ",
    "defguardp ",
    "defdelegate "
  ]

  @typedoc """
  The call sites a card has already opened, keyed by the raw target the source writes:
  `to` is the id of the card at the far end of the edge and `color` its palette index, so
  the call site can be painted like the edge that leaves it.
  """
  @type open_calls :: %{optional(String.t()) => %{to: pos_integer(), color: 0..7}}

  @type opts :: [
          card_id: pos_integer(),
          open_calls: open_calls(),
          external?: (String.t() -> boolean()),
          highlight: nil | %{optional(String.t()) => String.t() | [integer()]},
          commented: MapSet.t({:new | :old, pos_integer()})
        ]

  @typedoc """
  One rendered line: its `html`, the line number it is addressed by, which side of the diff
  that number belongs to and what the diff did to it. `:new` numbers a line of the current
  source, `:old` a line the branch deleted, numbered as the base commit numbers it. `op` is
  `:eq` for a line both sides share, `:ins` for one the branch added and `:del` for one it
  removed; outside a diff every line is `:eq`, since there is nothing it differs from.
  """
  @type line :: %{
          side: :new | :old,
          line: pos_integer(),
          op: :eq | :ins | :del,
          html: String.t()
        }

  @doc """
  The lines a record's source is numbered by.

  A template's `source` is a whole file and ends in a newline; a function's body does not.
  That final newline ends the last line rather than opening an empty one after it, so
  splitting on `\\n` alone would number a line past the record's own `end_line` — and draw
  it, in the diff as well as the source, wider than the gutter was sized for.
  """
  @spec source_lines(String.t() | nil) :: [String.t()]
  def source_lines(source), do: source |> without_final_newline() |> String.split("\n")

  @doc "Highlighted HTML for `record` with clickable call spans; see the moduledoc."
  @spec render(map(), opts()) :: Phoenix.HTML.safe()
  def render(record, opts), do: {:safe, record |> lines(opts) |> join()}

  @doc """
  The lines `render/2` joins, each as a `t:line/0`.

  Every line of the current source is one entry, numbered from the span's first line, so a
  caller placing markup between lines has the numbers it needs to address them. A line the
  `:commented` option names carries `data-commented`, which is how a card tints the lines a
  comment thread covers.
  """
  @spec lines(map(), opts()) :: [line()]
  def lines(record, opts) do
    card_id = Keyword.fetch!(opts, :card_id)
    source = record["source"]
    first_line = record["span"]["start_line"]
    highlight = Keyword.get(opts, :highlight)
    commented = Keyword.get(opts, :commented, MapSet.new())
    body = body_builder(record, opts)

    # Lines are driven by the source, not by the tokens: a blank line carries no piece, and
    # numbering it from the token groups alone would drop it and skip a number in the gutter.
    last_line = first_line + length(source_lines(source)) - 1

    for line <- first_line..last_line do
      html =
        ~s(<span class="line" data-line="#{line}"#{highlighted_line(highlight, line)}#{commented_line(commented, :new, line)}>#{gutter(card_id, :new, line, line)}#{body.(line)}</span>)

      %{side: :new, line: line, op: :eq, html: html}
    end
  end

  @doc """
  The same HTML as `render/2`, with the record's `base_source` diffed against its current
  source line by line.

  Every line is marked `data-op="eq|ins|del"` and prefixed with a `span.op` reading a
  space, `+` or `−`. A kept or inserted line is numbered as it is in the current file — the
  count runs from the span's first line through the lines the current source has — and is
  built exactly as `render/2` builds it, so an opened call keeps its colour and a highlight
  still lands. A deleted line has no number in the current file and so carries no
  `data-line`; it carries `data-base-line` instead, the number the base commit gives it. Its
  text is highlighted from `base_source` (parsed and memoised separately, under the function
  id suffixed `@base`) and wraps no call span, since the ranges the index recorded address
  the current source and nothing points at a line that is gone.

  A record with no `base_source` — an added or unchanged function — renders as `render/2`.
  """
  @spec render_diff(map(), opts()) :: Phoenix.HTML.safe()
  def render_diff(record, opts), do: {:safe, record |> diff_lines(opts) |> join()}

  @doc """
  The lines `render_diff/2` joins, each as a `t:line/0`.

  A kept or inserted line is `:new`, numbered as the current file numbers it; a deleted line
  is `:old`, numbered as the base commit numbers it. A record with no `base_source` gives the
  lines of `lines/2`.
  """
  @spec diff_lines(map(), opts()) :: [line()]
  def diff_lines(record, opts) do
    case record["base_source"] do
      nil -> lines(record, opts)
      base_source -> diff(record, base_source, opts)
    end
  end

  defp diff(record, base_source, opts) do
    card_id = Keyword.fetch!(opts, :card_id)
    highlight = Keyword.get(opts, :highlight)
    commented = Keyword.get(opts, :commented, MapSet.new())
    body = body_builder(record, opts)

    base_by_line =
      base_source
      |> pieces(1, record["id"] <> "@base", language(record))
      |> Enum.group_by(& &1.line)

    {lines, _current, _base} =
      base_source
      |> without_final_newline()
      |> Grasp.Diff.lines(without_final_newline(record["source"]))
      |> Enum.reduce({[], record["span"]["start_line"], 1}, fn
        {:del, _text}, {acc, current, base} ->
          text = base_by_line |> Map.get(base, []) |> Enum.map_join(&token_html/1)

          html =
            ~s(<span class="line" data-op="del" data-base-line="#{base}"#{commented_line(commented, :old, base)}>#{gutter(card_id, :old, base, "")}<span class="op">−</span>#{text}</span>)

          {[%{side: :old, line: base, op: :del, html: html} | acc], current, base + 1}

        {op, _text}, {acc, current, base} ->
          html =
            ~s(<span class="line" data-op="#{op}" data-line="#{current}"#{highlighted_line(highlight, current)}#{commented_line(commented, :new, current)}>#{gutter(card_id, :new, current, current)}<span class="op">#{mark(op)}</span>#{body.(current)}</span>)

          {[%{side: :new, line: current, op: op, html: html} | acc], current + 1,
           if(op == :eq, do: base + 1, else: base)}
      end)

    Enum.reverse(lines)
  end

  # A file's final newline ends its last line; it does not open an empty one after it.
  defp without_final_newline(source),
    do: source |> to_string() |> String.replace_suffix("\n", "")

  defp join(lines), do: Enum.map_join(lines, "", & &1.html)

  defp mark(:eq), do: " "
  defp mark(:ins), do: "+"

  # The gutter is the comment control as well as the number: clicking it asks the view to
  # open a composer against `line` on `side`. A deleted line shows no number — the current
  # file has none for it — but still addresses its base line.
  defp gutter(card_id, side, line, text) do
    ~s(<span class="ln" role="button" tabindex="0" title="Comment on this line" phx-click="comment_start" phx-value-card="#{card_id}" phx-value-side="#{side}" phx-value-line="#{line}">#{text}</span>)
  end

  # The body of one line of the current source: the pieces that line holds, cut at the call
  # ranges crossing it and wrapped in the clickable spans. Built once per render so both
  # renderers pay for the parse and the grouping a single time.
  defp body_builder(record, opts) do
    card_id = Keyword.fetch!(opts, :card_id)
    open = Keyword.get(opts, :open_calls, %{})
    external? = Keyword.get(opts, :external?, fn _ -> false end)
    highlighted_call = opts |> Keyword.get(:highlight) |> highlighted_call()

    ranges =
      for call <- record["calls"], %{"start" => [sl, sc], "end" => [el, ec]} = call["range"] do
        %{
          target: call["target"],
          kind: call["kind"],
          route: call["route"],
          job: call["job"],
          start: {sl, sc},
          end: {el, ec}
        }
      end

    by_line =
      record["source"]
      |> pieces(record["span"]["start_line"], record["id"], language(record))
      |> Enum.group_by(& &1.line)

    fn line ->
      by_line
      |> Map.get(line, [])
      |> Enum.flat_map(&split_at_ranges(&1, ranges))
      |> wrap_calls(ranges, card_id, open, external?, highlighted_call)
    end
  end

  @doc """
  The function's head as highlighted HTML: the tokens of its definition line, with no
  gutter, no line wrapper and no clickable call spans.

  This is what a card shows instead of its body once the canvas is zoomed too far out for
  code to be read, where a call site is too small to aim at and an outline around one would
  only be noise. The tokens come from the same memoised parse the body is built from, so a
  card that has rendered its body once pays nothing for its head. A record whose source
  defines nothing falls back to its `Mod.fun/arity`.
  """
  @spec signature(map()) :: Phoenix.HTML.safe()
  def signature(record) do
    {source, first_line, id} = signature_source(record)

    case signature_line(record) do
      nil ->
        {:safe, "<span>" <> escape(record["id"] || "") <> "</span>"}

      {line, _text} ->
        html =
          source
          |> pieces(first_line, id, language(record))
          |> Enum.filter(&(&1.line == line))
          |> trim_signature()
          |> Enum.map_join(&token_html/1)

        {:safe, html}
    end
  end

  @doc """
  The line that defines the function, as `{line number in the file, text}`, or nil when the
  source defines nothing.

  The definition is the first line whose trimmed text opens with `def`, `defp`, `defmacro`,
  `defmacrop`, `defguard`, `defguardp` or `defdelegate`, so the `@doc` and `@spec` a record
  carries above its head are passed over. The text is trimmed of the indentation the line
  was written at and of the `do` that opens the body, which belong to the body rather than
  to the head.
  """
  @spec signature_line(map()) :: {pos_integer(), String.t()} | nil
  def signature_line(record) do
    {source, first_line, _id} = signature_source(record)

    source
    |> String.split("\n")
    |> Enum.with_index(first_line)
    |> Enum.find_value(fn {text, line} ->
      trimmed = String.trim(text)

      if String.starts_with?(trimmed, @definition_prefixes) do
        {line, String.trim_trailing(trimmed, " do")}
      end
    end)
  end

  @doc """
  The assertions of a test record, in source order, each as `{lines, highlighted HTML}`,
  `lines` being the range of file lines it spans.

  An assertion is a call named `assert` or `refute`, or one whose name starts with `assert_`
  or `refute_` — `assert_receive`, a project's `assert_element` — written as a local or
  imported call or as a stage of a `|>` pipeline, found by parsing the source rather than by
  reading its lines, so an assertion the formatter broke over several lines is read whole. A
  piped assertion starts on the line its pipeline starts on, where the subject it asserts on
  is written. Assertions whose lines overlap — one nested inside another's function — are
  one range. A variable that shares the prefix (`assert_value = 1`) is not a call and is not
  an assertion.

  The HTML is the range's lines from the memoised parse joined by newlines, with the
  indentation they share taken off, no gutter and no call spans, the way `signature/1`
  renders a head. A record with no assertion, or whose source does not parse, gives `[]`.
  """
  @spec assertions(map()) :: [{Range.t(), Phoenix.HTML.safe()}]
  def assertions(record) do
    {source, first_line, id} = signature_source(record)

    case assertion_ranges(source, first_line) do
      [] ->
        []

      ranges ->
        texts =
          source
          |> source_lines()
          |> Enum.with_index(first_line)
          |> Map.new(fn {text, line} -> {line, text} end)

        by_line = source |> pieces(first_line, id, language(record)) |> Enum.group_by(& &1.line)

        for range <- ranges do
          indent =
            range
            |> Enum.map(&Map.get(texts, &1, ""))
            |> Enum.reject(&(String.trim(&1) == ""))
            |> Enum.map(&(String.length(&1) - String.length(String.trim_leading(&1))))
            |> Enum.min(fn -> 0 end)

          html =
            Enum.map_join(range, "\n", fn line ->
              by_line
              |> Map.get(line, [])
              |> drop_columns(indent)
              |> Enum.map_join(&token_html/1)
            end)

          {range, {:safe, html}}
        end
    end
  end

  defp assertion_ranges(source, first_line) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {_ast, ranges} =
          Macro.prewalk(ast, [], fn node, acc ->
            case assertion_range(node) do
              %Sourceror.Range{start: start, end: finish} ->
                {node, [{start[:line], finish[:line]} | acc]}

              nil ->
                {node, acc}
            end
          end)

        ranges
        |> Enum.sort()
        |> Enum.reduce([], fn
          {first, last}, [{open_first, open_last} | rest] when first <= open_last ->
            [{open_first, max(last, open_last)} | rest]

          range, merged ->
            [range | merged]
        end)
        |> Enum.reverse()
        |> Enum.map(fn {first, last} -> (first + first_line - 1)..(last + first_line - 1)//1 end)

      {:error, _reason} ->
        []
    end
  end

  # A pipeline stage is the call on the right of `|>`, and the pipeline is what it spans; any
  # other call counts by its own range.
  defp assertion_range({:|>, _meta, [_subject, {name, _call_meta, args}]} = node)
       when is_atom(name) and is_list(args) do
    if assertion_name?(name), do: Sourceror.get_range(node)
  end

  defp assertion_range({name, _meta, args} = node) when is_atom(name) and is_list(args) do
    if assertion_name?(name), do: Sourceror.get_range(node)
  end

  defp assertion_range(_node), do: nil

  defp assertion_name?(name) do
    case Atom.to_string(name) do
      "assert" -> true
      "refute" -> true
      "assert_" <> _rest -> true
      "refute_" <> _rest -> true
      _other -> false
    end
  end

  # Takes the first `count` columns off a line's pieces, which the caller has measured as
  # indentation, so only whitespace is cut.
  defp drop_columns(pieces, count) do
    pieces
    |> Enum.flat_map(fn piece ->
      length = String.length(piece.text)

      cond do
        piece.col > count -> [piece]
        piece.col + length - 1 <= count -> []
        true -> [%{piece | text: String.slice(piece.text, (count - piece.col + 1)..-1//1)}]
      end
    end)
  end

  # Which text the head is read from, how its lines are numbered and under which key its
  # parse is memoised. A function the branch removed may carry no source of its own; its base
  # text is then numbered from 1 and cached under the same key `render_diff/2` uses for it,
  # so the two never disagree about what line 1 holds.
  defp signature_source(record) do
    case record["source"] do
      nil -> {record["base_source"] || "", 1, to_string(record["id"]) <> "@base"}
      source -> {source, record["span"]["start_line"] || 1, record["id"]}
    end
  end

  # The indentation the definition was written at and the `do` opening its body frame the
  # head without being part of it, and both go, along with the whitespace that separated
  # them. A run left empty by the trim would render as a span around nothing.
  defp trim_signature(pieces) do
    pieces
    |> Enum.reverse()
    |> drop_trailing_do()
    |> Enum.reverse()
    |> case do
      [first | rest] -> [%{first | text: String.trim_leading(first.text)} | rest]
      [] -> []
    end
    |> Enum.reject(&(&1.text == ""))
  end

  defp drop_trailing_do(reversed_pieces) do
    case Enum.drop_while(reversed_pieces, &blank_piece?/1) do
      [%{text: "do"} | rest] -> Enum.drop_while(rest, &blank_piece?/1)
      _kept -> reversed_pieces
    end
  end

  defp blank_piece?(piece), do: String.trim(piece.text) == ""

  @doc """
  Creates the highlight cache unless it exists; the calling process owns it.

  Returns `:ok` whether or not it had to create the table.
  """
  @spec ensure_cache() :: :ok
  def ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every memoised parse; a no-op when the cache does not exist."
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache)
    :ok
  end

  # Each Lumis text run becomes a piece %{line, col, text, css}; col is the 1-based start
  # column, css the class of the run's innermost span (nil for unhighlighted text).
  defp pieces(source, first_line, id, language) do
    if :ets.whereis(@cache) == :undefined do
      parse(source, first_line, id, language)
    else
      case :ets.lookup(@cache, id) do
        [{^id, pieces}] ->
          pieces

        [] ->
          pieces = parse(source, first_line, id, language)
          :ets.insert(@cache, {id, pieces})
          pieces
      end
    end
  end

  defp parse(source, first_line, id, language) do
    source
    |> line_trees(id, language)
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {children, line} ->
      {pieces, _col} = Enum.reduce(children, {[], 1}, &runs(&1, nil, line, &2))
      Enum.reverse(pieces)
    end)
  end

  # Which grammar a record's source is read with. A record whose file is a `.heex` template
  # holds markup, not Elixir, and the elixir grammar would give its whole body one class.
  defp language(record) do
    if String.ends_with?(to_string(record["file"]), ".heex"), do: "heex", else: "elixir"
  end

  # The children of each `div.l-line`, taken from one whole-document parse rather than one
  # per line. A source Lumis will not highlight still has to render — unparseable bytes
  # raise inside the NIF rather than returning an error — so anything unexpected falls back
  # to one unhighlighted run per line, and the card is served as plain text rather than not
  # at all. The parse is memoised per function id, so the warning is one per function.
  defp line_trees(source, id, language) do
    result =
      try do
        with {:ok, html} <-
               Lumis.highlight(source, formatter: {:html_linked, language: language}),
             [{"pre", _, [{"code", _, lines}]}] <-
               html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() do
          {:ok, for({"div", _attrs, children} <- lines, do: children)}
        else
          other -> {:error, other}
        end
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, lines} ->
        lines

      {:error, reason} ->
        Logger.warning("grasp: highlighting unavailable for #{id}: #{inspect(reason)}")
        bare_lines(source)
    end
  end

  defp bare_lines(source), do: source |> String.split("\n") |> Enum.map(&[&1])

  defp runs(text, css, line, {acc, col}) when is_binary(text) do
    text = String.replace_suffix(text, "\n", "")

    if text == "" do
      {acc, col}
    else
      {[%{line: line, col: col, text: text, css: css} | acc], col + String.length(text)}
    end
  end

  defp runs({"span", attrs, children}, _outer_css, line, acc) do
    css = attrs |> List.keyfind("class", 0, {"class", nil}) |> elem(1)
    Enum.reduce(children, acc, &runs(&1, css, line, &2))
  end

  defp runs(_other, _css, _line, acc), do: acc

  defp split_at_ranges(piece, ranges) do
    piece_end = piece.col + String.length(piece.text)

    cuts =
      ranges
      |> Enum.flat_map(fn range ->
        [line_bound(range, piece.line, :start), line_bound(range, piece.line, :end)]
      end)
      |> Enum.filter(&(&1 > piece.col and &1 < piece_end))
      |> Enum.uniq()
      |> Enum.sort()

    {pieces, _} =
      Enum.reduce(cuts ++ [piece_end], {[], piece.col}, fn cut, {acc, from} ->
        text = String.slice(piece.text, from - piece.col, cut - from)
        {[%{piece | col: from, text: text} | acc], cut}
      end)

    Enum.reverse(pieces)
  end

  defp highlighted_call(%{"call" => call}), do: call
  defp highlighted_call(_highlight), do: nil

  defp highlighted_line(%{"lines" => [first, last]}, line) when first <= line and line <= last,
    do: ~s( data-highlight="true")

  defp highlighted_line(_highlight, _line), do: ""

  # A line covered by an open comment thread, so the range a thread was written over reads as
  # one block rather than as a remark hanging off its last line alone.
  defp commented_line(commented, side, line) do
    if MapSet.member?(commented, {side, line}), do: ~s( data-commented="true"), else: ""
  end

  defp wrap_calls(pieces, ranges, card_id, open, external?, highlighted_call) do
    pieces
    |> Enum.chunk_by(&covering(&1, ranges))
    |> Enum.map_join(fn [first | _] = chunk ->
      inner = Enum.map_join(chunk, &token_html/1)

      case covering(first, ranges) do
        nil ->
          inner

        %{target: target} = range ->
          attrs =
            ~s( data-target="#{escape(target)}") <>
              kind_attrs(range) <>
              edge_attrs(open, target) <>
              ~s( data-external="#{escape(to_string(external?.(target)))}" phx-click="open_call" phx-value-card="#{escape(to_string(card_id))}" phx-value-target="#{escape(target)}") <>
              if target == highlighted_call, do: ~s( data-highlight="true"), else: ""

          ~s(<span class="call"#{attrs}>#{inner}</span>)
      end
    end)
  end

  # A hop that is not a function call — an HTTP request the router resolved, a job put on
  # a queue — says which kind it is, and the title carries what the reader would otherwise
  # have to look up: the route's verb and path, or the worker and the queue it runs on.
  defp kind_attrs(%{kind: "route", route: %{"verb" => verb, "path" => path}}),
    do: ~s( data-kind="route" title="#{escape(verb)} #{escape(path)}")

  defp kind_attrs(%{kind: "enqueue", job: %{"worker" => worker, "queue" => queue}}),
    do: ~s( data-kind="enqueue" title="Oban job · #{escape(worker)} · #{escape(queue)}")

  defp kind_attrs(_range), do: ""

  defp edge_attrs(open, target) do
    case Map.fetch(open, target) do
      {:ok, %{to: to, color: color}} ->
        ~s( data-open="true" data-color="#{color}" data-edge-to="#{to}")

      :error ->
        ~s( data-open="false")
    end
  end

  # Whitespace is never part of a callee, so a range that continues onto a new line does
  # not swallow that line's indentation. Where several ranges cover the piece the narrowest
  # one wraps it, so a call written inside a route attribute keeps its own span and the
  # attribute's is drawn around it in two parts.
  defp covering(piece, ranges) do
    if String.trim(piece.text) == "" do
      nil
    else
      ranges
      |> Enum.filter(fn range ->
        piece.col >= line_bound(range, piece.line, :start) and
          piece.col < line_bound(range, piece.line, :end)
      end)
      |> Enum.min_by(&width/1, fn -> nil end)
    end
  end

  # Lines first, then columns, so a range held to one line is narrower than any range that
  # runs over more of them however few characters it takes on this one.
  defp width(%{start: {sl, sc}, end: {el, ec}}), do: {el - sl, ec - sc}

  # The columns a range occupies on `line`: a range covers whole lines between its start and end.
  defp line_bound(%{start: {sl, sc}, end: {el, _ec}}, line, :start),
    do: if(line == sl, do: sc, else: if(line > sl and line <= el, do: 1, else: :infinity))

  defp line_bound(%{start: {sl, _sc}, end: {el, ec}}, line, :end),
    do: if(line == el, do: ec, else: if(line >= sl and line < el, do: :infinity, else: -1))

  defp token_html(%{text: text, css: nil}), do: escape(text)
  defp token_html(%{text: text, css: css}), do: ~s(<span class="#{css}">#{escape(text)}</span>)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
