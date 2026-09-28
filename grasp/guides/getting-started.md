# Getting started

Installing Grasp in a Phoenix project, building the first index, and finding your way
around the canvas.

## Install

Grasp mounts inside the application it reviews, the way LiveDashboard does. Add it to that
project's `mix.exs`:

```elixir
{:grasp, git: "https://github.com/gfrancischelli/grasp.git", sparse: "grasp", only: :dev}
```

A Hex release will follow; until then the dependency is fetched from git, and `sparse`
points Mix at the `grasp/` directory inside the repository.

Run `mix deps.get`, then mount the page in the router:

```elixir
if Code.ensure_loaded?(Grasp.Router), do: Grasp.Router.mount(__ENV__, "/grasp")
```

The guard matters: Grasp is a `:dev` dependency, and the compiler expands an `import` or a
macro even inside an `if` it never takes, so a router that wrote `import Grasp.Router` would
fail to compile in `:test` and `:prod`. `mount/3` writes the routes as `grasp "/grasp"`
inside a `:browser` scope would (pass `pipeline:` to name another pipeline); a project that
ships Grasp in every environment may write the macro directly instead.

and add the plug to the endpoint, beside the code reloader:

```elixir
if code_reloading? do
  plug Grasp.Plug, at: "/grasp"
end
```

The plug does two things under that one prefix. It checks that every request for Grasp came
from loopback — binding the dev server to `127.0.0.1` does not stop a page whose DNS rebinds
to it, and Grasp hands out your source and drives an agent that edits files — and it serves
the MCP endpoint at `/grasp/mcp`, in front of the router, because a browser pipeline declares
`plug :accepts, ["html"]` and an MCP client asks for `application/json, text/event-stream`.

The plug's `at:` and the router's path must name the same mount, or the guard covers less
than the page. `"/grasp"` is the default on both sides; change one and change the other.
The plug's `at:` is the full path, enclosing scopes included: `scope "/tools" do grasp
"/grasp" end` pairs with `at: "/tools/grasp"`.

Grasp's LiveView connects over the host endpoint's live socket. If that socket is declared
somewhere other than `/live`, say so at the mount:

```elixir
grasp "/grasp", live_socket_path: "/socket/live"
```

If you write the `grasp "/grasp"` macro directly (a project that ships Grasp in every
environment), add the formatter export so it formats without parentheses:

```elixir
# .formatter.exs
import_deps: [:grasp]
```

A dev-only install must leave it out: `import_deps` is resolved for the current Mix
environment, so naming a dependency that exists only in `:dev` makes `mix format` fail under
`MIX_ENV=test`.

And ignore the files Grasp derives from your code:

```gitignore
.grasp/index.json
.grasp/worktrees/
```

Everything Grasp reads from configuration is optional and belongs in `config/dev.exs`:

```elixir
config :grasp,
  index_path: ".grasp/index.json",
  editor: "vscode",
  agent_command: "claude",
  agent_model: nil
```

`editor` is one of `vscode`, `cursor`, `zed` or `idea`, and turns every card's `file:line`
into a link that opens your editor there.

## The first index

```
mix grasp.index --base main
mix phx.server
```

`mix grasp.index` writes `.grasp/index.json`: every function in the project, what it calls,
what calls it, and where the entry points are. `--base main` also classifies each function
against the merge base with `main`, which is what turns the canvas into a pull-request
review. It is a full compile, so the first run takes a while; after that the index follows
your saves on its own. See [Indexing](indexing.md).

Open <http://localhost:4000/grasp>. A project that has never been indexed opens on a page
saying so and naming the task; the canvas fills in as soon as the file is written.

## The first screen

An empty canvas, and a sidebar down the left. The canvas says "Pick a function from the
sidebar or press ⌘K".

The sidebar's groups, from the top:

- **Comments** — every unresolved review thread in the project, under the module it was
  written on. Clicking one draws the card and lights up the line. Present only when a
  thread is open.
- **Changes** — every function the branch added, modified or removed, under its module,
  with a badge saying which. Present only in a review against a base ref, and open on
  arrival.
- **Entry points** — where the system starts executing, grouped by kind: Phoenix routes
  and LiveView routes (headed by their router, labelled `VERB /path`), Oban workers,
  LiveView and LiveComponent callbacks, GenServer, supervisor, application and plug
  callbacks.
- **Tests** — the test modules by file, each opening into its setup callbacks, its tests
  under their `describe` headings and its helpers. Present when the index holds tests.
- **Modules** — the whole module list, as the last group.

Above the groups is the session menu, which names the canvas you are reading and lists the
others. See [Reviewing](reviewing.md).

## Opening cards

Click any row in the sidebar to open that function as a card. Inside a card, every call is
a link: click it and the callee opens to the right, joined by an edge that takes the call
site's colour. The card's callers menu opens the chain the other way, to the left.

The canvas holds one card per function. A helper three functions call is drawn once, with
an edge arriving from each of them.

## The palette

⌘K or `/` opens the function palette. Type any part of a name: an exact `Module.fun/arity`
ranks first, then ids containing what you typed, then a fuzzy match. Arrow keys move, Enter
opens the card. In a review against a base ref each result carries its change badge, so a search
says which hits are part of the branch.

## The toolbar

The toolbar sits at the bottom centre of the canvas. Every control there names itself and
its shortcut when you hover or tab to it.

- **sidebar** (⌘M, or ⌘\ where the browser takes ⌘M for "minimise window") — show or hide
  the sidebar.
- **− / percentage / +** (⌘0 resets) — zoom. ⌘ or Ctrl with the wheel zooms about the
  cursor; the wheel alone pans, except over something that can scroll itself. Some browsers
  also take ⌘0 for their own page zoom and reset both.
- **fit** (`f`) — bring every card on the canvas into view at once.
- **signatures** (`s`) — turn the cards down to their signatures.
- **coverage** (`v`) — tint the lines the test suite ran and never ran, once
  `mix grasp.cover` has written them. See [Coverage](coverage.md).
- **modules** (`m`) — frame the cards of each module inside their flow, under the module's
  name. See [Reviewing](reviewing.md).
- **reset layout** — lay every card out again.
- **ask** (⌘I) — open the chat panel. See [The agent](agent.md).
- **?** (`?`) — the list of every key and gesture the canvas answers.

Keys that act on the focused card: the arrow keys or `h` `j` `k` `l` walk the graph, `x`
closes it, `Shift+x` closes it with everything that had no other way to be reached, `c`
collapses it, `d` swaps source for diff, `z` folds the unchanged lines away. ⌘G frames the
selected cards and ⇧⌘G takes them back out. Escape lets a selection go.

## Next

- [Reviewing](reviewing.md) — the canvas, cards, edges, comments and sessions.
- [Pull requests](pull-requests.md) — reviewing a branch or someone else's PR.
- [The agent](agent.md) — the chat panel and the MCP tools.
- [Indexing](indexing.md) — what the index holds and what it misses.
- [Coverage](coverage.md) — what the test suite ran, written by `mix grasp.cover`.
