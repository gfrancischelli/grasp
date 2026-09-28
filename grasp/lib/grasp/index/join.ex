defmodule Grasp.Index.Join do
  @moduledoc """
  Pairs compiler tracer events with the definitions Sourceror extracted, producing the
  function records the index stores.

  An event is attributed to the definition whose module, name and arity match the caller
  the compiler reported; a definition registers every arity its default arguments
  introduce, so calls made through any of them land on it. The event's line and column
  then locate the call node inside that definition, giving a call with a clickable range.

  Seven rules decide what survives:

    * **Head positions.** The compiler reports its own bookkeeping at every clause head —
      `Module.compile_definition_attributes/6` and any `@on_definition` hook a library
      installs — at the head's line and the function name's column. Every event at a
      position the definition lists as a head is dropped.
    * **Compiler internals.** Targets in `Kernel`, `Kernel.SpecialForms` and
      `Kernel.Utils`, and in the compiler's own Erlang modules (`:elixir_quote`,
      `:elixir_def`, ...), describe how the code was expanded rather than what it calls.
      `unquote(x)` inside a macro body, reported as `:elixir_quote.unquote/1`, is the
      common case.
    * **Reflection.** A `__name__`-shaped target — `__schema__/1`, `__struct__/1`,
      `Phoenix.VerifiedRoutes.__encode_segment__/1` — is machinery a macro expanded into,
      never a call anyone wrote, so it is dropped wherever it was reported. Position is no
      defence: a `~p` sigil reports its segment encoder at the interpolation's own line and
      column, which matches a real call node, and the rules below would otherwise hand the
      reader a clickable call that says nothing about what the function does.
    * **Sigils.** A `sigil_`-prefixed target — `Phoenix.Component.sigil_H/2`,
      `Phoenix.VerifiedRoutes.sigil_p/2` — is the macro that builds a literal out of the
      text beside it, which says nothing about what the function calls, so it is dropped
      wherever it was reported. A template holding thirty links would otherwise draw thirty
      clickable calls into the same route macro.
    * **`defdelegate`.** The delegated call is reported with no column, so it can only be
      placed by kind: for a `defdelegate`, a column-less event becomes a visible call
      ranged over the delegate's own name.
    * **Column-less events.** Macro- and template-generated code is reported without a
      column — a call written inside a `{...}` interpolation is the common case. Outside a
      `defdelegate` (which turns its one column-less delegated call into a visible call),
      such an event is first offered to every call site of the definition that carries a
      callee, wherever the source wrote it: an interpolation, a `~H` body, or the clause
      body itself. A site claims the event when it sits on the event's line, no
      column-bearing event has claimed it, its written name and arity are the event's, and
      its written module — where the source spells one out — is the target module or a
      suffix of it; the event then becomes a visible call over that site's range. Nothing
      narrower is right: an event carrying the name and arity of a call written on that
      line *is* that call, wherever the definition wrote it, and a macro that forwards its
      argument reports the forwarded call with the line alone. Two identical calls on one
      line are handed to their two sites in document order. Only what no site claims
      reaches the rule below it, where an event becomes a hidden call when its line falls
      inside the definition's span *and* its target is a definition the index holds. A
      macro that expands into a dependency — a template engine, a query builder, `Logger` —
      reports the macro's own implementation, not what the function set out to do, and on a
      real project those outnumber the project calls worth seeing by more than ten to one;
      OTP's `:erlang` operators that `and` and `>` expand to are not definitions the index
      holds, so they fall out the same way.
    * **Hidden calls.** An event with a column but no matching node came from
      macro-generated code — a function component in a `~H` template, code injected by
      `use` — and is kept as a hidden call so the graph stays complete even though
      nothing in the source can be clicked.

  A definition's double sites — the Mox expectations it writes — pass through too, on the
  records of the definitions that have any, for `Grasp.Index.Doubles` to resolve.

  A definition's route sites pass through untouched: nothing here knows what path the
  router answers to, so `Grasp.Index.Routes` resolves them into calls of kind `:route`
  once the project's routes have been detected.

  One call is rewritten rather than filtered. `render(conn, :show)` in a controller is
  reported as a call into `Phoenix.Controller`, which tells a reader nothing; under
  Phoenix 1.7's `use Phoenix.Controller, formats: [:html]` convention it renders the
  template `show` of the module whose name is the controller's with `Controller` swapped
  for `HTML`. When the index holds that template, the call is written against it with kind
  `:template`, so the controller's card reaches the markup it renders. Known gap: a
  controller that names another module with `put_view` is not followed — its `render` stays
  the external call the compiler reported.
  """

  alias Grasp.Index.{Extract, Tracer}

  @ignored_targets [Kernel, Kernel.SpecialForms, Kernel.Utils]
  # Reported at every definition. Most kinds carry the head's position, where the
  # positional rule catches it; a `defdelegate` reports it with no column, and there only
  # the target tells it apart from the delegated call.
  @definition_bookkeeping {Module, :compile_definition_attributes, 6}

  @type call :: %{
          required(:target) => String.t(),
          required(:kind) => Tracer.kind() | :template | :route | :enqueue | :double,
          required(:range) => Extract.range(),
          optional(:route) => %{verb: String.t(), path: String.t()},
          optional(:job) => %{worker: String.t(), queue: String.t()},
          optional(:via) => %{target: String.t(), kind: Tracer.kind() | :template},
          optional(:double) => %{mock: String.t(), behaviour: String.t()}
        }
  # `:route` is written by `Grasp.Index.Routes` on a call of kind `:route` alone, and holds
  # the router's own verb and path, which is what the reader is told the link reaches.
  # `:job` is written by `Grasp.Index.Jobs` on a call of kind `:enqueue` alone, and names
  # the worker and the queue the job runs on.
  # `:via` is the call an enqueue edge stands for, kept so the edge can be undone and drawn
  # again when the workers change.
  # `:double` is written by `Grasp.Index.Doubles` on a call of kind `:double` alone, and names
  # the Mox mock a test set up and the behaviour the mock stands in for.
  @type hidden_call :: %{target: String.t(), kind: Tracer.kind(), line: pos_integer()}

  # `test` is carried over from the definition, which has one only for a test or a setup, and
  # `double_sites` from a definition that writes a Mox expectation, for `Grasp.Index.Doubles`.
  @type function_record :: %{
          optional(:test) => Extract.test_info() | nil,
          optional(:double_sites) => [Extract.double_site()],
          id: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: Extract.kind(),
          file: String.t(),
          span: %{start_line: pos_integer(), end_line: pos_integer()},
          source: String.t(),
          calls: [call()],
          hidden_calls: [hidden_call()],
          route_sites: [Extract.route_site()],
          clauses: [Extract.line_range()],
          arms: [Extract.line_range()]
        }

  @doc """
  Builds the `\"Module.name/arity\"` id.

  `module` may be an atom or its `inspect/1` form and `name` an atom or its text, so an id
  can be rebuilt from a record read back out of an index document without turning its
  strings into atoms. The name is written as a remote call writes it,
  `Macro.inspect_atom(:remote_call, name)`: `greet`, `valid?` and `+` bare, and a name no
  call could spell bare quoted, as in `SampleAppWeb.GreetControllerTest."test greet/2 says hello"/1`.
  A name given as text is written the same way without creating an atom.
  """
  @spec function_id(module() | String.t(), atom() | String.t(), non_neg_integer()) :: String.t()
  def function_id(module, name, arity) when is_atom(module),
    do: function_id(inspect(module), name, arity)

  def function_id(module, name, arity) when is_binary(module),
    do: "#{module}.#{function_name(name)}/#{arity}"

  defp function_name(name) when is_atom(name), do: Macro.inspect_atom(:remote_call, name)

  # A name that is an atom already takes the atom's spelling, which covers every operator,
  # since the parser defines them all. Any other is an identifier or text only quoting can
  # write: `Code.Fragment.cursor_context/1` reads an identifier as the whole of the text it is
  # given without creating an atom, and anything it reads differently is quoted as a quoted
  # atom is, printable or not. The rescue runs for every name the VM holds no atom for, as
  # a test's name read back from an index document is, and costs one raised error each.
  defp function_name(name) when is_binary(name) do
    Macro.inspect_atom(:remote_call, String.to_existing_atom(name))
  rescue
    ArgumentError ->
      if Code.Fragment.cursor_context(name) == {:local_or_var, String.to_charlist(name)},
        do: name,
        else: inspect(name, binaries: :as_strings)
  end

  @doc """
  Turns definitions and tracer events into function records with resolved calls.

  Options:

    * `:known_ids` — function ids the index holds beyond `definitions`. A hidden call is
      kept only when its target is a function the index holds, and a controller's `render`
      is rewritten only against a template the index holds, so a caller joining one file at
      a time — `Grasp.Index.Incremental` — passes the ids of the records it is not
      rebuilding; without them every call reaching out of that file would read as a call
      into nothing.
    * `:unmatched_positions` — what becomes of an event that carries a column but lands on
      no call site in the definition. `:hide` (the default) keeps it as a hidden call,
      which is what a full build wants: the position came from macro-generated code and the
      call is real even though nothing in the source can be clicked. `:drop` discards it,
      which is what a caller joining events to a file that may have been saved since wants:
      there the same shape is just as likely to be an event describing a line that has
      moved, and a phantom hidden call is worse than a missing one.
  """
  @spec join([Extract.definition()], [Tracer.event()],
          known_ids: MapSet.t(String.t()),
          unmatched_positions: :hide | :drop
        ) :: [function_record()]
  def join(definitions, events, opts \\ []) do
    known_ids = Keyword.get(opts, :known_ids, MapSet.new())
    unmatched = Keyword.get(opts, :unmatched_positions, :hide)
    {canonical, indexed} = reachable(definitions, known_ids)

    events_by_definition =
      events
      |> Enum.filter(&keep?/1)
      |> Enum.group_by(fn event ->
        {name, arity} = event.function
        Map.get(canonical, {inspect(event.module), name, arity})
      end)

    Enum.map(definitions, fn definition ->
      key = {definition.module, definition.name, definition.arity}
      build(definition, Map.get(events_by_definition, key, []), indexed, unmatched)
    end)
  end

  # Every arity a definition answers to, paired with the definition it resolves to and
  # collected into the set of ids the index holds, in one pass over the definitions.
  defp reachable(definitions, known_ids) do
    Enum.reduce(definitions, {%{}, known_ids}, fn definition, acc ->
      key = {definition.module, definition.name, definition.arity}

      Enum.reduce(definition.arities, acc, fn arity, {canonical, indexed} ->
        {Map.put(canonical, {definition.module, definition.name, arity}, key),
         MapSet.put(indexed, function_id(definition.module, definition.name, arity))}
      end)
    end)
  end

  defp keep?(%{target: {module, _, _}}) when module in @ignored_targets, do: false

  defp keep?(%{target: {module, name, _}}),
    do: not compiler_internal?(module) and not reflection?(name) and not sigil?(name)

  defp compiler_internal?(module),
    do: module |> Atom.to_string() |> String.starts_with?("elixir_")

  defp reflection?(name) do
    name = Atom.to_string(name)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  defp sigil?(name), do: name |> Atom.to_string() |> String.starts_with?("sigil_")

  # The template a controller's `render` reaches, when the index holds it: the HTML module
  # Phoenix resolves by convention, the name the site read from the call's second argument,
  # and arity 1, which is every embedded template's arity. Only `Phoenix.Controller`'s own
  # `render` renders through that convention, so another module's `render` — a PDF or CSV
  # renderer a controller calls with the same literal — stays the call the compiler made.
  defp template_call(%{target: {Phoenix.Controller, :render, _arity}}, definition, site, indexed) do
    with template when is_binary(template) <- site.template,
         true <- String.ends_with?(definition.module, "Controller"),
         html = String.replace_suffix(definition.module, "Controller", "HTML"),
         target = function_id(html, template, 1),
         true <- MapSet.member?(indexed, target) do
      %{target: target, kind: :template, range: site.range}
    else
      _ -> nil
    end
  end

  defp template_call(_event, _definition, _site, _indexed), do: nil

  # The site that wrote the call an event reports with no column: the first one left on
  # that line whose name and arity are the event's, and whose module, where the source
  # names one, is the module the compiler resolved or the tail of it — a call written
  # through an alias (`Greeter.greet(@name)`) reports `SampleApp.Greeter`. A site an event
  # of its own lands on positionally is spoken for, so the same range is never handed out
  # twice.
  defp named_site(sites, claimed, event) do
    {module, name, arity} = event.target

    Enum.find(sites, fn site ->
      site.line == event.line and site.callee.name == name and site.callee.arity == arity and
        written_module?(site.callee.module, module) and
        not MapSet.member?(claimed, {site.line, site.column})
    end)
  end

  # The positions the column-bearing events of this definition own.
  defp positioned_sites(events, sites, heads) do
    for event <- events,
        event.column != nil,
        not MapSet.member?(heads, {event.line, event.column}),
        Map.has_key?(sites, {event.line, event.column}),
        into: MapSet.new(),
        do: {event.line, event.column}
  end

  defp written_module?(nil, _module), do: true

  defp written_module?(written, module) do
    resolved = inspect(module)
    resolved == written or String.ends_with?(resolved, "." <> written)
  end

  defp build(definition, events, indexed, unmatched) do
    sites = Map.new(definition.call_sites, &{{&1.line, &1.column}, &1})

    named =
      definition.call_sites |> Enum.filter(& &1.callee) |> Enum.sort_by(&{&1.line, &1.column})

    heads = MapSet.new(definition.head_positions)
    delegate_range = if definition.kind == :defdelegate, do: List.first(definition.head_ranges)
    span = definition.start_line..definition.end_line
    positioned = positioned_sites(events, sites, heads)

    {calls, hidden, _claimed} =
      Enum.reduce(events, {[], [], positioned}, fn event, {calls, hidden, claimed} ->
        {module, name, arity} = event.target
        target = function_id(module, name, arity)
        call = fn range -> %{target: target, kind: event.kind, range: range} end
        hidden_call = %{target: target, kind: event.kind, line: event.line}

        cond do
          MapSet.member?(heads, {event.line, event.column}) ->
            {calls, hidden, claimed}

          event.column == nil and event.target == @definition_bookkeeping ->
            {calls, hidden, claimed}

          event.column == nil ->
            cond do
              delegate_range ->
                {[call.(delegate_range) | calls], hidden, claimed}

              site = named_site(named, claimed, event) ->
                {[call.(site.range) | calls], hidden,
                 MapSet.put(claimed, {site.line, site.column})}

              not MapSet.member?(indexed, target) ->
                {calls, hidden, claimed}

              event.line in span ->
                {calls, [hidden_call | hidden], claimed}

              true ->
                {calls, hidden, claimed}
            end

          true ->
            case Map.fetch(sites, {event.line, event.column}) do
              {:ok, site} ->
                resolved = template_call(event, definition, site, indexed) || call.(site.range)
                {[resolved | calls], hidden, claimed}

              :error when unmatched == :hide ->
                {calls, [hidden_call | hidden], claimed}

              :error ->
                {calls, hidden, claimed}
            end
        end
      end)

    %{
      id: function_id(definition.module, definition.name, definition.arity),
      module: definition.module,
      name: definition.name,
      arity: definition.arity,
      arities: definition.arities,
      kind: definition.kind,
      file: definition.file,
      span: %{start_line: definition.start_line, end_line: definition.end_line},
      source: definition.source,
      calls: calls |> Enum.uniq() |> Enum.sort_by(&{&1.range.start, &1.target, &1.kind}),
      hidden_calls: hidden |> Enum.uniq() |> Enum.sort_by(&{&1.line, &1.target, &1.kind}),
      route_sites: definition.route_sites,
      clauses: Map.get(definition, :clauses, []),
      arms: Map.get(definition, :arms, [])
    }
    |> Map.merge(Map.take(definition, [:test]))
    |> put_double_sites(Map.get(definition, :double_sites, []))
  end

  defp put_double_sites(record, []), do: record
  defp put_double_sites(record, sites), do: Map.put(record, :double_sites, sites)
end
