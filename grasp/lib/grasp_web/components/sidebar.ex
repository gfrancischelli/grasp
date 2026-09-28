defmodule GraspWeb.Sidebar do
  @moduledoc """
  The sidebar's navigation: the project's entry points grouped by kind, with the module
  list as the last group.

  A review starts at the edge of the system — a request, a job, a mounted view — not at an
  alphabetical list of modules, so the groups are ordered from the outside in. A kind with
  nothing in it is not rendered at all, which is what makes the same sidebar readable in a
  library (no routes, no jobs) and in a web app; a kind the viewer has no group for still
  lands in "Other", so an entry the indexer learns to find is never invisible here.

  Entries name the function they are, so repeating the module on every row would bury the
  part that differs in a sidebar too narrow to hold it; each group therefore prints a
  heading once and lists what is under it by name and arity alone, with the full id on the
  row's `title`. Routes are headed by their router — a forwarded router is a section of the
  URL space, and its rows keep their `VERB /path` label, ordered by path.

  After the entry points comes the Tests group, present when the index holds test records:
  one row per test module in file order, opening into its setup callbacks and then its tests
  under their `describe` names, each test named as it is written, and last the helpers it
  defines. A test drives the system from outside as an entry point does, and clicking one
  opens its card as a root of its own. Every module `Grasp.Index.tests/1` lists — a test
  module, or a support module written under the project's test paths — is listed there and
  not in the module list, which is the code under review. The group keeps its own open
  module, apart from the module list's.

  A review against a base ref leads with what the branch did: a Changes group above the
  entry points, listing every added, modified and removed function under its module with
  the badge naming which it is. It is the table of contents of a pull request, so it opens
  on arrival whenever there is one, and is absent from a review with nothing to show — no
  base ref, or a branch that changed nothing.

  Under each changed application function the Changes group lists, indented, the changed
  tests that reach it, so code and tests changed together read as pairs; a changed function
  no test reaches is marked `untested` instead, and the Untested changes group after it lists
  those functions under their modules, opening on arrival whenever there is one. Both
  answers are read from the index, which walks back from the changes once when it is built.

  Above even that is the Comments group, the unresolved review threads of the session being
  read, under the modules they were written on. A thread is a question waiting on someone, so it
  leads; the row carries the function, the line and the opening words of the body, and
  clicking it draws the card and lights the line up. A thread on a function the index no
  longer holds has nothing to draw, so it is listed muted and clicking it does nothing.

  Above the groups is the session menu: the name of the session being read, and under it
  every session the viewer is running or has saved. A row navigates to that canvas, the ×
  beside it forgets the session and its file, and the field under the list opens a session
  by name, whether or not one of that name exists. The session being read carries no ×,
  since deleting it would take away the canvas the click was made on.

  Which group opens on arrival is decided by `default_expanded/2`, at mount and again
  whenever the index reloads: the comments whenever any thread is open, the changes whenever
  there are any, the routes when there are few enough to read as a list, the module list
  when there are no entry points at all. Every group's body is rendered
  either way and hidden when collapsed, so the `aria-controls` on its title always names an
  element.
  """

  use GraspWeb, :html

  import GraspWeb.CardComponents, only: [change_badge: 1, test_badge: 1, title: 1]

  alias Grasp.Index

  # The id of a function the index does not hold, which only its text can be read for. A
  # test's compiled name is written quoted and may hold a dot or a slash.
  @function_id ~r/^([A-Z][\w.]*)\.((?:"(?:[^"\\]|\\.)*"|[^.\/]+)\/\d+)$/

  # Ordered from the outside in: what calls into the system, then what the runtime calls,
  # then the plumbing. Each entry is {data-kind, title, kinds it collects}.
  @groups [
    {"routes", "Routes", ["route", "live_route"]},
    {"oban", "Background jobs", ["oban_worker"]},
    {"live", "Live views", ["live_view", "live_component"]},
    {"genservers", "Processes", ["genserver"]},
    {"otp", "Supervision", ["supervisor", "application"]},
    {"plugs", "Plugs", ["plug"]}
  ]

  @known_kinds Enum.flat_map(@groups, fn {_kind, _title, kinds} -> kinds end)
  @group_kinds ["comments", "changes", "untested"] ++
                 Enum.map(@groups, fn {kind, _title, _kinds} -> kind end) ++
                 ~w(other tests modules)

  # Past this many routes the list is a wall rather than a table of contents, and the
  # reader is better served by the search palette.
  @routes_open_max 50

  @doc "Every group the sidebar can render, as the `data-kind` its title toggles."
  @spec group_kinds() :: [String.t()]
  def group_kinds, do: @group_kinds

  @doc "The groups a review of `index` with no open comment threads opens with."
  @spec default_expanded(Index.t() | nil) :: MapSet.t(String.t())
  def default_expanded(index), do: default_expanded(index, 0)

  @doc """
  The groups a review of `index` opens with, `open_threads` being how many review threads
  are unresolved.

  An open thread is someone waiting on an answer, so the comments open while any is left.
  What the branch changed is why a reviewer is here at all, so it opens whenever there is
  any, and so do the changes no test reaches. The routes are the table of contents of a web app, so they open while they still
  read as one; a project with no entry points at all is a library, where the module list is
  the only way in.
  """
  @spec default_expanded(Index.t() | nil, non_neg_integer()) :: MapSet.t(String.t())
  def default_expanded(nil, _open_threads), do: MapSet.new()

  def default_expanded(%Index{} = index, open_threads) do
    groups = groups(index)
    routes = Enum.find(groups, &(&1.kind == "routes"))

    entries =
      cond do
        routes && routes.count <= @routes_open_max -> MapSet.new(["routes"])
        groups == [] -> MapSet.new(["modules"])
        true -> MapSet.new()
      end

    entries =
      case Index.changed_functions(index) do
        [] -> entries
        _changes -> MapSet.put(entries, "changes")
      end

    entries =
      case Index.untested_changes(index) do
        [] -> entries
        _untested -> MapSet.put(entries, "untested")
      end

    if open_threads > 0, do: MapSet.put(entries, "comments"), else: entries
  end

  @doc """
  The review page's path for `name` under the mount prefix `prefix`.

  The default session is the canvas at the mount path itself; a prefix of `""` is Grasp
  mounted at the root, whose canvas is `/`.
  """
  @spec session_path(String.t(), String.t()) :: String.t()
  def session_path("", "default"), do: "/"
  def session_path(prefix, "default"), do: prefix
  def session_path(prefix, name), do: "#{prefix}/s/#{name}"

  attr :prefix, :string, required: true
  attr :name, :string, required: true
  attr :sessions, :list, required: true
  attr :open?, :boolean, required: true
  attr :new_name, :string, default: ""

  def session_menu(assigns) do
    ~H"""
    <div class="session-bar">
      <button
        type="button"
        id="session-menu"
        class="session"
        phx-click="toggle_session_menu"
        aria-haspopup="true"
        aria-expanded={to_string(@open?)}
        aria-controls="session-list"
      >
        <span class="session__name">{@name}</span>
        <span class="session__chevron" aria-hidden="true">▾</span>
      </button>
      <%!-- The menu is rendered only while it is open, so the window listener it carries is
      bound only then and Escape reaches nothing else. --%>
      <div
        :if={@open?}
        id="session-list"
        class="session__menu"
        phx-window-keydown="close_session_menu"
        phx-key="Escape"
      >
        <ul class="session__list">
          <li :for={session <- @sessions} class="session__row">
            <.link
              navigate={session_path(@prefix, session)}
              class="session__link"
              aria-current={session == @name && "true"}
            >
              {session}
            </.link>
            <%!-- The session being read has no ×: leaving it would delete the canvas out from
            under the reader who clicked it. --%>
            <button
              :if={session != @name}
              type="button"
              class="session__delete"
              phx-click="delete_session"
              phx-value-name={session}
              data-confirm={"Delete session #{session}? Its cards are forgotten."}
              aria-label={"Delete session #{session}"}
            >
              ×
            </button>
          </li>
        </ul>
        <form class="session__new" phx-submit="new_session">
          <input
            type="text"
            name="name"
            value={@new_name}
            placeholder="new session"
            autocomplete="off"
            aria-label="New session"
          />
        </form>
      </div>
    </div>
    """
  end

  attr :index, Index, required: true
  attr :comments, :map, required: true
  attr :expanded, MapSet, required: true
  attr :expanded_module, :string, default: nil
  attr :expanded_test_module, :string, default: nil

  def entry_groups(assigns) do
    index = assigns.index
    changes = Index.changed_functions(index)
    untested = Index.untested_changes(index)
    threads = open_threads(assigns.comments)
    tests = Index.tests(index)
    suite = MapSet.new(tests, & &1.module)

    assigns =
      assign(assigns,
        groups: groups(index),
        # A module of the test suite is listed with its tests, not beside the code it tests.
        modules: Enum.reject(Index.modules(index), &(&1["name"] in suite)),
        tests: tests,
        test_count:
          tests |> Enum.flat_map(& &1.describes) |> Enum.map(&length(elem(&1, 1))) |> Enum.sum(),
        changes: changes_by_module(changes),
        change_count: length(changes),
        untested: changes_by_module(untested),
        untested_ids: MapSet.new(untested, & &1["id"]),
        untested_count: length(untested),
        threads: rows_by_module(threads, assigns.index),
        thread_count: length(threads)
      )

    ~H"""
    <nav id="entries" class="entries">
      <section :if={@thread_count > 0} class="group" data-kind="comments">
        <.group_title
          kind="comments"
          title="Comments"
          count={@thread_count}
          open?={open?(@expanded, "comments")}
        />
        <div
          id="group-comments"
          class="group__body"
          hidden={not open?(@expanded, "comments")}
        >
          <div :for={{module, rows} <- @threads} class="group__module">
            <h2 :if={module} class="group__heading">{module}</h2>
            <button
              :for={row <- rows}
              class={["entry", "entry--comment", row.orphan? && "entry--orphan"]}
              phx-click="open_comment"
              phx-value-id={row.id}
              title={row.function_id}
            >
              <span class="entry__where">{row.name} · {row.lines}</span>
              <span class="entry__excerpt">{row.excerpt}</span>
            </button>
          </div>
        </div>
      </section>
      <section :if={@changes != []} class="group" data-kind="changes">
        <.group_title
          kind="changes"
          title="Changes"
          count={@change_count}
          open?={open?(@expanded, "changes")}
        />
        <div
          id="group-changes"
          class="group__body"
          hidden={not open?(@expanded, "changes")}
        >
          <div :for={{module, records} <- @changes} class="group__module">
            <h2 class="group__heading">{module}</h2>
            <%= for record <- records do %>
              <button
                class={
                  if MapSet.member?(@untested_ids, record["id"]),
                    do: "entry entry--untested",
                    else: "entry"
                }
                phx-click="open_root"
                phx-value-id={record["id"]}
                title={record["id"]}
              >
                <.change_badge change={record["change"]} /><.test_badge kind={record["kind"]} />{title(
                  record
                ).name}<span
                  :if={MapSet.member?(@untested_ids, record["id"])}
                  class="badge badge--untested"
                  data-untested
                >untested</span>
              </button>
              <button
                :for={test <- Index.changed_tests(@index, record["id"])}
                class="entry entry--paired"
                phx-click="open_root"
                phx-value-id={test["id"]}
                title={test["id"]}
              >
                <.change_badge change={test["change"]} /><.test_badge kind="test" />{full_title(test)}
              </button>
            <% end %>
          </div>
        </div>
      </section>
      <section :if={@untested != []} class="group" data-kind="untested">
        <.group_title
          kind="untested"
          title="Untested changes"
          count={@untested_count}
          open?={open?(@expanded, "untested")}
        />
        <div
          id="group-untested"
          class="group__body"
          hidden={not open?(@expanded, "untested")}
        >
          <div :for={{module, records} <- @untested} class="group__module">
            <h2 class="group__heading">{module}</h2>
            <button
              :for={record <- records}
              class="entry"
              phx-click="open_root"
              phx-value-id={record["id"]}
              title={record["id"]}
            >
              <.change_badge change={record["change"]} />{title(record).name}
            </button>
          </div>
        </div>
      </section>
      <section :for={group <- @groups} class="group" data-kind={group.kind}>
        <.group_title
          kind={group.kind}
          title={group.title}
          count={group.count}
          open?={open?(@expanded, group.kind)}
        />
        <div
          id={"group-#{group.kind}"}
          class="group__body"
          hidden={not open?(@expanded, group.kind)}
        >
          <div :for={{module, entries} <- group.modules} class="group__module">
            <h2 :if={module} class="group__heading">{module}</h2>
            <button
              :for={entry <- entries}
              class="entry"
              phx-click="open_root"
              phx-value-id={entry["target"]}
              title={row_title(module, entry)}
            >
              {row_label(module, entry)}
            </button>
          </div>
        </div>
      </section>
      <section :if={@tests != []} class="group" data-kind="tests">
        <.group_title
          kind="tests"
          title="Tests"
          count={@test_count}
          open?={open?(@expanded, "tests")}
        />
        <div id="group-tests" class="group__body" hidden={not open?(@expanded, "tests")}>
          <nav id="tests">
            <div :for={test_module <- @tests} class="module-group">
              <button
                class={[
                  "module",
                  @expanded_test_module == test_module.module && "module--open"
                ]}
                phx-click="expand_module"
                phx-value-module={test_module.module}
                phx-value-group="tests"
                title={test_module.file}
              >
                {test_module.module}
              </button>
              <div :if={@expanded_test_module == test_module.module} class="tests">
                <ul :if={test_module.setups != []} class="fns">
                  <li :for={setup <- test_module.setups}>
                    <.test_row record={setup} />
                  </li>
                </ul>
                <div :for={{describe, tests} <- test_module.describes} class="tests__describe">
                  <h3 :if={describe} class="tests__heading">{describe}</h3>
                  <ul class="fns">
                    <li :for={test <- tests}>
                      <.test_row record={test} />
                    </li>
                  </ul>
                </div>
                <ul :if={test_module.helpers != []} class="fns tests__helpers">
                  <li :for={helper <- test_module.helpers}>
                    <.test_row record={helper} />
                  </li>
                </ul>
              </div>
            </div>
          </nav>
        </div>
      </section>
      <section class="group" data-kind="modules">
        <.group_title
          kind="modules"
          title="Modules"
          count={length(@modules)}
          open?={open?(@expanded, "modules")}
        />
        <div id="group-modules" class="group__body" hidden={not open?(@expanded, "modules")}>
          <nav id="modules">
            <div :for={module <- @modules} class="module-group">
              <button
                class={["module", @expanded_module == module["name"] && "module--open"]}
                phx-click="expand_module"
                phx-value-module={module["name"]}
              >
                {module["name"]}
              </button>
              <ul :if={@expanded_module == module["name"]} class="fns">
                <li :for={fun <- Index.functions_in_module(@index, module["name"])}>
                  <button
                    class={["fn", "fn--#{fun["kind"]}"]}
                    phx-click="open_root"
                    phx-value-id={fun["id"]}
                  >
                    {fun["name"]}/{fun["arity"]}
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </div>
      </section>
    </nav>
    """
  end

  attr :record, :map, required: true

  # A row of the Tests group sits under its module and its describe, so a test reads as its
  # name alone and a helper as its name and arity; a setup row is the only one that says what
  # kind it is.
  defp test_row(assigns) do
    ~H"""
    <button
      class={["fn", "fn--#{@record["kind"]}"]}
      phx-click="open_root"
      phx-value-id={@record["id"]}
      title={@record["id"]}
    >
      <.change_badge change={@record["change"]} />
      <.test_badge :if={@record["kind"] == "setup"} kind="setup" />{title(@record).name}
    </button>
    """
  end

  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :open?, :boolean, required: true

  defp group_title(assigns) do
    ~H"""
    <button
      class="group__title"
      phx-click="toggle_group"
      phx-value-group={@kind}
      data-open={to_string(@open?)}
      aria-expanded={to_string(@open?)}
      aria-controls={"group-#{@kind}"}
    >
      {@title}<span class="group__count">{@count}</span>
    </button>
    """
  end

  defp open?(expanded, kind), do: MapSet.member?(expanded, kind)

  defp groups(%Index{} = index) do
    by_kind = Enum.group_by(Index.entry_points(index), & &1["kind"])
    other = {"other", "Other", by_kind |> Map.keys() |> Kernel.--(@known_kinds) |> Enum.sort()}

    for {kind, title, kinds} <- @groups ++ [other],
        entries = Enum.flat_map(kinds, &Map.get(by_kind, &1, [])),
        entries != [] do
      %{
        kind: kind,
        title: title,
        count: length(entries),
        modules: by_module(kind, entries)
      }
    end
  end

  # Every thread the session holds, of every function, least recent first: the sidebar lists
  # what is still open across the review rather than what one card happens to show.
  defp open_threads(comments) do
    comments
    |> Enum.flat_map(fn {_function_id, threads} -> threads end)
    |> Enum.reject(& &1.resolved)
    |> Enum.sort_by(& &1.id)
  end

  # Grouping preserves the order the threads arrive in, so only the headings need sorting.
  defp rows_by_module(threads, index) do
    threads
    |> Enum.map(fn thread ->
      # A thread on an indexed function is named by its record, which a test's id cannot
      # be parsed for; one on a function the index lost has only its id to go on.
      {module, name} =
        case Index.fetch_function(index, thread.function_id) do
          {:ok, record} -> {record["module"], title(record).name}
          :error -> {module_of(thread.function_id), name_of(thread.function_id)}
        end

      %{
        id: thread.id,
        function_id: thread.function_id,
        module: module,
        name: name,
        lines: lines_label(thread),
        excerpt: excerpt(thread.body),
        orphan?: not indexed?(index, thread.function_id)
      }
    end)
    |> Enum.group_by(& &1.module)
    |> Enum.sort_by(fn {module, _rows} -> module end)
  end

  # A row names the lines the thread was written on, one or a range of them, so the sidebar
  # reads the same way the thread does on its card.
  defp lines_label(%{end_line: nil} = thread), do: "L#{thread.line}"
  defp lines_label(thread), do: "L#{thread.line}–L#{thread.end_line}"

  defp indexed?(%Index{} = index, function_id),
    do: match?({:ok, _record}, Index.fetch_function(index, function_id))

  # A row is one line of a sidebar narrow enough to cut a sentence short anyway, and the
  # opening words are what tells one thread from another; the body is read on the card.
  defp excerpt(body) do
    case String.split_at(body, 60) do
      {head, ""} -> head
      {head, _rest} -> head <> "…"
    end
  end

  # A paired test sits under the function it reaches rather than under its own module, so it
  # is named as its card names it, module or describe included.
  defp full_title(record) do
    %{module: module, separator: separator, name: name} = title(record)
    "#{module}#{separator}#{name}"
  end

  # Changed functions arrive sorted by id, which orders each module's rows the way the
  # module list orders them; grouping preserves that, so only the headings need sorting.
  defp changes_by_module(records) do
    records |> Enum.group_by(& &1["module"]) |> Enum.sort_by(fn {module, _records} -> module end)
  end

  # A route is not a callback on a module: what it belongs to is the router that declared
  # it, and a path reads as a list only in path order.
  defp by_module("routes", entries) do
    entries
    |> Enum.group_by(&meta(&1, "router"))
    |> Enum.sort_by(fn {router, _entries} -> router end)
    |> Enum.map(fn {router, routes} ->
      {router, Enum.sort_by(routes, &{meta(&1, "path"), meta(&1, "verb")})}
    end)
  end

  defp by_module(_kind, entries) do
    entries
    |> Enum.group_by(&module_of(&1["target"]))
    |> Enum.sort_by(fn {module, _entries} -> module end)
  end

  defp meta(entry, key), do: Map.get(entry["meta"] || %{}, key)

  # A row under a heading has already been told its module, and the id is too long for the
  # sidebar's width; the name and arity are what the reader is scanning for, and the id
  # stays on the row as its title.
  defp row_label(nil, entry), do: entry["label"]

  defp row_label(module, entry) do
    case entry["label"] do
      <<^module::binary, ".", rest::binary>> -> rest
      label -> label
    end
  end

  defp row_title(_module, entry), do: entry["target"]

  defp module_of(target) when is_binary(target) do
    case Regex.run(@function_id, target) do
      [_match, module, _name] -> module
      nil -> nil
    end
  end

  defp module_of(_target), do: nil

  # A row under a module heading says only what differs from its neighbours, and an id the
  # regex cannot read is printed whole rather than dropped.
  defp name_of(function_id) do
    case Regex.run(@function_id, function_id) do
      [_match, _module, name] -> name
      nil -> function_id
    end
  end
end
