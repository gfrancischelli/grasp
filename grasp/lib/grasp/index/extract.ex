defmodule Grasp.Index.Extract do
  @moduledoc """
  Reads one Elixir source file with Sourceror and returns its function definitions and
  the call sites inside them.

  A definition groups every clause of a `{module, name, arity}` — including the extra
  arities a head with default arguments introduces — into one record whose span runs
  from the first attached attribute (`@doc`, `@spec`, `@impl`, `@deprecated`, `@since`,
  `@decorate`) or leading comment through the last clause's end. Module names come from
  the `defmodule` nesting, including `__MODULE__.Sub` heads; a `defmodule` whose name is
  not a literal alias is skipped. Call sites are every call node in a clause, keyed by
  the position the compiler reports for that call — the line and column of the function
  name — so `Grasp.Index.Join` can pair them with tracer events. A site's range covers
  the callee only (`Formatter.wrap`, `shout`, `double`), never its arguments, so ranges
  don't nest when rendered. A range can span lines: a receiver written on its own line
  (`Enum\n.map(list, f)`) starts the range one line above the name the compiler reports.

  A `~H` sigil in a definition body contributes call sites too: `Grasp.Index.Heex` scans the
  template for component tags and yields the body of every interpolation, this module parses
  those bodies, and the sites the two produce join the ones the Elixir AST produced. The
  sigil itself is not one of them — a local call whose name begins with `sigil_` never becomes
  a site, since the macro behind a sigil builds a literal rather than calling anything, and
  `Grasp.Index.Join` drops every `sigil_`-named target whatever form it was written in. A heredoc
  `~H\"""` starts on the line after the sigil, with the `indentation` Sourceror records on
  the sigil's string stripped from every line, which is where the file has it too. A
  single-line `~H"..."` is the one place a site's key and its range part ways: Phoenix
  compiles it as though it began on the next line at column 1, so the site is keyed there —
  where the tracer reports its calls — while the `range` stays on the sigil's own line,
  three columns past the `~`, where the reader sees the code. A site made from a `render`
  call whose second argument is a literal atom or string also carries that literal as
  `template`, with any `.html` suffix removed, which is the name of the template the call
  renders.

  An interpolation is Elixir, so its body is parsed rather than skipped: `Sourceror` reads
  it at the file position `Grasp.Index.Heex` reports, and the same walk that reads a clause
  body collects its call sites, so a call written in a tag body, an attribute value or an
  EEx expression tag is a site a reader can click. A body that is only part of an
  expression — the `if ... do` half of a block — is retried with an `end` appended, and a
  body no parse can make sense of (`else`, `end`, a comment) contributes nothing. Every
  site also records its `callee`, the call as it is written, because the compiler reports
  the calls of a `{...}` interpolation with a line and no column at all: `Grasp.Index.Join`
  places those by name, arity and the module the source spells out.

  A definition carries its **route sites** beside its call sites. A route site is a path a
  template or an expression names — the value of an `href`, `action`, `navigate`, `patch`
  or `hx-*` attribute, and every `~p` sigil the walk meets — read into the verb it implies
  and the segments it is made of, with an interpolated segment reduced to `:dynamic`
  because no parser can know what it will hold. A query string and a fragment are cut off:
  they are not part of what the router matches. Nothing here knows the project's routes,
  so nothing is resolved: `Grasp.Index.Routes` matches the sites against the router's own
  paths once the entry points are known. A `~p` written inside a route attribute is the
  same route twice, and the attribute's site is the one that survives, because it is the
  one that knows the verb.

  A request a test makes is a route site too: a call named `get`, `post`, `put`, `patch`,
  `delete`, `head`, `options`, `live` or `visit` — local, imported, or called on a module
  whose alias ends in `Test`, such as `Phoenix.ConnTest` — whose second argument (the first
  written, when the call is piped into) is a string or a `~p` sigil. A remote call on any
  other module (`Map.get(params, "/")`, an HTTP client's `get`) is no request.
  Its verb is the one the name gives, GET for `live` and `visit`, and it replaces the GET
  the `~p` it holds would read as, so one request is one route. A path held in a variable
  names nothing the source can read and makes no site.

  A test file is read the same way, and ExUnit's blocks inside a module are definitions too.
  A `test "name"` with a body is a definition of kind `:test`, arity 1, named as ExUnit
  compiles it — `:"test <describe> <name>"` inside a `describe`, `:"test <name>"` outside one,
  cut to ExUnit's own length limit — and carries `test`, the describe, the name and the tags
  its `@tag` attributes give it. A `setup` or `setup_all` with a body is a definition of kind
  `:setup`, arity 1, carrying `test: nil`, and is named by ExUnit's counters:
  `:"__ex_unit_setup_<n>"` and `:"__ex_unit_setup_all_<n>"` count every callback registered
  before it in the module, a `setup :name` or each entry of a `setup [...]` included, and a
  setup inside a `describe` is `:"__ex_unit_setup_<describe>_<n>"`, where `<describe>` is the
  describe's position among the module's describes and `<n>` counts that describe's callbacks
  alone. A pending `test "name"` with no body, a `setup` naming callbacks and a `describe`
  itself contribute no definition. A test's or a setup's span starts at its attached `@tag`,
  `@describetag` or `@moduletag` attributes and leading comments, and its call sites are
  its body's, which is where the tracer reports them: the compiled function is the caller of
  every call in the body.

  Each definition also records where its clause heads are: `head_positions` is the
  `{line, column}` of the function name in every clause and `head_ranges` the matching
  ranges over that name. `Grasp.Index.Join` uses the positions to drop the events the
  compiler reports while registering a definition, and the range to place the call a
  `defdelegate` makes, which the compiler reports with no column at all.

  A definition records where its branches are too, as `{start_line, end_line}` pairs.
  `clauses` holds one per clause in source order, from the line of its `def` — or its
  `test` or `setup` — through its last line; a test or a setup is one clause, and a head
  written without a body to declare default arguments is none. `arms` holds every
  arm, anywhere in those clauses, of a `case`, a `cond`, a `with`'s `else`, a `receive` and
  its `after`, a `try`'s `rescue`, `catch`, `else` and `after` — and of the same clauses
  written straight on a `def`, a test or a setup, which is a `try` the compiler writes — and
  of a `fn` with more than one clause. An arm runs from its pattern's line through its
  body's last line, an `after` that has no pattern from the `after` itself; a construct
  nested inside an arm adds arms of its own, and clauses written in keyword form
  (`else: (_ -> nil)`) are arms as much as those of a `do` block. A branch written inside a
  `~H` sigil is template text, not Elixir the walk reads, and adds no arm. Arms are sorted by
  their start line, then their end line.
  """

  alias Grasp.Index.Heex

  @type range :: %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}}
  @type position :: {pos_integer(), pos_integer()}
  @type line_range :: {pos_integer(), pos_integer()}
  @type callee :: %{module: String.t() | nil, name: atom(), arity: non_neg_integer()}
  # `callee` is the call as written: `module` is the literal receiver — an alias joined
  # with "." (`"Greeter"`, `"SampleApp.Greeter"`) or an Erlang module's own text — and is
  # `nil` for a local or imported call and for a receiver that is an expression
  # (`mod.f(x)`); `name` is the function and `arity` the arity as written, which for a
  # capture (`&Mod.f/2`) is the one after the slash and for a piped call counts the piped
  # value as the first argument. A component tag has no callee: the compiler always reports
  # it with a column, so it is never placed by name.
  @type call_site :: %{
          line: pos_integer(),
          column: pos_integer(),
          range: range(),
          template: String.t() | nil,
          callee: callee() | nil
        }
  @type segment :: String.t() | :dynamic
  # A path the source names, split the way a router splits its own: `"/greet/bob"` is
  # `["greet", "bob"]`, `"/"` is `[]`, and a segment an interpolation reaches into is
  # `:dynamic`, which matches whatever the route writes in that position.
  @type route_site :: %{verb: String.t(), path: [segment()], range: range()}
  # `:template` is not a kind this module reads: `Grasp.Index.Templates` builds a definition
  # of that kind, in this same shape, for every file an `embed_templates` pattern matches.
  @type kind ::
          :def
          | :defp
          | :defmacro
          | :defmacrop
          | :defguard
          | :defguardp
          | :defdelegate
          | :template
          | :test
          | :setup

  # What a test is to the reader, beside its compiled name: the describe it sits in, the
  # name its author wrote and the names of the tags `@tag` attaches to it.
  @type test_info :: %{describe: String.t() | nil, name: String.t(), tags: [String.t()]}

  # `test` is present on the definitions of kind `:test`, where it is a `test_info()`, and
  # of kind `:setup`, where it is `nil`; every other definition has no `test` key.
  @type definition :: %{
          optional(:test) => test_info() | nil,
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: kind(),
          file: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          source: String.t(),
          call_sites: [call_site()],
          route_sites: [route_site()],
          head_positions: [position()],
          head_ranges: [range()],
          clauses: [line_range()],
          arms: [line_range()]
        }

  @type module_info :: %{name: String.t(), file: String.t(), line: pos_integer()}

  @type embed :: %{
          module: String.t(),
          pattern: String.t(),
          suffix: String.t() | nil,
          root: String.t() | nil,
          file: String.t(),
          line: pos_integer()
        }

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @attached_attributes [
    :doc,
    :spec,
    :impl,
    :deprecated,
    :since,
    :decorate,
    :tag,
    :describetag,
    :moduletag
  ]
  # Special forms and operators the compiler never reports as calls; leaving them in
  # would produce sites no tracer event can ever land on.
  @not_calls [
    :__block__,
    :__aliases__,
    :.,
    :fn,
    :->,
    :__MODULE__,
    :unquote,
    :unquote_splicing,
    :/,
    :=,
    :when,
    :%{},
    :{},
    :<<>>,
    :^,
    :|,
    :%,
    :"::",
    :\\
  ]

  # The request helpers a test drives the router with, and the verb each sends. A LiveView
  # is mounted, and a page visited, by a GET.
  @request_verbs %{
    get: "GET",
    post: "POST",
    put: "PUT",
    patch: "PATCH",
    delete: "DELETE",
    head: "HEAD",
    options: "OPTIONS",
    live: "GET",
    visit: "GET"
  }

  @doc """
  Parses `source`, read from the project-relative `file`, into definitions, modules and
  the template patterns its modules embed.

  An embed carries the pattern and the `:suffix` and `:root` options that decide what the
  embedded functions are called and where they are looked for; an option that is not a
  literal string reads as absent.
  """
  @spec extract(String.t(), String.t()) ::
          {:ok, %{definitions: [definition()], modules: [module_info()], embeds: [embed()]}}
          | {:error, term()}
  def extract(source, file) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      lines = String.split(source, "\n")

      acc =
        walk(ast, [], %{definitions: [], modules: [], embeds: [], lines: lines, file: file})

      {:ok,
       %{
         definitions: Enum.reverse(acc.definitions),
         modules: Enum.reverse(acc.modules),
         embeds: Enum.reverse(acc.embeds)
       }}
    end
  end

  defp walk({:defmodule, meta, [name_ast, body]}, stack, acc) do
    case module_name(name_ast, stack) do
      nil ->
        acc

      name ->
        parts = String.split(name, ".")
        acc = %{acc | modules: [%{name: name, file: acc.file, line: meta[:line]} | acc.modules]}
        body |> do_block_exprs() |> collect_definitions(name, parts, acc)
    end
  end

  defp walk({:__block__, _, exprs}, stack, acc), do: Enum.reduce(exprs, acc, &walk(&1, stack, &2))
  defp walk(_other, _stack, acc), do: acc

  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _stack), do: join_alias(parts, [])

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, stack),
    do: join_alias(parts, stack)

  defp module_name({:__aliases__, _, parts}, stack), do: join_alias(parts, stack)
  defp module_name(_dynamic, _stack), do: nil

  defp join_alias(parts, stack) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.join(stack ++ Enum.map(parts, &Atom.to_string/1), ".")
    end
  end

  defp do_block_exprs([{{:__block__, _, [:do]}, {:__block__, _, exprs}} | _]), do: exprs
  defp do_block_exprs([{{:__block__, _, [:do]}, expr} | _]), do: [expr]
  defp do_block_exprs(_), do: []

  # Walks a module body in order, carrying the attributes that will attach to the next
  # definition; anything that is neither an attached attribute nor a definition resets them.
  # `scope` carries what ExUnit counts while it compiles the module: the describe the walk is
  # inside, how many describes came before, and how many setup callbacks each list holds.
  defp collect_definitions(exprs, module, parts, acc) do
    scope = %{module: module, parts: parts, describe: nil, describes: 0, setups: 0, setups_all: 0}
    {acc, _scope} = collect_block(exprs, acc, scope)
    acc
  end

  defp collect_block(exprs, acc, scope) do
    {acc, scope, _pending} = Enum.reduce(exprs, {acc, scope, []}, &collect_expr/2)
    {acc, scope}
  end

  defp collect_expr({:@, _, [{attr, _, _}]} = node, {acc, scope, pending})
       when attr in @attached_attributes,
       do: {acc, scope, pending ++ [node]}

  defp collect_expr({kind, _, [head | _]} = node, {acc, scope, pending}) when kind in @def_kinds,
    do: {add_clause(acc, scope.module, kind, head, node, pending), scope, []}

  defp collect_expr({:defmodule, _, _} = node, {acc, scope, _pending}),
    do: {walk(node, scope.parts, acc), scope, []}

  defp collect_expr({:embed_templates, meta, [pattern | opts]}, {acc, scope, _pending}),
    do: {add_embed(acc, scope.module, pattern, opts, meta), scope, []}

  # ExUnit sets a describe's setup list aside while it compiles the describe and puts it back
  # after, so the module's own count resumes from its value before the describe; the
  # describe counter moves on whether or not the describe's name is a literal.
  defp collect_expr({:describe, _, [name, block]}, {acc, scope, _pending}) when is_list(block) do
    inner = %{scope | describe: {literal_string(name), scope.describes}, setups: 0}
    {acc, _inner} = collect_block(do_block_exprs(block), acc, inner)
    {acc, %{scope | describes: scope.describes + 1}, []}
  end

  defp collect_expr({:test, _, [name | rest]} = node, {acc, scope, pending}) do
    description = test_description(scope.describe, literal_string(name))

    case {description, do_block(List.last(rest))} do
      {{describe, text, compiled}, {:ok, block}} ->
        test = %{describe: describe, name: text, tags: tags(pending)}
        {add_block(acc, scope.module, :test, compiled, node, block, pending, test), scope, []}

      _pending_or_dynamic ->
        {acc, scope, []}
    end
  end

  defp collect_expr({setup, _, args} = node, {acc, scope, pending})
       when setup in [:setup, :setup_all] and is_list(args) do
    counter = if setup == :setup, do: :setups, else: :setups_all
    count = Map.fetch!(scope, counter)

    case setup_callbacks(args) do
      {:block, block} ->
        name = setup_name(setup, scope.describe, count)
        acc = add_block(acc, scope.module, :setup, name, node, block, pending, nil)
        {acc, Map.put(scope, counter, count + 1), []}

      {:callbacks, callbacks} ->
        {acc, Map.put(scope, counter, count + callbacks), []}
    end
  end

  defp collect_expr(_other, {acc, scope, _pending}), do: {acc, scope, []}

  # The whole keyword list of a `do` block — `do` and any `rescue`, `catch`, `else` or
  # `after` clause — since ExUnit compiles every clause into the function the tracer names.
  defp do_block([{{:__block__, _, [:do]}, _body} | _clauses] = block), do: {:ok, block}
  defp do_block(_other), do: :error

  defp literal_string({:__block__, _, [text]}) when is_binary(text), do: text
  defp literal_string(_dynamic), do: nil

  # `{describe, name, compiled_name}`, or `nil` for a test whose name, or whose describe's
  # name, is not a literal string and so compiles to a name no parser can know.
  defp test_description(_describe, nil), do: nil
  defp test_description(nil, name), do: {nil, name, test_name("test #{name}")}
  defp test_description({nil, _index}, _name), do: nil

  defp test_description({describe, _index}, name),
    do: {describe, name, test_name("test #{describe} #{name}")}

  # `ExUnit.Case`'s own rule for a name past the 255 bytes an atom may hold: the first 246
  # bytes, an ellipsis and a short hash of the whole description.
  defp test_name(description) when byte_size(description) > 255 do
    hash = :erlang.md5(description) |> binary_slice(0, 3) |> Base.encode64()
    test_name(String.byte_slice(description, 0, 246) <> "... " <> hash)
  end

  defp test_name(description), do: String.to_atom(description)

  defp setup_name(:setup_all, _describe, count), do: :"__ex_unit_setup_all_#{count}"
  defp setup_name(:setup, nil, count), do: :"__ex_unit_setup_#{count}"
  defp setup_name(:setup, {_name, index}, count), do: :"__ex_unit_setup_#{index}_#{count}"

  # A setup with a `do` block defines a function; any other argument names callbacks, which
  # ExUnit registers one per entry of a literal list and one for anything else.
  defp setup_callbacks(args) do
    case {do_block(List.last(args)), args} do
      {{:ok, block}, _args} -> {:block, block}
      {:error, [{:__block__, _, [list]}]} when is_list(list) -> {:callbacks, length(list)}
      {:error, _args} -> {:callbacks, 1}
    end
  end

  # The tags `@tag` attaches: `@tag :slow` is `slow`, and each key of `@tag timeout: 100`
  # is its own tag.
  defp tags(pending) do
    pending
    |> Enum.flat_map(fn
      {:@, _, [{:tag, _, [value]}]} -> tag_names(value)
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp tag_names({:__block__, _, [name]}) when is_atom(name), do: [Atom.to_string(name)]
  defp tag_names({:__block__, _, [pairs]}) when is_list(pairs), do: tag_names(pairs)

  defp tag_names(pairs) when is_list(pairs) do
    for {{:__block__, _, [key]}, _value} <- pairs, is_atom(key), do: Atom.to_string(key)
  end

  defp tag_names(_dynamic), do: []

  defp add_block(acc, module, kind, name, node, block, pending, test) do
    first = List.first(pending) || node
    %{start: [line: start_line, column: _]} = Sourceror.get_range(first, include_comments: true)

    %{start: [line: head_line, column: _], end: [line: end_line, column: _]} =
      Sourceror.get_range(node)

    sites = collect_sites(block)

    definition = %{
      module: module,
      name: name,
      arity: 1,
      arities: [1],
      kind: kind,
      file: acc.file,
      start_line: start_line,
      end_line: end_line,
      source: nil,
      call_sites: sites.call_sites,
      route_sites: sites.route_sites,
      head_positions: [],
      head_ranges: [],
      clauses: [{head_line, end_line}],
      arms: arms(node, block),
      test: test
    }

    %{acc | definitions: merge_clause(acc.definitions, definition, acc.lines)}
  end

  defp add_embed(acc, module, {:__block__, _meta, [pattern]}, opts, meta)
       when is_binary(pattern) do
    embed = %{
      module: module,
      pattern: pattern,
      suffix: embed_option(opts, :suffix),
      root: embed_option(opts, :root),
      file: acc.file,
      line: meta[:line]
    }

    %{acc | embeds: [embed | acc.embeds]}
  end

  defp add_embed(acc, _module, _dynamic_pattern, _opts, _meta), do: acc

  # Only a literal string in a literal keyword list is read. An option computed elsewhere
  # (`suffix: @suffix`) is a value no parser can know, and guessing it would name a function
  # the compiler never defined, so it reads as absent.
  defp embed_option([opts], key) when is_list(opts) do
    Enum.find_value(opts, fn
      {{:__block__, _, [^key]}, {:__block__, _, [value]}} when is_binary(value) -> value
      _pair -> nil
    end)
  end

  defp embed_option(_opts, _key), do: nil

  defp add_clause(acc, module, kind, head, node, pending) do
    case head_signature(head) do
      nil ->
        acc

      {name, arity, arities} ->
        first = List.first(pending) || node

        %{start: [line: start_line, column: _]} =
          Sourceror.get_range(first, include_comments: true)

        %{start: [line: head_line, column: _], end: [line: end_line, column: _]} =
          Sourceror.get_range(node)

        sites = clause_sites(node)
        {head_positions, head_ranges} = head_location(head, name)

        clause = %{
          module: module,
          name: name,
          arity: arity,
          arities: arities,
          kind: kind,
          file: acc.file,
          start_line: start_line,
          end_line: end_line,
          source: nil,
          call_sites: sites.call_sites,
          route_sites: sites.route_sites,
          head_positions: head_positions,
          head_ranges: head_ranges,
          clauses: if(bodiless?(node), do: [], else: [{head_line, end_line}]),
          arms: arms(node, List.last(elem(node, 2)))
        }

        %{acc | definitions: merge_clause(acc.definitions, clause, acc.lines)}
    end
  end

  defp merge_clause(definitions, clause, lines) do
    key = {clause.module, clause.name, clause.arity}

    case Enum.split_with(definitions, &({&1.module, &1.name, &1.arity} == key)) do
      {[existing], rest} ->
        merged = %{
          existing
          | start_line: min(existing.start_line, clause.start_line),
            end_line: max(existing.end_line, clause.end_line),
            arities: Enum.uniq(Enum.sort(existing.arities ++ clause.arities)),
            call_sites: existing.call_sites ++ clause.call_sites,
            route_sites: existing.route_sites ++ clause.route_sites,
            head_positions: Enum.uniq(existing.head_positions ++ clause.head_positions),
            head_ranges: Enum.uniq(existing.head_ranges ++ clause.head_ranges),
            clauses: existing.clauses ++ clause.clauses,
            arms: Enum.sort(existing.arms ++ clause.arms)
        }

        [with_source(merged, lines) | rest]

      {[], rest} ->
        [with_source(clause, lines) | rest]
    end
  end

  defp with_source(definition, lines) do
    source =
      lines
      |> Enum.slice(definition.start_line - 1, definition.end_line - definition.start_line + 1)
      |> Enum.join("\n")

    %{definition | source: source}
  end

  # A head written without a body — the one that declares default arguments ahead of the
  # clauses — has nothing to enter.
  defp bodiless?({_kind, _meta, [_head]}), do: true
  defp bodiless?(_node), do: false

  # `block` is the definition's own keyword list — its `do` and whatever `rescue`, `catch`,
  # `else` or `after` it writes, which the compiler turns into a `try` around the body.
  defp arms(node, block) do
    own = keyword_arms(block, [:rescue, :catch, :else, :after])

    {_, arms} =
      Macro.prewalk(node, own, fn
        {:case, _, [_ | _] = args} = node, arms ->
          {node, keyword_arms(List.last(args), [:do]) ++ arms}

        {:cond, _, [block]} = node, arms ->
          {node, keyword_arms(block, [:do]) ++ arms}

        {:receive, _, [block]} = node, arms ->
          {node, keyword_arms(block, [:do, :after]) ++ arms}

        {:with, _, [_ | _] = args} = node, arms ->
          {node, keyword_arms(List.last(args), [:else]) ++ arms}

        {:try, _, [block]} = node, arms ->
          {node, keyword_arms(block, [:rescue, :catch, :else, :after]) ++ arms}

        {:fn, _, [_, _ | _] = clauses} = node, arms ->
          {node, Enum.flat_map(clauses, &arrow_lines/1) ++ arms}

        node, arms ->
          {node, arms}
      end)

    Enum.sort(arms)
  end

  # The arms under the given keys of a `do` block's keyword list. A key holding `->`
  # clauses gives one arm per clause; a `try`'s `after` holds a plain body, which is one arm
  # starting at the `after` keyword.
  defp keyword_arms(block, keys) when is_list(block) do
    Enum.flat_map(block, fn
      {{:__block__, meta, [key]}, value} when is_atom(key) ->
        cond do
          key not in keys -> []
          arrows?(unwrap(value)) -> Enum.flat_map(unwrap(value), &arrow_lines/1)
          key == :after -> body_lines(meta, value)
          true -> []
        end

      _other ->
        []
    end)
  end

  defp keyword_arms(_other, _keys), do: []

  # Clauses written in parentheses, as a keyword's value (`else: (_ -> :error)`), come
  # wrapped in a block holding their list.
  defp unwrap({:__block__, _meta, [list]}) when is_list(list), do: list
  defp unwrap(value), do: value

  defp arrows?(value), do: is_list(value) and Enum.all?(value, &match?({:->, _, _}, &1))

  defp arrow_lines({:->, _, _} = arrow) do
    case Sourceror.get_range(arrow) do
      %{start: [line: start_line, column: _], end: [line: end_line, column: _]} ->
        [{start_line, end_line}]

      _other ->
        []
    end
  end

  defp arrow_lines(_other), do: []

  defp body_lines(meta, body) do
    with start_line when is_integer(start_line) <- meta[:line],
         %{end: [line: end_line, column: _]} <- Sourceror.get_range(body) do
      [{start_line, end_line}]
    else
      _ -> []
    end
  end

  defp head_signature({:when, _, [head, _guard]}), do: head_signature(head)

  defp head_signature({name, _, args}) when is_atom(name) and (is_list(args) or is_nil(args)) do
    args = args || []
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, [_, _]}, &1))
    {name, arity, Enum.to_list((arity - defaults)..arity//1)}
  end

  defp head_signature(_dynamic), do: nil

  defp head_location({:when, _, [head, _guard]}, name), do: head_location(head, name)

  defp head_location({name, meta, _args}, name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      width = String.length(Atom.to_string(name))
      {[{line, column}], [%{start: {line, column}, end: {line, column + width}}]}
    else
      _ -> {[], []}
    end
  end

  defp head_location(_head, _name), do: {[], []}

  # The head itself is never a call site: the compiler reports its bookkeeping there, and
  # a site would put those events on the function name. Guards are searched because custom
  # guards (`when is_pos(x)`) are real calls, and so are default arguments, whose
  # expressions the compiler reports at their own position inside the head.
  defp clause_sites({_kind, _meta, [head | rest]}) do
    {signature, guard} =
      case head do
        {:when, _, [signature, guard]} -> {signature, [guard]}
        _ -> {head, []}
      end

    collect_sites(defaults(signature) ++ guard ++ rest)
  end

  @doc """
  Call sites for the Elixir written inside one interpolation body.

  `text` is parsed at `line` and `column`, the file position of its first character, so
  every site it yields carries the file's own coordinates. A body that does not parse is
  retried with an `end` appended, which is what an expression tag that opens a block
  (`<%= if allowed?(@user) do %>`) needs; a body that still does not parse yields nothing.
  """
  @spec expression_sites(String.t(), pos_integer(), pos_integer()) :: [call_site()]
  def expression_sites(text, line, column)
      when is_binary(text) and is_integer(line) and is_integer(column) do
    expression(text, line, column).call_sites
  end

  @doc """
  Route sites for the Elixir written inside one interpolation body: its `~p` sigils and
  the requests it makes.

  The arguments are `expression_sites/3`'s, and so is the parse: a body that only becomes
  an expression once an `end` is added is read that way, and one no parse can make sense
  of yields nothing.
  """
  @spec route_sites(String.t(), pos_integer(), pos_integer()) :: [route_site()]
  def route_sites(text, line, column)
      when is_binary(text) and is_integer(line) and is_integer(column) do
    expression(text, line, column).route_sites
  end

  defp expression(text, line, column) do
    options = [line: line, column: column]

    case Sourceror.parse_string(text, options) do
      {:ok, ast} ->
        collect_sites(ast)

      {:error, _reason} ->
        case Sourceror.parse_string(text <> "\nend", options) do
          {:ok, ast} -> collect_sites(ast)
          {:error, _reason} -> %{call_sites: [], route_sites: []}
        end
    end
  end

  @doc """
  Every call site a template's text holds: its component tags and its interpolations.

  The position arguments are `Grasp.Index.Heex.tag_sites/3`'s. Sites are returned in
  document order, one per position, which is the order and the shape `Grasp.Index.Join`
  reads them in.
  """
  @spec template_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [
          call_site()
        ]
  def template_sites(text, first_line_and_indent, first_line_column \\ nil) do
    interpolated =
      text
      |> Heex.interpolations(first_line_and_indent, first_line_column)
      |> Enum.flat_map(&expression_sites(&1.text, &1.line, &1.column))

    (Heex.tag_sites(text, first_line_and_indent, first_line_column) ++ interpolated)
    |> Enum.sort_by(&{&1.line, &1.column})
    |> Enum.uniq_by(&{&1.line, &1.column})
  end

  @doc """
  Every route a template's text names: its route attributes and the `~p` sigils inside it.

  The position arguments are `Grasp.Index.Heex.tag_sites/3`'s. A `~p` written as the value
  of a route attribute is dropped in favour of the attribute's own site, which covers the
  same text and knows the verb; a `~p` anywhere else in an interpolation is a route site
  of its own, read as a GET.
  """
  @spec template_route_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) ::
          [route_site()]
  def template_route_sites(text, first_line_and_indent, first_line_column \\ nil) do
    attributes = Heex.route_attributes(text, first_line_and_indent, first_line_column)
    covered = Enum.map(attributes, & &1.range)

    interpolated =
      text
      |> Heex.interpolations(first_line_and_indent, first_line_column)
      |> Enum.flat_map(&route_sites(&1.text, &1.line, &1.column))
      |> Enum.reject(fn site -> Enum.any?(covered, &inside?(site.range.start, &1)) end)

    (Enum.flat_map(attributes, &attribute_route_site/1) ++ interpolated)
    |> Enum.sort_by(& &1.range.start)
  end

  defp inside?(position, range), do: position >= range.start and position < range.end

  defp attribute_route_site(%{value: {:string, path}} = attribute) do
    case path_segments(path) do
      nil -> []
      segments -> [%{verb: verb(attribute), path: segments, range: attribute.range}]
    end
  end

  # The verb belongs to the attribute and the path to the sigil inside it, so the two are
  # read from either side of the same value. A value holding no `~p` — an assign, a helper
  # call — names a path only the running application knows.
  defp attribute_route_site(%{value: {:expr, body}} = attribute) do
    case route_sites(body.text, body.line, body.column) do
      [] -> []
      [site | _rest] -> [%{verb: verb(attribute), path: site.path, range: attribute.range}]
    end
  end

  # `hx-post` says what it is, and carries its own verb whatever else the tag writes.
  # Every other route attribute takes the tag's literal `method` where it has one, so
  # `<.link href={~p"/users/1"} method="delete">` is the DELETE it sends, and a GET
  # otherwise. A form's `action` with no `method` is a POST on a component form, since
  # `<.form>` sends everything but a GET as one and writes the real verb into a hidden
  # `_method` field, while a plain `<form>` is the GET HTML makes it.
  defp verb(%{name: "hx-" <> verb}), do: String.upcase(verb)

  defp verb(%{name: "action"} = attribute) do
    cond do
      attribute.method -> attribute.method
      component_tag?(attribute.tag) -> "POST"
      true -> "GET"
    end
  end

  defp verb(attribute), do: attribute.method || "GET"

  defp component_tag?("." <> _rest), do: true
  defp component_tag?(<<first::utf8, _rest::binary>>), do: first in ?A..?Z
  defp component_tag?(_tag), do: false

  @doc """
  The segments of a path, or `nil` for text no router could match.

  Takes a literal string or the parts of a `~p` sigil's `<<>>` node. A path must start
  with a single `/` — a leading `//` is a protocol-relative URL, whose first segment is a
  host rather than anything a router answers to. Everything from the first `?` or `#` on
  is dropped, as is the empty text between two slashes, so `"/"` is the empty list. A
  segment an interpolation reaches into is `:dynamic` whole, because the text around the
  interpolation is no more knowable than the interpolation itself.
  """
  @spec path_segments(String.t() | [String.t() | term()]) :: [segment()] | nil
  def path_segments(path) when is_binary(path), do: path_segments([path])

  def path_segments(parts) when is_list(parts) do
    items = path_items(parts, [])

    case items do
      [<<"//", _rest::binary>> | _] -> nil
      [<<"/", _rest::binary>> | _] -> segments(items)
      _items -> nil
    end
  end

  # Everything up to the first `?` or `#`, with each interpolation standing in for text
  # that is only known when the page is rendered.
  defp path_items([], items), do: Enum.reverse(items)

  defp path_items([piece | rest], items) when is_binary(piece) do
    case String.split(piece, ~r/[?#]/, parts: 2) do
      [^piece] -> path_items(rest, [piece | items])
      [before | _after] -> Enum.reverse([before | items])
    end
  end

  defp path_items([_interpolation | rest], items), do: path_items(rest, [:dynamic | items])

  defp segments(items) do
    {done, current} = Enum.reduce(items, {[], nil}, &segment_item/2)
    done |> close(current) |> Enum.reverse()
  end

  defp segment_item(:dynamic, {done, current}), do: {done, mark(current)}

  defp segment_item(text, {done, current}) when is_binary(text) do
    [first | rest] = String.split(text, "/")

    Enum.reduce(rest, {done, append(current, first)}, fn piece, {done, current} ->
      {close(done, current), append(nil, piece)}
    end)
  end

  defp append(nil, ""), do: nil
  defp append(nil, text), do: {false, text}
  defp append({dynamic?, read}, text), do: {dynamic?, read <> text}

  defp mark(nil), do: {true, ""}
  defp mark({_dynamic?, read}), do: {true, read}

  defp close(done, nil), do: done
  defp close(done, {true, _read}), do: [:dynamic | done]
  defp close(done, {false, read}), do: [read | done]

  # One walk reads a clause body and an interpolation body alike, so a call written in a
  # template is the same kind of site as a call written in Elixir. Both kinds of site come
  # out of the one walk, because a `~H` sigil holds both and reading it twice would mean
  # scanning the same template twice. A request's route site covers the path argument it
  # reads, which is the range the `~p` written there would have taken, so that sigil's own
  # GET is dropped in favour of the request's verb.
  defp collect_sites(ast) do
    {_, {calls, routes, requests, _piped}} =
      Macro.prewalk(ast, {[], [], [], MapSet.new()}, fn
        {:&, _, [{:/, _, [target, arity]}]} = node, {calls, routes, requests, piped} ->
          {node, {add_site(calls, target, written_arity(arity)), routes, requests, piped}}

        {:sigil_H, _meta, [{:<<>>, _str_meta, [content]}, _modifiers]} = node,
        {calls, routes, requests, piped}
        when is_binary(content) ->
          sites = sigil_sites(node)

          {node,
           {Enum.reverse(sites.call_sites) ++ calls, Enum.reverse(sites.route_sites) ++ routes,
            requests, piped}}

        {:sigil_p, _meta, [{:<<>>, _str_meta, parts}, _modifiers]} = node,
        {calls, routes, requests, piped} ->
          {node, {calls, sigil_route_site(routes, node, parts), requests, piped}}

        {:|>, _meta, [_left, right]} = node, {calls, routes, requests, piped} ->
          {requests, piped} = piped_request(requests, piped, right)
          {node, {calls |> add_site(node) |> piped_site(right), routes, requests, piped}}

        {{:., _, _}, _, args} = node, {calls, routes, requests, piped} when is_list(args) ->
          {node, {add_site(calls, node), routes, request(requests, piped, node), piped}}

        {name, _, args} = node, {calls, routes, requests, piped}
        when is_atom(name) and is_list(args) and name not in @not_calls ->
          calls = if(sigil?(name), do: calls, else: add_site(calls, node))
          {node, {calls, routes, request(requests, piped, node), piped}}

        node, sites ->
          {node, sites}
      end)

    covered = MapSet.new(requests, & &1.range)

    route_sites =
      routes
      |> Enum.reject(&MapSet.member?(covered, &1.range))
      |> Enum.concat(requests)
      |> Enum.sort_by(& &1.range.start)

    %{
      call_sites: calls |> Enum.reverse() |> Enum.uniq_by(&{&1.line, &1.column}),
      route_sites: route_sites
    }
  end

  # A request is `get(conn, path)` and its kin: the verb its name gives and the path its
  # second argument writes, whether the function is local, imported or called on a test
  # module — one whose alias ends in `Test`, as `Phoenix.ConnTest` and
  # `Phoenix.LiveViewTest` do. `Map.get(params, "/")` and an HTTP client's `get` share the
  # shape and name no route of this application.
  # Piped, the path is the first argument written, and the piped call is marked so the walk
  # reaching it next does not read its written arguments a second time.
  defp request(requests, piped, node) do
    case {MapSet.member?(piped, node), request_call(node)} do
      {false, {verb, [_conn, path | _rest]}} -> request_site(requests, verb, path)
      _other -> requests
    end
  end

  defp piped_request(requests, piped, right) do
    case request_call(right) do
      {verb, [path | _rest]} -> {request_site(requests, verb, path), MapSet.put(piped, right)}
      {_verb, []} -> {requests, MapSet.put(piped, right)}
      nil -> {requests, piped}
    end
  end

  defp request_call({{:., _, [{:__aliases__, _, segments}, name]}, _meta, args})
       when is_atom(name) and is_list(args) do
    if test_module?(segments), do: request_verb(name, args)
  end

  defp request_call({{:., _, _}, _meta, _args}), do: nil

  defp request_call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: request_verb(name, args)

  defp request_call(_node), do: nil

  defp test_module?(segments) do
    case List.last(segments) do
      last when is_atom(last) -> last |> Atom.to_string() |> String.ends_with?("Test")
      _other -> false
    end
  end

  defp request_verb(name, args) do
    case Map.fetch(@request_verbs, name) do
      {:ok, verb} -> {verb, args}
      :error -> nil
    end
  end

  defp request_site(requests, verb, path) do
    with {:ok, parts} <- path_parts(path),
         segments when is_list(segments) <- path_segments(parts),
         range when is_map(range) <- node_range(path) do
      [%{verb: verb, path: segments, range: range} | requests]
    else
      _ -> requests
    end
  end

  # A literal string, one with interpolations, or a `~p` sigil: the forms whose text says
  # the path. A variable or a helper call names a path only the running test knows. A
  # heredoc's text ends in the newline before its closing delimiter, which is no part of
  # the path it writes.
  defp path_parts({:__block__, meta, [text]}) when is_binary(text),
    do: {:ok, heredoc_trimmed(meta, [text])}

  defp path_parts({:<<>>, meta, parts}), do: {:ok, heredoc_trimmed(meta, parts)}

  defp path_parts({:sigil_p, meta, [{:<<>>, _str_meta, parts}, _modifiers]}),
    do: {:ok, heredoc_trimmed(meta, parts)}

  defp path_parts(_expression), do: :error

  defp heredoc_trimmed(meta, parts) do
    with delimiter when delimiter in ~w(""" ''') <- meta[:delimiter],
         last when is_binary(last) <- List.last(parts) do
      List.replace_at(parts, -1, String.trim_trailing(last, "\n"))
    else
      _ -> parts
    end
  end

  # A `~p` names a path and nothing else: the router decides what it reaches, and a GET is
  # what a path written on its own means until an attribute says otherwise.
  defp sigil_route_site(routes, node, parts) do
    with segments when is_list(segments) <- path_segments(parts),
         range when is_map(range) <- node_range(node) do
      [%{verb: "GET", path: segments, range: range} | routes]
    else
      _ -> routes
    end
  end

  defp node_range(node) do
    case Sourceror.get_range(node) do
      %{
        start: [line: start_line, column: start_column],
        end: [line: end_line, column: end_column]
      } ->
        %{start: {start_line, start_column}, end: {end_line, end_column}}

      _other ->
        nil
    end
  end

  defp written_arity({:__block__, _meta, [arity]}) when is_integer(arity), do: arity
  defp written_arity(_other), do: nil

  # A sigil is written as a call to `sigil_x/2` and the compiler reports it as one, but the
  # macro behind it describes how the literal is built rather than what the code calls.
  defp sigil?(name), do: name |> Atom.to_string() |> String.starts_with?("sigil_")

  # The compiler reports a piped call with the piped value as its first argument, so the
  # site records one more than the arguments written between the parentheses. The prewalk
  # reaches a pipe before its right-hand side, and `collect_sites/1` keeps the first site
  # at a position, so this site is the one that survives the walk into that call node.
  defp piped_site(sites, {{:., _, [_receiver, name]}, _meta, args} = right)
       when is_atom(name) and is_list(args),
       do: add_site(sites, right, length(args) + 1)

  defp piped_site(sites, {name, _meta, args} = right)
       when is_atom(name) and is_list(args) and name not in @not_calls do
    if sigil?(name), do: sites, else: add_site(sites, right, length(args) + 1)
  end

  defp piped_site(sites, _right), do: sites

  defp defaults({_name, _meta, args}) when is_list(args),
    do: for({:\\, _, [_arg, default]} <- args, do: default)

  defp defaults(_head), do: []

  defp add_site(sites, node, arity \\ nil) do
    case call_range(node) do
      nil ->
        sites

      {line, column, range} ->
        site = %{
          line: line,
          column: column,
          range: range,
          template: template(node),
          callee: callee(node, arity)
        }

        [site | sites]
    end
  end

  # The arity is the argument list's length, except for a capture, where the caller reads
  # it off the `/2` the source wrote and the name carries no arguments at all.
  defp callee({{:., _, [receiver, name]}, _meta, args}, nil) when is_atom(name) and is_list(args),
    do: %{module: receiver_name(receiver), name: name, arity: length(args)}

  defp callee({{:., _, [receiver, name]}, _meta, _args}, arity)
       when is_atom(name) and is_integer(arity),
       do: %{module: receiver_name(receiver), name: name, arity: arity}

  defp callee({name, _meta, args}, nil) when is_atom(name) and is_list(args),
    do: %{module: nil, name: name, arity: length(args)}

  defp callee({name, _meta, _args}, arity) when is_atom(name) and is_integer(arity),
    do: %{module: nil, name: name, arity: arity}

  defp callee(_node, _arity), do: nil

  # Only a receiver the source spells out as a module is recorded. `mod.f(x)` names a
  # module no parser can know, and a call placed by name against it would match anything;
  # `nil`, `true` and `false` are values, not the modules their text would name.
  defp receiver_name({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp receiver_name({:__block__, _meta, [atom]})
       when is_atom(atom) and atom not in [nil, true, false],
       do: inspect(atom)

  defp receiver_name(_expression), do: nil

  # `~H"""` content reaches the compiler with the heredoc's indentation stripped, starting on
  # the line below the sigil, which is where these file positions put it too.
  defp sigil_sites({:sigil_H, meta, [{:<<>>, str_meta, [content]}, _modifiers]}) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      delimiter = meta[:delimiter] || str_meta[:delimiter]

      if delimiter in ~w(""" ''') do
        position = {line + 1, str_meta[:indentation] || 0}

        %{
          call_sites: template_sites(content, position),
          route_sites: template_route_sites(content, position)
        }
      else
        %{
          call_sites: inline_sigil_sites(content, line, column),
          route_sites: template_route_sites(content, {line, 0}, column + 3)
        }
      end
    else
      _ -> %{call_sites: [], route_sites: []}
    end
  end

  # `Phoenix.Component.sigil_H/2` hands EEx `line: caller line + 1` and `indentation: 0`
  # whatever the delimiter, so the compiler reports the calls of a single-line `~H"..."` one
  # line below the sigil at their column within the content. `Grasp.Index.Join` keys a site
  # by line and column and renders its range, so the site carries the compiler's position as
  # the key and the file's own — three columns past the `~`, after the sigil name and its
  # opening quote — as the range the reader clicks. Both lists come from one function, so
  # they hold the same sites in the same order and zip.
  defp inline_sigil_sites(content, line, column) do
    keys = template_sites(content, {line + 1, 0})
    ranges = template_sites(content, {line, 0}, column + 3)

    Enum.zip_with(keys, ranges, &%{&1 | range: &2.range})
  end

  # The template a `render(conn, :show, …)` or `render(conn, "show.html", …)` call renders.
  defp template({{:., _, [_receiver, :render]}, _meta, [_first, second | _rest]}),
    do: template_name(second)

  defp template({:render, _meta, [_first, second | _rest]}), do: template_name(second)
  defp template(_node), do: nil

  defp template_name({:__block__, _meta, [name]}) when is_atom(name),
    do: template_name(Atom.to_string(name))

  defp template_name({:__block__, _meta, [name]}) when is_binary(name), do: template_name(name)
  defp template_name(name) when is_binary(name), do: String.replace_suffix(name, ".html", "")
  defp template_name(_other), do: nil

  # Remote call: the compiler reports the function name's position; the range starts at
  # the receiver when it is a literal alias/atom (`Formatter.wrap`) and at the name
  # otherwise (`foo().bar`), so nothing but the callee gets wrapped.
  defp call_range({{:., _, [receiver, name]}, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      start =
        case receiver do
          {:__aliases__, alias_meta, _} ->
            {alias_meta[:line], alias_meta[:column]}

          {:__block__, atom_meta, [atom]} when is_atom(atom) ->
            {atom_meta[:line], atom_meta[:column]}

          _expression ->
            {line, column}
        end

      {line, column, %{start: start, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range({name, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      {line, column,
       %{start: {line, column}, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range(_other), do: nil
end
