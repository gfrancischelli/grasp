# Grasp

Call-chain code review for Elixir. Grasp draws each function as a card on a canvas: click a
call inside a card and the callee opens beside it, joined by an edge, so a call chain reads
left to right instead of as a series of editor jumps. Indexed against a base branch the same
canvas reviews a pull request, takes review comments on any line or range of lines, and can
be driven by a coding agent over MCP.

## Why

Agents now write more code than humans can comfortably review with a text editor and a
unified diff. A unified diff shows which lines moved; it does not show what calls the changed
function, or what the changed function now calls, and an editor answers that one jump at a
time. Grasp lays the chain out instead: one card per function, one edge per call, the whole
path from the route to the write on a canvas you can arrange, annotate and come back to.

## Features

- **The canvas.** A function is a card; clicking a call opens the callee beside it, joined by
  an edge that takes the call site's colour. One card per function, however many callers it
  has. Cards stay where you put them, and group into named frames.
- **Entry points.** The sidebar lists where the system starts executing — Phoenix and
  LiveView routes, Oban workers, LiveView, GenServer, supervisor, application and plug
  callbacks — so a review starts where the system starts.
- **Templates.** A `.heex` file is a card too, and a component tag inside it is a call
  site, and so is a call written in `{…}` or `<%= … %>`.
- **Routes and jobs are edges.** A link, a form action, an `hx-*` attribute or a `~p` sigil
  resolves against the router, so a card joins the controller action or LiveView behind that
  path by a dashed edge; queueing an Oban job joins the worker that runs it the same way,
  the call reading the queue it goes on.
- **Tests.** Every ExUnit test and setup is a card, traced in the test environment without a
  test run: a request a test makes joins the action it reaches, signature mode reads a test's
  assertions, and the sidebar lists the tests by module and `describe`.
- **Pull-request mode.** Index against a base ref and changed functions lead the sidebar, a
  modified card swaps between its source and its diff, and removed functions open from the
  base.
- **Review comments.** Click a line number to leave a thread, or drag along the numbers to
  cover a range; reply, resolve, and publish the lot to GitHub as review comments.
- **An agent that drives it.** An MCP server with 25 tools: search the index, trace the paths
  into a function, lay the cards out, read and answer the comments. A chat panel over the
  canvas runs that agent for you: rendered answers whose function ids open the card, folded
  tool calls, a queue for the next question, and a Retry when a run fails.
- **Live reindexing.** After the first build, the index follows your saves.
- **Editor links.** Every card links its `file:line` into VS Code, Cursor, Zed or IntelliJ.

## Requirements

- Elixir 1.19 or later
- Phoenix `~> 1.8` and Phoenix LiveView `~> 1.1` in the project you review
- `gh`, installed and signed in, to review pull requests
- the [Claude Code](https://claude.com/claude-code) CLI for the chat panel

## Install

Grasp mounts inside the application it reviews, the way LiveDashboard does. In that project's
`mix.exs`:

```elixir
{:grasp, git: "https://github.com/gfrancischelli/grasp.git", sparse: "grasp", only: :dev}
```

A Hex release will follow; until then the dependency is fetched from git, and `sparse` points
Mix at the `grasp/` directory inside this repository.

In the router:

```elixir
if Code.ensure_loaded?(Grasp.Router), do: Grasp.Router.mount(__ENV__, "/grasp")
```

The guard matters: Grasp is a `:dev` dependency, and the compiler expands an `import` or a
macro even inside an `if` it never takes, so a router that wrote `import Grasp.Router` would
fail to compile in `:test` and `:prod`. `mount/3` writes the routes as `grasp "/grasp"`
inside a `:browser` scope would (pass `pipeline:` to name another pipeline); a project that
ships Grasp in every environment may write the macro directly instead.

In the endpoint, beside the code reloader:

```elixir
if code_reloading? do
  plug Grasp.Plug, at: "/grasp"
end
```

The plug guards the mount — Grasp hands out your source and drives an agent that edits files,
so every request for it has to come from loopback — and serves the MCP endpoint at
`/grasp/mcp`, in front of the router. Its `at:` and the router's path must name the same
mount.

In `.gitignore`:

```gitignore
.grasp/index.json
.grasp/worktrees/
```

## Quick start

```
mix grasp.index --base main
mix phx.server
```

Open <http://localhost:4000/grasp>, pick an entry point or a module in the sidebar or press
⌘K, and click any call inside a card to open the callee next to it. Register the MCP server
so an agent can drive the same canvas:

```
claude mcp add --transport http grasp http://localhost:4000/grasp/mcp
```

## Guides

- [Getting started](grasp/guides/getting-started.md) — install, the first index, the sidebar,
  the palette and the toolbar.
- [Reviewing](grasp/guides/reviewing.md) — the canvas, cards, edges, comments and sessions.
- [Pull requests](grasp/guides/pull-requests.md) — reviewing a branch or someone else's PR,
  and publishing the comments to GitHub.
- [The agent](grasp/guides/agent.md) — the chat panel, the MCP tools and what to ask for.
- [Indexing](grasp/guides/indexing.md) — what the index holds, how it stays current, and what
  it misses.
- [Contributing](grasp/guides/contributing.md) — layout, tests, assets and docs.

The same guides, with the API reference beside them, will be on HexDocs once Grasp is
published there.

`docs/specs/2026-09-15-grasp-design.md` is the design record: the pipeline, the index JSON,
the card graph, the MCP surface and the in-app mount.

## Status

Early. Grasp is used daily on a large Phoenix application, and the parts described here work,
but the public API, the configuration and the index format may still change between versions.
There is no Hex release yet. Reports of edges the indexer misses are especially useful.

## Contributing

Issues and pull requests are welcome: <https://github.com/gfrancischelli/grasp/issues>. See
[Contributing](grasp/guides/contributing.md) for the repository layout, how to run Grasp
against a project, and what the tests and docs expect.

## License

Apache-2.0.

The MCP endpoint is served by [Anubis MCP](https://hex.pm/packages/anubis_mcp), which is
LGPL-3.0. Grasp uses it as an unmodified dependency, resolved from Hex at build time.
