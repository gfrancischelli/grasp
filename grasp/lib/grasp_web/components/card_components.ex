defmodule GraspWeb.CardComponents do
  @moduledoc """
  One card on the canvas: the node the canvas drags, the card itself, and the stub shown
  for a function the index does not contain.

  A card carries no knowledge of what it calls beyond the edges leaving it. Each of those
  edges paints its own call site — the span in the body, or the button in the "Also calls"
  footer — with the edge's palette colour and the id of the card at the far end, so the
  connector layer can join the two without a second source of truth.

  A test card is named by its test rather than its compiled function: the header wears a
  `test` badge, titles itself with the test's name and fills the module slot with its
  `describe`, or its module when there is none, and signature mode shows its assertion
  lines where a function card shows its head. A setup callback wears `setup` and is titled
  `setup` or `setup_all`. The node's `data-module` is read from the record, so a test
  clusters with its module whatever its name holds.

  A function card that tests reach wears `n tests` in its header, and its callers menu lists
  those tests after the callers, nearest first with the hops between; the badge opens the
  menu. A row opens the calls between its test and the function, each record a caller of
  the next. The answers are the LiveView's, held in a `GraspWeb.TestReach`, so a card reads them
  rather than walking the index as it renders.

  Coverage is read the same way, from a `GraspWeb.CardCoverage` the LiveView holds, each card
  handed only its own reading: a fresh
  reading marks the body's counted lines and the clauses and arms never entered, and a stale
  one puts `coverage stale` in the header and marks nothing. Both are drawn only while the
  reader has the coverage mode on, which is the page's CSS and not the card's markup.

  Test results are read the same way again, from a `GraspWeb.CardResults`: a test card wears
  its latest result — `passed`, `failed`, `skipped`, `invalid` or `stale` — and a function
  card's tests badge adds how many of its tests fresh results mark failed or invalid. A test card has `run`, and the
  callers menu's Tests section `run all`, each starting a run of those tests; while any run
  is under way both are disabled, titled with the command that is running.

  A test card whose fresh result failed draws each error under the line its own frame names
  (`Grasp.TestFailure.line/2`): the message, an assertion's expression and its `left` and
  `right` as the run printed them, and the stacktrace with each frame outside the index
  said to be. It is drawn from the result the card is handed, never stored as a thread, and
  goes when the result goes stale. A line the view does not draw puts the panel in a footer.
  When the first error's stacktrace holds an indexed frame above the test's own, the header
  has `open failure`, which lays those frames out as a chain of callees from the card.
  """

  use GraspWeb, :html

  import GraspWeb.CommentComponents

  alias Grasp.Comments
  alias Grasp.Comments.Anchor
  alias Grasp.Diff
  alias Grasp.Diff.Hunks
  alias Grasp.Index
  alias Grasp.Session.Forest
  alias GraspWeb.TestReach

  @stdlib_apps [:elixir, :logger, :eex, :ex_unit, :mix, :iex]
  @badge_labels %{
    "live_route" => "live route",
    "oban_worker" => "worker",
    "live_view" => "live view",
    "live_component" => "component",
    "genserver" => "GenServer"
  }
  # A test's compiled name is written quoted, and may hold any character but an unescaped
  # quote, so a dot or a slash inside the quotes belongs to the name.
  @function_id ~r/^([A-Z][\w.]*)\.("(?:[^"\\]|\\.)*"|[^.\/]+)\/(\d+)$/
  @erlang_function_id ~r/\A(:[a-z]\w*)\.[^.\/]+\/\d+\z/

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card_id, :integer, required: true
  attr :depth, :integer, required: true
  attr :open_calls, :map, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil
  attr :test_reach, TestReach, doc: "the tests reaching each card's function", default: nil

  attr :coverage, :any,
    doc: "this card's own reading, a `t:GraspWeb.CardCoverage.reading/0`",
    default: :none

  attr :result, :any,
    doc: "this card's own reading, a `t:GraspWeb.CardResults.reading/0`",
    default: :none

  attr :running, :string, doc: "the description of the run under way, if any", default: nil

  attr :failure, :map,
    doc: "this card's fresh failure, a `t:GraspWeb.CardResults.failure/0`",
    default: nil

  attr :selected, :boolean, default: false
  attr :comments, :map, doc: "every thread of the session, keyed by function id", default: %{}
  attr :composing, :map, doc: "the anchor a comment is being written at", default: nil
  attr :expanded_threads, :any, doc: "ids of the resolved threads shown in full", default: nil
  attr :expanded_folds, :any, doc: "`{card id, first line}` of every fold opened", default: nil

  # The node is the card's place on the stage and the card is what is drawn there, so a
  # re-render of the card's contents leaves the position alone and a drag moves the node
  # without touching anything LiveView owns inside it. A card nothing has placed yet renders
  # at the origin and hidden, waiting for the canvas to measure it and say where it goes.
  def card_node(assigns) do
    card = Forest.card(assigns.forest, assigns.card_id)
    {x, y} = card.position || {0, 0}

    # A record names its module, which a test's id could only be parsed for; a stub has no
    # record, and a function id with no module part stands for its own module, clustering
    # alone.
    module =
      case Index.fetch_function(assigns.index, card.function_id) do
        {:ok, %{"module" => module}} when is_binary(module) -> module
        _none -> cluster_module_of(card.function_id) || card.function_id
      end

    assigns = assign(assigns, card: card, x: x, y: y, module: module)

    ~H"""
    <div
      class="node"
      id={"node-#{@card.id}"}
      data-card={@card.id}
      data-depth={@depth}
      data-group={@card.group || ""}
      data-module={@module}
      data-unplaced={@card.position == nil}
      style={"--x: #{@x}px; --y: #{@y}px"}
    >
      <.card
        forest={@forest}
        index={@index}
        card={@card}
        open_calls={@open_calls}
        editor={@editor}
        callers_open={@callers_open}
        test_reach={@test_reach}
        coverage={@coverage}
        result={@result}
        failure={@failure}
        running={@running}
        selected={@selected}
        comments={@comments}
        composing={@composing}
        expanded_threads={@expanded_threads}
        expanded_folds={@expanded_folds}
      />
    </div>
    """
  end

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card, :map, required: true
  attr :open_calls, :map, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil
  attr :test_reach, TestReach, doc: "the tests reaching each card's function", default: nil

  attr :coverage, :any,
    doc: "this card's own reading, a `t:GraspWeb.CardCoverage.reading/0`",
    default: :none

  attr :result, :any,
    doc: "this card's own reading, a `t:GraspWeb.CardResults.reading/0`",
    default: :none

  attr :running, :string, doc: "the description of the run under way, if any", default: nil

  attr :failure, :map,
    doc: "this card's fresh failure, a `t:GraspWeb.CardResults.failure/0`",
    default: nil

  attr :selected, :boolean, default: false
  attr :comments, :map, doc: "every thread of the session, keyed by function id", default: %{}
  attr :composing, :map, doc: "the anchor a comment is being written at", default: nil
  attr :expanded_threads, :any, doc: "ids of the resolved threads shown in full", default: nil
  attr :expanded_folds, :any, doc: "`{card id, first line}` of every fold opened", default: nil

  def card(assigns) do
    case Index.fetch_function(assigns.index, assigns.card.function_id) do
      {:ok, record} -> function_card(assign(assigns, record: record))
      :error -> stub_card(assigns)
    end
  end

  attr :change, :string, default: nil

  @doc """
  The badge naming what a pull request did to a function: added, modified or removed.

  Renders nothing for a function the branch left alone, so a caller can hand it every
  record it lists without asking first.
  """
  def change_badge(assigns) do
    ~H"""
    <span
      :if={@change in ~w(added modified removed)}
      class="badge badge--change"
      data-change={@change}
    >
      {@change}
    </span>
    """
  end

  attr :kind, :string, default: nil

  @doc """
  The badge a test or a setup callback wears: `test` for a record of kind `"test"`, `setup`
  for one of kind `"setup"`.

  Renders nothing for any other kind, so a caller can hand it every record it lists.
  """
  def test_badge(assigns) do
    ~H"""
    <span :if={@kind in ~w(test setup)} class="badge badge--test" data-test-kind={@kind}>
      {@kind}
    </span>
    """
  end

  @typedoc """
  How a card's header names its record: `module` fills the slot module frames hide,
  `separator` sits between it and `name`, and `badge` is the test kind the header wears, if
  any.
  """
  @type title :: %{
          module: String.t() | nil,
          separator: String.t(),
          name: String.t(),
          badge: String.t() | nil
        }

  @doc """
  The parts a card's header names `record` by.

  A function is `Module.` and `name/arity`. A test is its name as written, under its
  `describe` when it has one and its module otherwise; a setup callback is `setup` or
  `setup_all`, as its compiled name says, under its module. Both carry the badge of their
  kind and no arity, since a test is a block, not a function anyone calls.
  """
  @spec title(map()) :: title()
  def title(%{"kind" => "test"} = record) do
    test = if is_map(record["test"]), do: record["test"], else: %{}

    %{
      module: test["describe"] || record["module"],
      separator: " › ",
      name: test["name"] || to_string(record["name"]),
      badge: "test"
    }
  end

  def title(%{"kind" => "setup"} = record) do
    name =
      if String.starts_with?(to_string(record["name"]), "__ex_unit_setup_all_"),
        do: "setup_all",
        else: "setup"

    %{module: record["module"], separator: " › ", name: name, badge: "setup"}
  end

  def title(record) do
    %{
      module: record["module"],
      separator: ".",
      name: "#{record["name"]}/#{record["arity"]}",
      badge: nil
    }
  end

  defp function_card(assigns) do
    %{forest: forest, index: index, card: card, record: record, comments: comments} = assigns

    external? = fn target -> match?(:error, Index.fetch_function(index, target)) end

    change = record["change"] || "unchanged"
    title = title(record)
    diffable? = Diff.diffable?(record)

    # A card holds its view across an index reload, so one opened on a diff can outlive the
    # diff itself — a rebase, or a base ref that moved. Nothing is left to show, and the
    # toggle that would switch back is gone with the diff, so the card reads as source
    # again rather than reporting a view it is not in.
    view = Forest.effective_view(card.view, diffable?)

    # Only the diff has unchanged stretches to fold; the source view is the whole function
    # by definition, and says so by carrying no context at all.
    context = view == :diff && Forest.effective_context(card.context, loc(record))

    # The reading is taken once per coverage document and index and held by the LiveView;
    # a stale one tints nothing, since its counts describe a body other than this one.
    coverage = assigns.coverage

    highlight_opts = [
      card_id: card.id,
      open_calls: assigns.open_calls,
      external?: external?,
      highlight: card.highlight,
      coverage: if(is_map(coverage), do: coverage)
    ]

    # A thread names a line, not a rendered one: the code under it moves, so where each one
    # belongs is decided against the record about to be drawn. Anything the anchor can no
    # longer find keeps its place in the footer instead of being dropped. A thread written
    # over a range keeps its length rather than its numbers: the anchor re-places its first
    # line and the rest is counted out from there, up to the record's own last line.
    {anchored, lost} =
      comments
      |> Map.get(record["id"], [])
      |> Enum.map(&{&1, Anchor.place(&1, record)})
      |> Enum.split_with(fn {_thread, placement} -> is_tuple(placement) end)

    anchored =
      Enum.map(anchored, fn {thread, {side, line}} ->
        span = Range.size(Comments.range(thread)) - 1
        last = last_line(record, side)
        %{thread: thread, side: side, range: line..min(line + span, last)//1}
      end)

    # Only an open thread tints its lines: a resolved one is a settled argument, and the card
    # says so by collapsing it rather than by colouring the code again.
    commented =
      for %{thread: thread, side: side, range: range} <- anchored,
          not thread.resolved,
          number <- range,
          into: MapSet.new(),
          do: {side, number}

    highlight_opts = Keyword.put(highlight_opts, :commented, commented)

    lines =
      if view == :diff,
        do: Grasp.Highlight.diff_lines(record, highlight_opts),
        else: Grasp.Highlight.lines(record, highlight_opts)

    # A placement the view does not draw would otherwise take the thread off the card
    # altogether — a comment on a deleted line is anchored on the base side, which the source
    # view has no line for — so it joins the footer until the view that draws it is back.
    # A thread hangs off the last line of its range the view actually draws, so the code it
    # is about reads before the conversation about it.
    drawn = MapSet.new(lines, &{&1.side, &1.line})

    anchored =
      Enum.map(anchored, fn placement ->
        at =
          placement.range
          |> Enum.reverse()
          |> Enum.find(&MapSet.member?(drawn, {placement.side, &1}))

        Map.put(placement, :at, at)
      end)

    {shown, hidden} = Enum.split_with(anchored, &(&1.at != nil))

    placed = Enum.group_by(shown, &{&1.side, &1.at}, & &1.thread)

    aside =
      lost
      |> Enum.map(fn {thread, _placement} -> {:outdated, thread} end)
      |> Enum.concat(Enum.map(hidden, &{:hidden, &1.thread}))
      |> Enum.sort_by(fn {_why, thread} -> thread.id end)

    # A failure is the result's, not a thread: its panels are taken with the result, and each
    # hangs under the line the test's own frame names, which a fold keeps open as a thread
    # keeps its range open.
    failure = if record["kind"] == "test", do: assigns.failure
    failures = if failure, do: failure.panels, else: []

    expanded_folds = assigns.expanded_folds || MapSet.new()
    card_id = card.id
    opened = for {^card_id, from} <- expanded_folds, into: MapSet.new(), do: from

    # Folding runs after the threads are placed, so a comment holds its lines open: the
    # placements are decided against every line the record has, and only then is what is
    # left of an unchanged stretch collapsed. A thread holds its whole range open, since a
    # range half folded away is a comment about code the reader cannot see.
    keep =
      for %{side: side, range: range} <- shown,
          number <- range,
          into: MapSet.new(),
          do: {side, number}

    keep = Enum.reduce(failures, keep, &MapSet.put(&2, {:new, &1.line}))

    lines =
      if context == :hunks do
        Hunks.fold(lines, keep: keep, expanded: opened)
      else
        lines
      end

    drawn_new = for %{side: :new, line: number} <- lines, into: MapSet.new(), do: number

    {failures_under, failures_aside} =
      Enum.split_with(failures, &MapSet.member?(drawn_new, &1.line))

    assigns =
      assign(assigns,
        failures_under: Enum.group_by(failures_under, & &1.line),
        failures_aside: failures_aside,
        chain?: failure != nil and failure.chain != [],
        focused?: forest.focus == card.id,
        coverage_stale?: coverage == :stale,
        lines: lines,
        placed: placed,
        aside: aside,
        expanded_threads: assigns.expanded_threads || MapSet.new(),
        change: change,
        diffable?: diffable?,
        stats: diffable? && Diff.stats(record["base_source"], record["source"]),
        callers: Index.callers(index, record["id"]),
        tests: tests_reaching(assigns.test_reach, card.function_id),
        result: result_worn(assigns.result),
        failing: failing(assigns.result),
        runnable?: record["kind"] == "test" and record["removed"] != true,
        entries: Index.entry_points_for(index, record["id"]),
        title: title,
        signature: signature(record),
        signature_html: !title.badge && Grasp.Highlight.signature(record),
        assertions: if(title.badge == "test", do: Grasp.Highlight.assertions(record), else: []),
        callees: Forest.callees(forest, card.id),
        hidden_count: Forest.hidden_count(forest, card.id),
        view: view,
        context: context,
        gutter: gutter_columns(record),
        # A removed function's file and line are the base commit's: the line may hold
        # something else on this branch, or the file may be gone, so there is nothing to
        # open and the card prints the location as plain text.
        editor_href:
          !record["removed"] &&
            editor_url(
              assigns.editor,
              index.project["root"],
              record["file"],
              record["span"]["start_line"]
            )
      )

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={[
        "card",
        @focused? && "card--focused",
        @selected && "card--selected",
        @record["removed"] && "card--removed",
        !@record["removed"] && @record["change"] == "added" && "card--added"
      ]}
      data-function-id={@record["id"]}
      data-focused={to_string(@focused?)}
      data-selected={to_string(@selected)}
      data-view={to_string(@view)}
      data-context={@context && to_string(@context)}
      data-highlight-key={highlight_key(@card.highlight)}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <.change_badge change={@change} />
        <span
          :for={entry <- @entries}
          class={["badge", "badge--#{entry["kind"]}"]}
          title={entry["target"]}
        >
          {badge_label(entry)}
        </span>
        <.test_badge kind={@title.badge} />
        <span :if={@result} class="badge badge--result" data-result={@result}>{@result}</span>
        <button
          :if={@tests != []}
          type="button"
          class="card__tests"
          phx-click="toggle_callers"
          phx-value-card={@card.id}
          aria-expanded={to_string(@callers_open == @card.id)}
          data-failing={@failing > 0 && to_string(@failing)}
          title="Tests reaching this function"
        >
          {count_label(length(@tests), "test")}{if @failing > 0, do: " · #{@failing} failing"}
        </button>
        <h2 class="card__title">
          <span class="card__module">{@title.module}{@title.separator}</span><span class="card__fn">{@title.name}</span>
          <span :if={!@title.badge} class="card__kind">{@record["kind"]}</span>
        </h2>
        <span :if={@stats} class="card__stats">+{@stats.added} −{@stats.removed}</span>
        <span
          :if={@coverage_stale?}
          class="card__coverage"
          title="These counts describe another version of this function"
        >
          coverage stale
        </span>
        <div class="card__tools">
          <a :if={@editor_href} class="card__file" href={@editor_href}>
            {@record["file"]}:{@record["span"]["start_line"]}
          </a>
          <span :if={!@editor_href} class="card__file">
            {@record["file"]}:{@record["span"]["start_line"]}
          </span>
          <div :if={@callers != [] or @tests != []} class="card__callers">
            <button
              :if={@callers != []}
              class="card__callers-toggle"
              phx-click="toggle_callers"
              phx-value-card={@card.id}
              aria-expanded={to_string(@callers_open == @card.id)}
            >
              callers ({length(@callers)})
            </button>
            <ul :if={@callers_open == @card.id}>
              <li :for={caller <- @callers}>
                <button
                  class="caller"
                  phx-click="open_caller"
                  phx-value-card={@card.id}
                  phx-value-caller={caller}
                >
                  {caller}
                </button>
              </li>
              <li :if={@tests != []} class="callers__heading">
                Tests
                <button
                  type="button"
                  class="callers__run"
                  phx-click="run_reaching"
                  phx-value-card={@card.id}
                  disabled={@running != nil}
                  title={GraspWeb.RunsPanel.running_title(@running, "Run every test listed")}
                >
                  run all
                </button>
              </li>
              <li :for={reach <- @tests}>
                <button
                  class="caller caller--test"
                  phx-click="open_test"
                  phx-value-card={@card.id}
                  phx-value-test={reach.test}
                >
                  <span class="caller__test">{test_row_title(@index, reach.test)}</span>
                  <span class="caller__hops">{hops_label(reach.hops)}</span>
                </button>
              </li>
            </ul>
          </div>
          <button
            :if={@chain?}
            type="button"
            id={"open-failure-#{@card.id}"}
            class="card__open-failure"
            phx-click="open_failure"
            phx-value-card={@card.id}
            title="Open the functions this test failed down, each as a callee of the one before"
          >
            open failure
          </button>
          <button
            :if={@runnable?}
            type="button"
            id={"run-#{@card.id}"}
            class="card__run"
            phx-click="run_test"
            phx-value-test={@record["id"]}
            disabled={@running != nil}
            title={GraspWeb.RunsPanel.running_title(@running, "Run this test")}
          >
            run
          </button>
          <button
            :if={@diffable?}
            id={"view-#{@card.id}"}
            class="card__view"
            phx-click="toggle_view"
            phx-value-card={@card.id}
            title="Show the diff against the base (d)"
          >
            {if @view == :source, do: "diff", else: "source"}
          </button>
          <button
            :if={@context}
            id={"context-#{@card.id}"}
            class="card__context"
            phx-click="toggle_context"
            phx-value-card={@card.id}
            title="Show every line or only the changes (z)"
          >
            {if @context == :hunks, do: "all lines", else: "changes only"}
          </button>
          <button
            :if={@callees != []}
            class="card__collapse"
            phx-click="toggle_collapse"
            phx-value-card={@card.id}
            title="Collapse what only this card reaches (c)"
          >
            {if @card.collapsed, do: "▸ #{@hidden_count}", else: "▾"}
          </button>
          <button
            class="card__close"
            phx-click="close_card"
            phx-value-card={@card.id}
            title="Close (x) · Shift+x closes the chain"
          >
            ×
          </button>
        </div>
      </header>
      <p :if={!@title.badge} class="card__signature lumis" title={@signature}>{@signature_html}</p>
      <%!-- A test's promise is its assertions, so those are what a far-out test card reads
      under its title; a test asserting nothing, and a setup, are the title alone. --%>
      <%!-- An assertion keeps the line breaks its source has, so each is preformatted. --%>
      <div
        :if={@assertions != []}
        class="card__signature card__assertions lumis"
        title={@signature}
      >
        <pre
          :for={{lines, html} <- @assertions}
          class="card__assertion"
          data-line={lines.first}
          data-end-line={lines.last}
        >{html}</pre>
      </div>
      <%!-- The lines are rendered one at a time so a thread can sit between two of them.
      Whitespace between the children here is ordinary white-space, which the body does not
      preserve — only the lines themselves are preformatted. --%>
      <div
        id={"body-#{@card.id}"}
        class="card__body lumis"
        style={"--gutter: #{@gutter}ch"}
        phx-hook="Gutter"
      >
        <%= for line <- @lines do %>
          <%= if line[:fold] do %>
            <button
              class="line line--fold"
              phx-click="expand_fold"
              phx-value-card={@card.id}
              phx-value-from={line.from}
            >
              ⋯ {line.count} unchanged lines
            </button>
          <% else %>
            {raw(line.html)}<.failure_panel
              :for={failure <- failures_at(@failures_under, line)}
              failure={failure}
            /><.thread
              :for={thread <- Map.get(@placed, {line.side, line.line}, [])}
              thread={thread}
              card_id={@card.id}
              expanded={MapSet.member?(@expanded_threads, thread.id)}
              composing={@composing}
            /><.composer
              :if={composing_at?(@composing, @card.id, line.side, line.line)}
              composing={@composing}
              card_id={@card.id}
            />
          <% end %>
        <% end %>
      </div>
      <footer :if={@failures_aside != []} class="card__failures">
        <.failure_panel :for={failure <- @failures_aside} failure={failure} />
      </footer>
      <footer :if={@aside != []} class="card__outdated">
        <.thread
          :for={{why, thread} <- @aside}
          thread={thread}
          card_id={@card.id}
          expanded={MapSet.member?(@expanded_threads, thread.id)}
          composing={@composing}
          aside={why}
        />
      </footer>
      <footer :if={@record["hidden_calls"] != []} class="card__also">
        <span class="card__also-label">Also calls</span>
        <button
          :for={call <- @record["hidden_calls"]}
          class="also"
          phx-click="open_call"
          phx-value-card={@card.id}
          phx-value-target={call["target"]}
          {edge_attrs(@open_calls, call["target"])}
        >
          {call["target"]}
        </button>
      </footer>
    </article>
    """
  end

  defp failures_at(under, %{side: :new, line: number}), do: Map.get(under, number, [])
  defp failures_at(_under, _line), do: []

  attr :failure, :map,
    required: true,
    doc: "one error, with the line it belongs under and its trace (`Grasp.TestFailure`)"

  # Everything an error holds is what the test run printed — the message, and the values an
  # assertion compared — so it is rendered as text, preformatted as the run printed it.
  defp failure_panel(assigns) do
    error = assigns.failure.error

    assigns =
      assign(assigns,
        kind: text_field(error, "kind"),
        message: text_field(error, "message"),
        expr: text_field(error, "expr"),
        left: text_field(error, "left"),
        right: text_field(error, "right"),
        trace: assigns.failure.trace
      )

    ~H"""
    <div class="failure" data-line={@failure.line} data-kind={@kind}>
      <pre :if={@message} class="failure__message">{@message}</pre>
      <pre :if={@expr} class="failure__expr">{@expr}</pre>
      <dl :if={@left || @right} class="failure__values">
        <div :if={@left} class="failure__value" data-side="left">
          <dt>left</dt>
          <dd><pre>{@left}</pre></dd>
        </div>
        <div :if={@right} class="failure__value" data-side="right">
          <dt>right</dt>
          <dd><pre>{@right}</pre></dd>
        </div>
      </dl>
      <ol :if={@trace != []} class="failure__trace">
        <li
          :for={frame <- @trace}
          class="failure__frame"
          data-indexed={to_string(frame.id != nil)}
          data-own={frame.own? && "true"}
          data-step={frame.step? && "true"}
        >
          <span class="failure__function">{frame.label}</span>
          <span :if={frame.file} class="failure__location">
            {frame.file}{if frame.line, do: ":#{frame.line}"}
          </span>
          <span :if={frame.closure?} class="failure__note">
            inside an anonymous function or comprehension
          </span>
          <span :if={frame.id == nil} class="failure__note">outside the index</span>
          <span :if={frame.step? and frame.via == nil and frame.skipped?} class="failure__note">
            reached through code outside the index
          </span>
          <span
            :if={frame.step? and frame.via == nil and not frame.skipped?}
            class="failure__note"
          >
            a call its caller's record does not hold
          </span>
        </li>
      </ol>
    </div>
    """
  end

  defp text_field(error, key) do
    case Map.get(error, key) do
      value when is_binary(value) and value != "" -> value
      _none -> nil
    end
  end

  # Where the composer for a new thread is drawn: under the last line of the range it covers,
  # so the code it is about reads before the box that talks about it. A reply is not placed
  # here: it belongs inside the thread it answers, which renders it itself.
  defp composing_at?(
         %{card: card, side: side, line: line, end_line: end_line, reply_to: nil, edit: nil},
         card_id,
         line_side,
         number
       )
       when card == card_id,
       do: to_string(line_side) == side and number == (end_line || line)

  defp composing_at?(_composing, _card_id, _side, _number), do: false

  # The last line the record has on a side, which is where a range re-placed lower down the
  # function stops: a comment is about code the function holds, so it never reaches past its
  # end. A side the record does not have anchors nothing, so any number will do for it.
  defp last_line(record, side) do
    case Anchor.lines(record, Atom.to_string(side)) do
      nil -> 0
      lines -> lines |> List.last() |> elem(0)
    end
  end

  # Columns the gutter reserves: enough for the highest number the body prints — the span's
  # last line, which is also the highest the diff view prints, since a deleted line prints
  # none — and one more for the `+` that appears beside it on hover.
  defp gutter_columns(record) do
    last = record["span"]["end_line"] || record["span"]["start_line"] || 1
    max(4, String.length(Integer.to_string(last)) + 1)
  end

  # How long the function is on the branch, which is what the default context is decided
  # against. A record carrying no source of its own — one the branch removed — is nothing to
  # fold. Counted as the body numbers its lines, so a template is not folded against a line
  # its card never draws.
  defp loc(record), do: record["source"] |> Grasp.Highlight.source_lines() |> length()

  # The footer button for a hidden call is marked exactly as the call spans in the body are,
  # so a call the graph has opened reads the same wherever the card shows it.
  defp edge_attrs(open_calls, target) do
    case Map.fetch(open_calls, target) do
      {:ok, %{to: to, color: color}} ->
        ["data-open": "true", "data-color": color, "data-edge-to": to]

      :error ->
        ["data-open": "false"]
    end
  end

  # The canvas reveals a card again when this key changes, so a highlight pushed onto the
  # card that already has focus is still panned to.
  defp highlight_key(%{"call" => target}), do: "call:#{target}"
  defp highlight_key(%{"lines" => [first, last]}), do: "lines:#{first}-#{last}"
  defp highlight_key(_highlight), do: nil

  # A callback entry is labelled with the function it is, which the card title already
  # says; the kind is the part the badge adds, spelled the way a reader would say it
  # rather than the way the index stores it. A route's path is the one thing neither the
  # title nor the body carries, so it is shown in full.
  defp badge_label(%{"kind" => "route", "label" => label}), do: label
  defp badge_label(%{"kind" => kind}), do: Map.get(@badge_labels, kind, kind)

  defp tests_reaching(nil, _function_id), do: []
  defp tests_reaching(reach, function_id), do: TestReach.for_function(reach, function_id)

  defp result_worn({:result, status}), do: status
  defp result_worn(_reading), do: nil

  defp failing({:failing, count}), do: count
  defp failing(_reading), do: 0

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  defp hops_label(1), do: "direct"
  defp hops_label(hops), do: "#{hops} hops"

  # A row names its test as the test's own card titles it, less the module: every row of the
  # menu is a test, and the describe is the part that tells two of them apart.
  defp test_row_title(index, test_id) do
    case Index.fetch_function(index, test_id) do
      {:ok, %{"kind" => "test"} = record} ->
        title = title(record)
        describe = is_map(record["test"]) && record["test"]["describe"]
        if describe, do: describe <> title.separator <> title.name, else: title.name

      {:ok, record} ->
        title(record).name

      :error ->
        test_id
    end
  end

  defp stub_card(assigns) do
    # The title is split the way a full card's is, so that the frame round the cluster can
    # carry the module name and the header read `fun/arity` alone. An id with no module part
    # has no part to drop.
    module = cluster_module_of(assigns.card.function_id)
    name = if module, do: String.replace_prefix(assigns.card.function_id, module <> ".", "")

    assigns =
      assign(assigns,
        focused?: assigns.forest.focus == assigns.card.id,
        docs: hexdocs_url(assigns.card.function_id),
        stale?: indexed_module?(assigns.index, assigns.card.function_id),
        module: module,
        name: name || assigns.card.function_id
      )

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={["card", "stub", @focused? && "card--focused", @selected && "card--selected"]}
      data-function-id={@card.function_id}
      data-focused={to_string(@focused?)}
      data-selected={to_string(@selected)}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <h2 class="card__title">
          <span :if={@module} class="card__module">{@module}.</span><span class="card__fn">{@name}</span>
        </h2>
        <div class="card__tools">
          <button class="card__close" phx-click="close_card" phx-value-card={@card.id}>×</button>
        </div>
      </header>
      <p class="card__signature lumis" title={@card.function_id}>{@card.function_id}</p>
      <p :if={@stale?} class="stub__text">
        No longer in the index — renamed or removed since it was written.
      </p>
      <p :if={!@stale?} class="stub__text">
        Not in the index (a dependency or the standard library).
      </p>
      <a :if={@docs} class="stub__docs" href={@docs} target="_blank" rel="noopener">Open on hexdocs</a>
    </article>
    """
  end

  @doc """
  The one line that heads a function as plain text: its definition, without the indentation
  it was written at and without a trailing `do`.

  The card renders the head highlighted, and carries this beside it as the title a pointer
  reads — an attribute holds text, not markup. A record with no definition line anywhere
  falls back to `Mod.fun/arity`, which is what a stub shows. A test or a setup callback has
  no head a reader would name it by, and reads as its card's title does.
  """
  @spec signature(map()) :: String.t()
  def signature(%{"kind" => kind} = record) when kind in ~w(test setup) do
    title = title(record)
    "#{title.module}#{title.separator}#{title.name}"
  end

  def signature(record) do
    case Grasp.Highlight.signature_line(record) do
      {_line, text} -> text
      nil -> record["id"] || ""
    end
  end

  @doc "Editor deep link for `file:line` under `root`, or nil when no editor is configured."
  @spec editor_url(String.t() | nil, String.t() | nil, String.t(), pos_integer()) ::
          String.t() | nil
  def editor_url(nil, _root, _file, _line), do: nil
  def editor_url(_editor, nil, _file, _line), do: nil

  def editor_url(editor, root, file, line) do
    path = Path.join(root, file)

    case editor do
      "vscode" -> "vscode://file/#{encode_path(path)}:#{line}"
      "cursor" -> "cursor://file/#{encode_path(path)}:#{line}"
      "zed" -> "zed://file/#{encode_path(path)}:#{line}"
      "idea" -> "idea://open?file=#{URI.encode_www_form(path)}&line=#{line}"
      _ -> nil
    end
  end

  # A space or an ampersand in a project path would otherwise truncate the link the browser
  # hands the editor; the separators have to survive, so each segment is encoded on its own.
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  @doc "hexdocs URL for a standard-library function id, or nil for anything else."
  @spec hexdocs_url(term()) :: String.t() | nil
  def hexdocs_url(function_id) when not is_binary(function_id), do: nil

  def hexdocs_url(function_id) do
    with [_, module, name, arity] <- Regex.run(@function_id, function_id),
         {:ok, mod} <- existing_module(module),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         {:ok, app} when app in @stdlib_apps <- :application.get_application(mod) do
      "https://hexdocs.pm/#{app}/#{module}.html##{name}/#{arity}"
    else
      _ -> nil
    end
  end

  # A card opened before the index was rewritten may show a function the project no longer
  # defines; its module still being indexed is what separates that from a dependency.
  defp indexed_module?(%Index{} = index, function_id) do
    case module_of(function_id) do
      nil -> false
      module -> Enum.any?(Index.modules(index), &(&1["name"] == module))
    end
  end

  defp module_of(function_id) when is_binary(function_id) do
    case Regex.run(@function_id, function_id) do
      [_, module, _name, _arity] -> module
      nil -> nil
    end
  end

  defp module_of(_function_id), do: nil

  # Clustering reads the module part of every id a card can hold, where `module_of/1` reads
  # only the Elixir aliases hexdocs and the index are keyed by: `:erlang.split_binary/2`
  # clusters under `:erlang`, the text before its `name/arity`, like any other card.
  defp cluster_module_of(function_id) when is_binary(function_id) do
    case Regex.run(@erlang_function_id, function_id) do
      [_, module] -> module
      nil -> module_of(function_id)
    end
  end

  defp cluster_module_of(_function_id), do: nil

  # Call targets come from the index and from the browser, so concatenating them into a
  # module atom would let anyone grow the atom table one unknown name at a time.
  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end
end
