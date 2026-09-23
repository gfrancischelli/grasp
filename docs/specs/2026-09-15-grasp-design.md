# Grasp — call-chain code review for Elixir

## Problem

Reviewing agent-generated Elixir is slow. Editors show one function at a time, following
a call chain means jumping between files, and a unified diff shows changed lines with no
sense of where they sit in the program's flow. As agents write more code than humans can
read this way, review becomes the bottleneck.

Grasp renders a function as a card. Clicking any call inside it opens the callee as a card
to the right, joined to its caller by an edge in the colour of the call, so a long chain reads left to
right and several branches can be open at once. One card stands for one function, so a
helper several of them call is read once. Cards show the function's diff against a base
branch. The top level lists the codebase's entry points, and Cmd+K finds any function. An
MCP server lets coding agents arrange cards and answer review comments
(next/back with a highlighted call) so the human reviews what the agent wants to explain.

## Decisions

- Standalone repository at `~/repos/grasp`, open source from day one (Apache-2.0).
- Two independent Mix projects, not an umbrella. `grasp_index` is the indexer a target
  project adds as a dev dependency; `grasp` is the Phoenix LiveView viewer plus MCP
  server and is never a dependency of the target.
  Superseded by Part 4: one package, `{:grasp, only: :dev}`, mounted in the target's own
  endpoint.
- Call resolution comes from an **Elixir compiler tracer** (exact, the mechanism behind
  `mix xref` and Boundary), with **Sourceror** supplying definition spans and call ranges.
  Reach was evaluated and rejected as the engine: its source-level resolution misses
  what macros inject, and it is a large fast-moving dependency of which only a slice
  would be used.
- PR mode diffs against a **local git base ref**. The base side is Sourceror-parsed
  only; it is never recompiled.
- MCP over **Streamable HTTP** at `/mcp` on the same endpoint as the UI, via
  `anubis_mcp ~> 2.0`.
- Sessions persist as **JSON files** under `.grasp/sessions/` in the target
  repository, so agents can write them and they can travel with a PR.
- Cards form a **graph**, not a strip: one card per function, with an edge from every
  caller on screen, so several branches are visible side by side and a shared helper is
  read once.
- Highlighting by **Lumis** (tree-sitter) with the `github_light` theme; the whole UI
  uses the GitHub Light palette.
- Entry points in v1: Phoenix routes (controller actions and LiveView routes), Oban
  workers, LiveView and LiveComponent callbacks, GenServer, Supervisor, Application and
  Plug callbacks.
- Toolchain pinned to Elixir 1.20.4 / OTP 29 (`.mise.toml`); `grasp_index` requires
  Elixir `~> 1.19` (for `test_ignore_filters`).

## Repository layout

Superseded by Part 4: one package, `{:grasp, only: :dev}`, so the two directories below are
one, `grasp/`.

```
grasp/
  README.md  LICENSE  .mise.toml  .github/workflows/ci.yml  docs/specs/
  grasp_index/   # hex-publishable. Deps: sourceror, jason. Mix task, tracer, extraction,
                 # entry-point detection, git base diff, Grasp.Index reader (shared).
  grasp/         # Phoenix LiveView viewer + MCP. Deps: phoenix, phoenix_live_view ~> 1.2,
                 # bandit, jason, lumis, lazy_html, anubis_mcp ~> 2.0,
                 # {:grasp_index, path: "../grasp_index"}
```

## Part 1 — `grasp_index`

Superseded by Part 4: one package, `{:grasp, only: :dev}`. Everything below describes the
indexer, whose modules and Mix task are unchanged by that.

In the target project:

```elixir
{:grasp_index, "~> 0.1", only: :dev, runtime: false}
```

```
mix grasp.index [--base main] [--out .grasp/index.json]
```

### Pipeline

1. **Trace compile.** Register `Grasp.Index.Tracer` via
   `Code.put_compiler_option(:tracers, ...)`, enable `parser_options: [columns: true]`,
   then `Mix.Task.run("compile", ["--force"])`. The tracer records into ETS, for the
   events `:remote_function`, `:local_function`, `:imported_function`, `:remote_macro`,
   `:imported_macro` and `:local_macro`: caller file, caller `{module, function, arity}`
   from `env`, line, column, callee MFA and event kind. Events fired outside a function
   body (`env.function == nil`) are dropped. Only files under the project's
   `elixirc_paths` are kept, so dependencies are excluded.
2. **Extract definitions with Sourceror.** For each source file: parse, walk `defmodule`
   with a module stack (nested modules resolve to their full name), and collect
   `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, `defguardp` and `defdelegate`
   clauses grouped by `{module, name, arity}`. A head with default arguments registers
   every arity it defines, all pointing at the one definition. The span runs from the
   first attached attribute or leading comment (`@doc`, `@spec`, `@impl`, `@deprecated`,
   `@since`, `@decorate`) through the last clause's `end`; the source text is the file
   slice for that span. Every call node inside the bodies is collected with
   `Sourceror.get_range/1`, keyed by start line and column.
3. **Join.** Each tracer event finds its definition by caller MFA (falling back to file and line
   containment) and its call node by line and column, producing a call with a target id, kind and
   range. An event that has a column but no matching node is macro-generated (`use`-injected
   code) and is kept as a `hidden_call`, so the callers/callees graph stays exact even where
   nothing is clickable. Events reported with **no column at all** come from the same machinery
   but are mostly the expansion's own plumbing — a template engine, a query builder, `Logger`,
   `and` and `>` compiling to `:erlang` — which describes how the code was built rather than what
   the function set out to do, and on a real project outnumbers the interesting calls by more
   than ten to one. A column-less event therefore becomes a hidden call only when its line falls
   inside the definition's span and its target is a definition the index itself holds. That keeps
   the calls a `~H` body makes into the project's own contexts — the controller to template to
   context chain — while leaving the macro's implementation out. A call written in a template's
   `{…}` interpolation is reported the same way — its line, no column — but there the source
   itself says what was called: the extractor parses every interpolation and records its call
   nodes as sites carrying the callee as written (`Greeter.greet`, arity 1), and a column-less
   event whose line holds a site with the same name and arity — and, when the site names a
   module, one the event's target module ends with — takes that site's range and becomes a
   visible call, before the hidden-call rule is consulted (see [Templates](#templates)).
   `defdelegate` is the other column-less case placed as a visible call, ranged over the
   delegate's own name. A `__name__`-shaped target (`__schema__/1`, `__struct__/1`,
   `Phoenix.VerifiedRoutes.__encode_segment__/1`) is dropped before any of this, whatever
   position it carries: it is machinery a macro expanded into, and a `~p` sigil reports its
   encoder at the interpolation's own line and column, where the position rules would otherwise
   make it a clickable call. A `sigil_`-prefixed target (`Phoenix.Component.sigil_H/2`,
   `Phoenix.VerifiedRoutes.sigil_p/2`) is dropped for the same reason: the macro behind a sigil
   builds a literal out of the text beside it and says nothing about what the function calls.
4. **Entry points.** After the traced compile, `Application.load/1` then
   `:application.get_key(app, :modules)` gives the application's modules to iterate. Routers are found by their exported
   `__routes__/0` — `use Phoenix.Router` declares no behaviour — and everything else by
   `module_info(:attributes)[:behaviour]`, which is what tells a LiveView from a
   LiveComponent where their injected `__live__/0` does not. Phoenix, LiveView and Oban
   are reached through `apply/3`, so this package never depends on them at compile time.
   A callback becomes an entry point only when the index holds a definition for it:
   `use GenServer` injects default `handle_call/3` and friends that `function_exported?/3`
   reports as present, and a macro-injected `call/2` on an endpoint is the same noise.
   When the application has no module list at all — an unloadable or applicationless
   project — the step reports it on the shell and yields no entry points rather than
   failing the index.
   - `Phoenix.Router`: `Phoenix.Router.routes/1` yields each route. A controller route is
     kind `route` targeting `{plug, plug_opts, 2}`; a LiveView route
     (`plug == Phoenix.LiveView.Plug`, `metadata.phoenix_live_view`) is kind `live_route`
     targeting the first of `mount/3`, `handle_params/3` and `render/1` the index holds,
     since `mount/3` is optional and a route with no reachable callback would otherwise
     vanish; a view writing none of the three falls back to its first indexed function,
     and a view with no indexed function at all is counted and reported on the shell. A
     forward contributes its mount prefix to the forwarded router's routes, which
     `Phoenix.Router.routes/1` reports relative to the mount — composed to a fixed point,
     so a forward inside a forward carries both prefixes — and the forward route itself
     (`verb == :*`) is not an entry. A route whose `plug_opts` is not an action atom is
     skipped, and so is any route whose target the index does not hold, which is what
     drops a forwarded dependency's own controllers. Meta carries `verb`, `path`,
     `router` and `helper`, with nil values dropped.
   - Every other kind takes its callbacks from the behaviour itself
     (`behaviour_info(:callbacks)`, reached through `apply/2` after `Code.ensure_loaded?/1`
     so a behaviour the project does not use costs nothing), minus the callbacks that
     configure a module rather than run its work: `Plug`'s `init/1`, `Oban.Worker`'s
     `new/2`, `backoff/1` and `timeout/1`, `GenServer`'s `code_change/3` and
     `format_status/1,2`, and `Application`'s `config_change/3`. A callback a new version
     of a library adds is therefore picked up without an edit here.
   - `Oban.Worker` carries `queue` and `max_attempts` from `__opts__/0` when they are set.
     `Phoenix.LiveComponent` is a kind of its own, `live_component`. `Plug` is skipped
     when the module is already a route target.

   A route is labelled `VERB /path`; every callback entry is labelled with the function
   id it targets, so the viewer can strip the module it already prints as a heading. The
   list is sorted by kind — route, live route, Oban worker, live view, live component,
   GenServer, supervisor, application, plug — then label, then target. The same pass
   writes each module's behaviours into its `modules[]` entry.
5. **Base ref (PR mode).** With `--base REF`, the merge base of `REF` and `HEAD` is
   resolved first (`git merge-base`, falling back to `REF` itself), and everything is read
   against that `BASE_SHA`: what the branch did, not what has landed on the base since.
   Changed files are `git diff --name-only BASE_SHA` (working tree included) unioned with
   `git ls-files --others --exclude-standard`, filtered to `.ex` sources under the compile
   paths — the same extension the index itself is extracted with, so a changed file can
   never carry base definitions no current record could answer to. Each base version is
   read with `git show BASE_SHA:./path` and run through step 2 only; a file the base did
   not have is compared against an empty source, so its functions read as added.
   Definitions are matched by MFA across the two sides — under any arity a head declares,
   so a function that gains a default argument is matched, not replaced — giving each
   function a `change` of `added`, `modified`, `removed` or `unchanged`; `base_source` is
   stored for modified and removed functions. Removed functions become definitions flagged
   `removed: true` with no calls. A function moved between files without change counts as
   unchanged.
6. **Write JSON** to `--out`.

### Templates

HEEx is code the graph knows, in five parts, and the hops that are not function calls — a
route a template links to, a job a function queues — are edges beside them:

- **Component tags are call sites.** The compiler reports `<.badge>` and
  `<MyAppWeb.Components.badge>` as calls to the component function, inside inline `~H` bodies
  and inside `.heex` files alike, but not at the same column: a local tag carries the column
  of the `<` that opens it, a remote one the column of the function name, one past the last
  dot. `Grasp.Index.Heex.tag_sites/2` scans template text for those tags — skipping slots
  (`<:name>`), comments, the inside of `{…}` interpolations and expression tags, and
  `<script>` / `<style>` bodies — and yields call sites in file coordinates (a heredoc's
  stripped indentation is added back; a single-line `~H"…"` starts at the sigil's own column),
  each keyed at the column the compiler reports for its form and ranged from the character
  after `<` to the end of the name, so the tag name is the clickable span whichever form it
  takes. The extractor adds them to the definition holding each `~H` sigil; the join then
  matches the events as it does any call.
- **Template files are records.** The extractor records every `embed_templates "pattern"`
  a module body calls, with the `:suffix` and `:root` options it was given. The builder
  globs each pattern under `:root` — resolved against the directory of the module that
  embeds it, which is also where the pattern is looked for when no `:root` is given — and
  makes one definition per match, following Phoenix's naming: the basename with its format
  and engine extensions dropped and `:suffix` appended, so `home.html.heex` is
  `PageHTML.home/1` and the same file under `suffix: "_html"` is `PageHTML.home_html/1`.
  Each record carries `kind` `template`, the template path as `file`, the whole file as
  `source` and span, and the tag sites as call sites; events the compiler reports for that
  function (their file is the template) join to it. A template that also has a
  hand-written definition of the same name and arity is left to the hand-written one.
- **`render` reaches the template.** A call to `Phoenix.Controller.render/2,3` in a
  module named `…Controller` whose second argument is a literal atom or string names a
  template; when `…HTML.<name>/1` is a record, the call's target becomes that record with
  call kind `template`, so a route leads through its action to the page it renders. The
  convention followed is Phoenix 1.7's `use Phoenix.Controller, formats: [:html]`; a
  `put_view` naming another module is not followed.
- **Interpolations are code.** `Grasp.Index.Heex.interpolations/2` yields the body of every
  `{…}` — in a tag body or as an attribute value — and of every `<%= … %>` / `<% … %>`
  expression tag, with its file position, and the extractor parses each body with Sourceror at
  that position (a heredoc's stripped indentation is put back on every continuation line
  first, so every node carries file coordinates) and collects call sites from the AST exactly
  as it does for a clause body: the range covers the callee only. An EEx block opener (`<%= if
  x do %>`) is parsed with an `end` appended; a body that still does not parse (`<% else %>`,
  `<% end %>`) contributes nothing, and a sigil inside a body (`~p"/users/#{@id}"`) yields no
  site of its own. The compiler reports an expression tag's calls with their file column, so
  those sites join like any other; it reports a `{…}` interpolation's calls with the line
  alone, so every site also carries the callee as written — module segments when the receiver
  is a literal alias, `nil` otherwise, the name, and the arity as written, counting a piped
  value as the first argument — and the join matches a column-less event to the first
  unclaimed site on its line with the same name and arity whose written module, if any, is a
  suffix of the event's target module. A call the index does not hold (`Enum.join/2`) is a
  visible external call, as it is in a clause body. Positions inside a single-line `~H"…"`
  follow the same key/range split component tags use.
- **Routes are edges.** A template that links to a page, submits a form or fires an htmx
  request names a route, and a route names a controller action or a LiveView, so the link is
  a call the graph can draw: an edge of kind `route` from the template to the action, which
  makes the template a caller of the action in the callers menu. `Grasp.Index.Heex` reads
  the attributes of every tag — `href`, `action`, `navigate`, `patch`, `hx-get`, `hx-post`,
  `hx-put`, `hx-patch`, `hx-delete` — and yields a **route site** for each whose value is a
  string literal starting with `/` or a `{…}` whose expression is a `~p` sigil: the verb is
  the `hx-*` name, `GET` for `href`, `navigate` and `patch` unless the tag writes a literal
  `method`, which `<.link method="delete">` does, and for `action` the tag's literal
  `method` attribute, defaulting to `POST` on `<.form>` and `GET` on `<form>`; the
  path is the literal's segments, or the sigil's with every `#{…}` interpolation read as one
  dynamic segment (a segment that mixes text and interpolation is dynamic as a whole), the
  query string and fragment dropped; the range is the attribute value with its quotes or
  braces. A `~p` sigil written anywhere else — a `redirect(conn, to: ~p"/…")` in a clause
  body, a bare `{~p"/…"}` — is a route site with verb `GET` ranged over the sigil, found by
  the extractor's AST walk; a sigil that sits inside a route attribute is counted once, as
  the attribute's site. Any other value (`{@path}`, a route helper, an external URL) yields
  nothing. Route sites travel on the definition and through the join unchanged, and a
  resolved record keeps them: they are written to the document under `route_sites`, which is
  what lets an update match a record's sites against the routes it finds.
  `Grasp.Index.Routes.resolve/2` turns them into calls once the entry points are known,
  matching verb and segments against every `route` and `live_route` entry (a `:param`
  segment matches any one site segment, a `*glob` the rest, a dynamic site segment any one
  route segment) and, where several routes match, taking the most specific — fewest dynamic
  route segments, a glob counting most — since the entry-point list is sorted and not in the
  router's declaration order. A resolved site is a call `%{target, kind: :route, range,
  route: %{verb, path}}` whose `path` is the route's own pattern; an unresolved one is
  dropped. The same pass runs in the incremental update, over every record the document
  carries the inputs for, against the entry points that update finds.
- **Jobs are edges.** Putting an Oban job on a queue is a hop as well: a call to `new/1` or
  `new/2` on a module whose `perform/1` is an `oban_worker` entry point is a call of kind
  `enqueue` on that `perform/1`, so the enqueueing function is a caller of the worker and
  the site is a hop the reader follows to the work it sets in motion.
  `Grasp.Index.Jobs.resolve/2` makes the rewrite once the entry points are known — after
  entry-point detection, in the builder and in the incremental update alike — and a resolved
  call is `%{target, kind: :enqueue, range, job: %{worker, queue}, via: %{target, kind}}`:
  the worker is the module the call named, the queue the one that module's `__opts__/0`
  declares, `"default"` where it declares none, and `via` the call the edge stands for — the
  target and kind the compiler reported — so the edge can be undone and derived again
  against another set of workers. The entry points rather than the definitions say which
  modules are workers: a worker that writes a `new/1` of its own — Oban makes both
  overridable — is redirected all the same, and a `new/1` on any other module is left as it
  is. The call keeps its range and its place among the record's calls, and where the rewrite
  leaves a record holding two calls of the same target, kind and range, one is kept. The span
  renders as `data-kind="enqueue"`, titled `Oban job · Worker · queue`, and its edge to the
  worker is drawn dashed, as a route's is: neither hop hands control straight from one end to
  the other.

Against a base ref, a template's `change` compares the whole file with the base commit's
copy (`git show <base>:<path>`): a template the base does not have is added, one whose text
differs is modified and carries the base file as `base_source`, and one the diff never
touched is unchanged.

### Index JSON (version 1)

```jsonc
{
  "version": 1,
  "generated_at": "2026-09-15T10:00:00Z",
  "project": { "app": "my_app", "root": "/abs/path", "elixirc_paths": ["lib"] },
  "git": { "head": "sha", "branch": "...", "base_ref": "main", "base_sha": "sha" }, // null outside git
  "modules": [
    { "name": "MyApp.Wallets", "file": "lib/my_app/wallets.ex", "line": 1, "behaviours": ["GenServer"] }
  ],
  "functions": [
    {
      "id": "MyApp.Wallets.credit/3",
      "module": "MyApp.Wallets", "name": "credit", "arity": 3, "arities": [2, 3],
      "kind": "def", "file": "lib/my_app/wallets.ex",
      "span": { "start_line": 40, "end_line": 62 },
      "source": "@doc ...\ndef credit(...)",
      "calls": [
        { "target": "MyApp.Ledger.post/2", "kind": "remote",
          "range": { "start": [45, 5], "end": [45, 22] } }
      ],
      // a route site the router resolved: a call of kind "route" carrying the route it matched
      // { "target": "MyAppWeb.UserController.show/2", "kind": "route",
      //   "range": { "start": [3, 9], "end": [3, 21] }, "route": { "verb": "GET", "path": "/users/:id" } }
      // an enqueueing call the workers resolved: a call of kind "enqueue" carrying the worker,
      // the queue it runs on, and under "via" the call it stands for
      // { "target": "MyApp.Workers.Forex.perform/1", "kind": "enqueue",
      //   "range": { "start": [50, 5], "end": [50, 30] },
      //   "job": { "worker": "MyApp.Workers.Forex", "queue": "forex" },
      //   "via": { "target": "MyApp.Workers.Forex.new/1", "kind": "remote" } }
      "hidden_calls": [ { "target": "MyAppWeb.CoreComponents.button/1", "kind": "remote", "line": 50 } ],
      // every record carries the route sites the route pass reads; a null path segment is
      // one the source computes
      "route_sites": [ { "verb": "GET", "path": ["users", null],
                         "range": { "start": [3, 9], "end": [3, 21] } } ],
      "change": "modified", "base_source": "...", "removed": false
    }
  ],
  "entry_points": [
    { "kind": "route", "label": "GET /players/:id",
      "target": "MyAppWeb.PlayerController.show/2",
      "meta": { "verb": "GET", "path": "/players/:id", "router": "MyAppWeb.Router",
                "helper": "player" } },
    { "kind": "live_route", "label": "GET /players",
      "target": "MyAppWeb.PlayerLive.mount/3",
      "meta": { "verb": "GET", "path": "/players", "router": "MyAppWeb.Router" } },
    { "kind": "oban_worker", "label": "MyApp.Workers.Forex.perform/1",
      "target": "MyApp.Workers.Forex.perform/1",
      "meta": { "queue": "forex", "max_attempts": 3 } },
    { "kind": "live_view", "label": "MyAppWeb.PlayerLive.handle_event/3",
      "target": "MyAppWeb.PlayerLive.handle_event/3", "meta": {} },
    { "kind": "genserver", "label": "MyApp.Cache.init/1",
      "target": "MyApp.Cache.init/1", "meta": {} }
  ]
}
```

A record's `kind` is the definition form it was written as — `def`, `defp`, `defmacro`,
`defmacrop`, `defguard`, `defguardp`, `defdelegate` — or `template`, for a file an
`embed_templates` pattern matched, which no source line defines. A call's `kind` is the
tracer's — `remote`, `local`, `imported`, `remote_macro`, `local_macro`, `imported_macro`
— or `template`, for a controller's `render` retargeted at the template it names. The word
means two different things in the two places: a record of kind `template` *is* a template,
a call of kind `template` *reaches* one.

`Grasp.Index` (shared reader): `load/1` into a plain struct, `fetch_function/2`,
`callers/2` (reverse index built at load), `callees/2`, `search/3` (substring and
subsequence scoring over `Mod.fun/arity`), `entry_points/1`, `entry_points_for/2` (the
entries a given function is the target of, for the card's badge), `changed_functions/1`,
`modules/1`. The struct is immutable and large — roughly 10 MB of JSON for a 500-file
project — so the viewer stores the loaded index in `:persistent_term`. That keeps the
term off-heap, so every LiveView process reads it without copying; re-loading an index
replaces the term.

### Known gaps (milestone 1)

Edges the indexer does not yet produce. All are planned follow-ups, not design
decisions — the join is only as complete as the definitions the extractor finds, and a
tracer event whose caller has no definition record is dropped entirely.

- **`defimpl` and `defprotocol` bodies.** The extractor walks `defmodule` only, so the
  functions inside a protocol or an implementation get no definition record and their
  tracer events are dropped.
- **Definitions nested under a control structure.** A `def` written inside `if`, `for`,
  `case` or `quote` in a module body is invisible to the extractor for the same reason.
- **Macro-generated functions.** A function a macro defines — the `def`s a `use`
  injects — has no source of its own to extract, so it has no definition record. The one
  exception is `embed_templates`, whose functions have a source: the template file. Those
  are records since milestone 6.1 (see [Templates](#templates)).

## Part 2 — `grasp` viewer

> Superseded in part by [Part 4](#part-4--in-app-grasp): the viewer is mounted inside the
> reviewed application's endpoint; the launcher, `~/.grasp/viewer` and port 4040 are gone,
> and `mix grasp.viewer` serves only Grasp's own development. The card, canvas, session,
> comment and highlighting sections below still describe the viewer as it is.

```
cd my_app && mix grasp.serve [--port 4040] [--editor vscode]
```

The viewer is never a dependency of the project it reviews — its Phoenix, LiveView, Bandit
and MCP libraries would collide with the project's own pins — so `mix grasp.serve` is a
task of `grasp_index`, the one package the project installs, and it launches the viewer
from a checkout of this repository. The checkout is `--viewer PATH` or `GRASP_VIEWER`, else
`~/.grasp/viewer`; when the current project *is* the viewer, the checkout is the current
directory. A checkout that does not exist yet is cloned from `--repo URL` or
`GRASP_VIEWER_REPO` (default: this repository on GitHub); one without `deps/` gets
`mix deps.get`, one without a built `priv/static/assets/app.js` gets `mix assets.build`.
The index defaults to `.grasp/index.json` under the current directory and must exist
(`mix grasp.index` writes it); `--index`, `--port`, `--editor`, `--agent-command` and
`--agent-model` are forwarded. The launcher then runs `mix grasp.viewer --index PATH …` in
the checkout's `grasp/` project as a child process, streaming its output. The child sits in
its own process group, so a terminal interrupt does not reach it by itself, and SIGINT is
the runtime's own — it answers with the break menu and cannot be trapped. The child is
therefore started under a shell that watches the standard input it inherited from the
launcher: that pipe closes the moment the launcher's VM is gone, however it went, and the
shell stops the viewer. A SIGTERM to the launcher is trapped as well and signals the
viewer's process group first. One Ctrl-C — abort at the break menu — stops both, and port
4040 is free for the next run.

`mix grasp.viewer` is the viewer's own task, run in `grasp/`; it takes the same options,
needs `--index`, binds to 127.0.0.1, reloads the index when the file's mtime changes (2 s
poll) and broadcasts the reload.

### Session

`Grasp.Session` is a GenServer per named session, found through a Registry. State:

- `cards`: map of card id to `%{function_id, highlight, view, collapsed, position}` where
  `highlight` is `nil`, `%{call: target_id}` or `%{lines: a..b}`, `view` is `:source` or
  `:diff`, and `position` is `{x, y}` in stage pixels — the node's top-left corner — or
  `nil` for a card that has not been placed yet (see [Layout](#layout)). One card per
  function: a function already on screen is never opened twice.
- `edges`: directed caller → callee, each `%{from, to, target, color}` where `target` is
  the caller's own spelling of the call — which identifies the call site inside its body —
  and `color` indexes an eight-entry palette handed out in creation order, so a call site
  and the edge leaving it are painted alike. At most one edge joins a given pair, so mutual
  recursion reads as two.
- `groups`: map of group id to `%{id, title}`, `title` being a string or `nil`, and a card
  carrying the id of the one group it belongs to (`nil` for none). A group is the section
  drawn round cards, with a name over it or without: it changes no edge, hides nothing, and
  a card is in one at a time. A group whose last card leaves, or is closed, is deleted;
  group ids are never reused.
- a card also carries `context`: `:auto`, `:hunks` or `:full` — whether its diff view shows
  every line or only the changed hunks with three lines of context, `:auto` resolving to
  `:hunks` when the function is longer than 100 lines and to `:full` otherwise.
- `focus`: the focused card id.
- Review comments are not session state: they belong to the code under review and live in
  `Grasp.Comments` (see [Comments](#comments)), so every session on the project reads the
  same threads.

Every mutation broadcasts on `session:<name>` and schedules a write of
`<project.root>/.grasp/sessions/<name>.json`, coalesced: the first mutation after a write starts a
150 ms timer that later mutations do not push out, so a drag's stream of moves lands on
disk about every 150 ms and the last of them within 150 ms of its end; stopping the session
writes what is pending. The file is `{"version": 2, "cards", "edges", "groups", "focus", "next_id",
"next_color", "next_group"}` — the whole struct, so ids and colours survive a restart and
an agent holding a card id keeps a valid one. A session loads from its file when it
starts: a card whose function is no longer in the index is dropped with its edges, and a
group left empty by that goes too, so a stale file never draws a card nothing can render.
A session keeps the directory it resolved at startup and writes nowhere else, so one that
started before the index was loaded — with nowhere to write, and nothing read — stays in
memory rather than writing over a file it has never seen.
A file that does not decode is moved aside as `<name>.json.corrupt` and the session starts
empty; a `version` the viewer does not know is treated the same way. When the root the
index names is not a directory on this machine sessions live in memory only, as comments
do; `:grasp, :sessions_dir` overrides the directory (tests write to a temporary one).
`Grasp.Session.list/0` names the sessions running and the sessions saved, so a saved
session is reachable by name after a restart and `list_sessions` sees it.
`Grasp.Session.delete/1` stops a running session, removes its file and ends the agent
conversation held under that name, since a session opened under it afterwards is a new one;
a tab showing it is sent to the default session.

### Card graph

- Clicking a call opens the callee to the right and adds an edge from the caller's card. A
  card may call many others, so several branches are visible at once.
- A function already on screen is focused and scrolled to rather than opened again, and
  the click leaves an edge from the new caller behind it. A helper three cards call is one
  card with three edges arriving, so reading it once is reading it for every caller.
- The call span stays marked while the callee is open, in the colour its edge carries.
- `x` closes one card: its edges go and what it called stays, unattached. `Shift+x` closes
  it together with everything that had no other way to be reached — a card another visible
  card also calls survives, and so does a card upstream of the closed one that a cycle also
  puts downstream. Collapsing hides what only that card reaches, behind a count badge.
- Opening a caller from the callers menu adds it to the left of the card and joins the
  two; the card itself does not move and keeps every other edge. Several callers may be
  open at once. A card opened from a card inside a group — a caller from its menu, a callee
  from a call — joins that group when it is new, so it is laid out in the same frame, one
  column beside the card it was opened from, rather than in the groupless section; a card
  already on screen keeps the group it has.
- Palette and entry-point selection add a card with no caller. Shift+Enter opens it as a
  callee of the focused card instead.
- MCP `set_cards` replaces the whole graph.

### Layout

A two-dimensional canvas that pans and zooms, and a whiteboard: every card has an absolute
position on the stage, in stage pixels, and nothing moves a placed card but the reader (a
drag, a group drag), a reset, or a card above it growing: a card that grows pushes the cards
it would overlap down by the amount it grew, and the cards those would run into after them,
and when it shrinks back, the cards it pushed return, as long as they are still where the
push left them. Opening a card therefore never shifts the cards already there. A card
arrives with no position; the LiveView renders it hidden and the canvas hook, which alone
knows the rendered sizes, places it on the next patch and pushes `place_cards` with the
result, which the session stores (`Forest.place/2`, filling only positions still empty, so a
stale placement never undoes a drag). Placement is beside the opener, and an opener counts
only within the card's own group: a callee is aimed to the right of the placed card of its
own group whose call site opened it (`GAP_X` 48 px), level with that call site, and settles
in the clear spot nearest there, above or below it; a caller opened to the left goes left of
its target, top-aligned; a card reached only from another group is a root of its own group
instead, since standing it beside that opener would put it inside a frame it does not belong
to. A root with peers of its section already placed opens a row under the lowest of them, at
the section's left edge — or, where that row would reach into another section's frame,
stands beside them, off their right edge and level with their top, which is room the section
can take without growing down into its neighbour. The first card of a section starts below
everything on the stage, cards and frames alike, at the stage's left edge, so a section is a
band of its own rather than a column beside the sections already down; the cards in no group
are laid out last, after every frame.

A card is kept clear of every other section's frame, the header above it included, so
frames laid out this way stack downwards one gap apart and never overlap. A candidate that
would overlap a placed card is swept clear of it (`GAP_Y` 16 px), and clear of whatever
that move ran it into next; against a foreign frame the clearance is that gap plus the
padding the card's own frame takes beyond it (`FRAME_PAD` 28 px), and a downward move past
such a frame carries the card's own header allowance, so the frame that grows round the
card ends a gap clear of the one it passed rather than cutting into it — upwards that
allowance is not needed, since what the card's own frame extends below it is the padding
the clearance already holds. A root and a caller sweep downwards only, sections being
stacked that way on purpose. A callee is swept four ways from its ideal box — down and up
in that column, and down and up in the column one card width and `GAP_X` to the right — and
takes the candidate whose top-left comes to rest nearest the ideal top-left, ties going to
the ideal column and to downwards, so a callee lands in the clear spot nearest its call
rather than at the foot of a busy column. Cards placed in one pass respect one another, and
each placement is made against the frames as they stand rather than as the pass found them.
A card in no group grows no frame, and so takes neither allowance nor padding with it. The
allowance is measured at 100%, so a position the pass pushes never depends on how far out
the reader was standing when the card arrived; the drawn header is counter-scaled, so far
out it stands taller than the allowance the placement left. A section hemmed in on both
sides — the row below it and the room beside it both taken — grows round its neighbour when
a card of it lands past that neighbour.

The pass orders unplaced cards by their section and, inside one, by their depth in the call
graph — the column algorithm below survives as that ordering and as the keyboard's notion of
neighbours — so an agent's `set_cards`, which leaves every position empty, comes out
callers-left of callees in one pass, and "Reset layout" (`Forest.reset_layout/1`) empties
every position to lay the whole canvas out again.

The depth ordering is columns: `Forest.layout/1` computes it. A card nothing
on screen calls is a source and sits in column 0; every other card sits one column right of
the caller that reaches it from furthest right, found by a depth-first walk from the
sources. The walk refuses to re-enter a card already on its own stack, so a recursive or
mutually recursive call names no column and cannot loop for ever; a group of cards that
only call each other has no source at all, so its lowest id is promoted to one until every
card is placed. Within a column, rows follow the callers — column 0 reads in id order, and
every later column is ordered by the mean row of its callers in the column immediately
left, so edges cross as little as possible. A card whose callers all sit further left has
no mean and sorts last, by id.

Depths are computed one section at a time, a section being a group's cards or, last, the
cards in no group: `Forest.sections/1` runs the column algorithm over one section's cards
at a time, seeing only the edges between them, so a member reached only from another
section heads a column of its own and depths count from the section's own left edge. Each
section keeps an element for its header (title, count, an `ungroup` button that dissolves
the group and leaves the cards), which the hook translates to its frame; the cards
themselves render in one flat container, positioned absolutely. A group keeps its section
while a collapse hides every member, so the frame does not blink out of the page.

A group is a frame round cards; its title is a label on that frame and may be absent. The
forest makes one either way: `new_group/3` frames the cards in hand under a title or under
none and always builds a fresh group, while `group_cards/3` addresses a group by title —
reusing the one already carrying it — and so reaches only a titled group. `rename_group/3`
is what names a group afterwards, and a blank title there clears the name rather than being
refused, so a frame can be drawn first and named once the reader sees what it holds. The id
is what names a group for certain: titles are neither required nor unique.

Groups are made and edited on the canvas as well as over MCP, by selecting cards and framing
the selection. Shift+click picks a card out or puts it back — the canvas hook takes the click
in the capture phase, before the card's own focus handler, and pushes `toggle_select`; a
button, a link, a call site or an "Also calls" entry inside the card keeps what it already
does. The selection is a `MapSet` on the LiveView (`selected`) and nowhere else: it is a
gesture half-finished rather than a fact about the session, so it is neither stored nor
broadcast, and two tabs on one session pick cards out independently. The selection is pruned
against every forest that arrives, this tab's own changes and the broadcasts alike, so a card
closed by another tab or by an agent over MCP leaves the selection with it and what is
outlined is always what ⌘G will act on; an index reload empties it outright.

A plain click is the other answer to "which card do I mean", so `focus_card` lets the
selection go, as do the sidebar and the palette, which focus the card they open. Shift+click
never reaches those handlers — the hook takes it first — so it stays the one additive
gesture, and the fallback to the focused card is then the same rule seen from the other end:
the focus is a selection of one.

⌘G frames the selection through `Session.new_group/3` under no title, then clears the
selection and focuses the frame's first card; ⇧⌘G calls `Session.ungroup_cards/2` over it and
keeps the selection, since taking cards out of a frame is as often the first half of putting
them in another. Both fall back to the focused card when nothing is selected, so the chords
work before anything has been picked out. Escape lets the selection go. A frame with no title
renders the placeholder "Untitled group" in place of its heading, muted and italic, which is
clicked to name it like any other title.

A frame's title is renamed in place: clicking it swaps the heading for a form over the same
title — empty for an untitled frame — Enter saves through `Session.rename_group/3` — which
keeps the group's id and its cards, so an id held elsewhere still names it, and takes a blank
title as a frame left with no name — and Escape or a blur leaves it as it was. Which frame is
being renamed is the LiveView's (`renaming_group`), not the browser's, so one rename is open
at a time and a patch cannot lose it. A card is also put into a group by being dragged into
another group's frame: on release the drag hook tests the pointer, in stage coordinates,
against the frame rectangles it drew last (below), skipping the frame of the group the card
is already in, and sends the innermost hit — the last in section order — along with the
move. Dragging a selected card carries the rest of the selection into that frame, the others
keeping the positions they had, since only the card under the pointer moved. A drop anywhere
else — the groupless section, the bare canvas, the frame the card is already in — is a move
and nothing more, so a card never changes group by being put down near one; a grouped card
dragged out onto bare canvas stays in its group, and the frame follows it. A card that does
change group keeps the position the drag gave it: the frame of its new group grows to take
it in where it landed.

A frame is drawn round where its cards are, not round where the layout put them. The
section element holds a group's header, but it has no border of its own: the canvas hook owns a `phx-update="ignore"` layer under the cards and, on every
patch, resize and drag move, draws one rectangle per grouped section — the union of its
visible cards' boxes as they are on screen, the drag in progress included, padded
by 16 stage pixels on the sides and below and by the header's height above — and translates
the section's header to the rectangle's top-left corner, so a card dragged out of the frame
takes the frame with it instead of leaking past its edge. The rectangles are what the drop
test above reads, so "the area of a group" and the frame the reader sees are the same thing.
Two frames may overlap once cards are dragged across; the later section wins a drop inside
both. A group every card of which is hidden by a collapse draws no frame. The frame's border
is `1px / --zoom`, so it stays one screen pixel far out.

A card is as wide as its widest line up to a ceiling (`--card-max-width`, 60rem), rather
than a fixed width, so a column of one-line helpers does not reserve the width of the
widest function in the session. The arrow keys move focus to a caller, a callee or the
neighbour in the same column, and `h` `l` `k` `j` push the same four moves; `x` closes the
focused card, `Shift+x` closes it and everything that hung off it alone, `c` collapses it.

The canvas pans by dragging empty background, by holding Space and dragging from anywhere
(cards included), or with the wheel; Ctrl or Cmd with the wheel zooms about the cursor. The
scale runs from 5% to 250%: far enough out that a canvas of a hundred cards is read as a
shape, and no further in than a card is worth reading at. A toolbar floats at the bottom
centre of the canvas, the way drawing tools place theirs, and carries the sidebar toggle,
zoom out, a zoom readout that resets to 100% when clicked, zoom in, fit, the signature-mode
toggle and the module-clusters toggle (both below), "reset layout", the chat toggle and a
help button (`?`); the chat panel docks above it. That button and the `?` key open the
keys-and-gestures list (`GraspWeb.Help`), a modal `<dialog>` of every gesture and chord the
toolbar has no room to show. Nothing in it is session state, so it is rendered once, marked
`phx-update="ignore"`, and opened, closed and toggled by the `Help` hook alone: `showModal()`
brings Escape, the focus trap and the backdrop from the platform, and no patch can close it
behind the reader's back. `?` is a character, so a reader typing in a field keeps it, a
chord carrying it belongs to whoever claims the chord, and the key is left alone while the
palette is open.
The view — `{x, y, scale}` — lives only in the canvas hook and is written to a stylesheet
rule for the stage rather than to an inline style, so a LiveView patch cannot wipe it
mid-gesture. A wheel over something that can scroll itself — a code body scrolled sideways,
an open callers menu — is left to that element.

Signature mode is the reader's choice, not the zoom's: the toolbar's `signatures` toggle (or
`s`) puts `grasp-signatures` on `<body>`, and while it is on every card drops its body, its
"Also calls" footer and, on a stub, its prose and its hexdocs link, keeping its header and
one line — the function's head.
`Grasp.Highlight.signature/1` renders that head from the same memoised token pieces the body
is built from, so it reads as code rather than as a plain-text label; it carries no gutter
and no call spans, because a call site at that scale is too small to aim at.
`Highlight.signature_line/1` finds the line — the first opening with any of `def`, `defp`,
`defmacro`, `defmacrop`, `defguard`, `defguardp` or `defdelegate`, past whatever `@doc` and
`@spec` sit above it, without the indentation it was written at and without its trailing
`do` — and `CardComponents.signature/1` takes its text for the title a pointer reads. A stub,
or a record with no definition in it, falls back to `Mod.fun/arity`. The header and that
line are sized as `--far-size / --zoom` — 10px divided by the scale the hook writes on the
stage beside the transform — so they measure 10px on screen at every zoom while everything
around them shrinks; everything inside the header takes the header's size, rather than each
element keeping a size the zoom has already shrunk past reading. The card's
width floor and ceiling go with the body, leaving each card as wide as the wider of its
header and its signature. The header keeps its badges, its stats and its tint, which is what
marks a removed function, and its buttons stay live, so a far-out card can be closed or
collapsed without zooming back in to it. The mode is the browser's, like the view: the hook
holds it, marks the toggle pressed, and nothing on the server knows it, so a patch cannot
drop it. The mode never flips on its own: a card changes size only when the reader asks, so
zooming never rearranges the canvas under the pointer.

"Fit" fits in two passes. A frame header measures `--frame-title-size / --zoom` in stage
units, so the scale the first pass picks changes the height of what it measured; the second
pass measures at that scale and lands within a fraction of a percent of the fixed point,
and a third would change nothing a reader could see.

A group's title is read at every zoom: the frame header — title, count and `ungroup` — is
sized as `--frame-title-size / --zoom` (18px for the title, 13px for the rest) in every mode,
so it measures the same on screen whether the canvas is at 5% or 250%. The hook redraws the
frames whenever the scale changes, since the header's box in stage units changes with it.

A card is moved by dragging its header or by Ctrl-dragging anywhere on it. The drag shows an
inline translate at once and pushes `move_card` with the card's new absolute position on
release; the position is stored on the card (`Forest.move/3`) and re-rendered as `--x`/`--y`
on the node. A drag moves that one card: with a card reachable from several callers there is
no subtree to carry along. Alt and drag carries a whole flow instead — every card joined to
the pressed one over the edges the canvas draws, followed in both directions, since a reader
shifting a flow means the calls into it as much as the calls out of it. The gesture takes
precedence over Ctrl and over the header rule, both of which carry the one card, and a link
is left to the browser, whose Alt+click downloads it. The component is read once, at press
time: a flow does not change while it is being dragged, and rereading it on every move would
walk every call site on the canvas over a gesture. Every member travels by the same
displacement, the hook pushes `move_cards` with their ids and the deltas, and
`Forest.shift_cards/3` adds them to each placed member's position; a card with no position
yet is not among them, and a press that gathers no card at all begins no drag rather than a
dead one the release would report. A graph drag decides no membership: the cards travel
together and each stays in the group it is a member of. "Reset layout"
(`Forest.reset_layout/1`) empties every position, and the hook lays the canvas out again on
the next patch. Dragging a frame's title — with or without Ctrl; a press that does not move
is the rename click — moves the group as one: the hook pushes `move_group` with the deltas,
and `Forest.shift_group/3` adds them to every placed member's position, so the cards keep
their places relative to one another and the frame travels unchanged.

Edges are an SVG overlay, not CSS: the hook walks the open call sites, and for each pair of
caller card and callee card it measures the two cards and draws one cubic path between them,
so a line follows a card that has been dragged. The path leaves the caller's card at the
header's port on the side facing the callee, not at the call: a card with many open calls
carries one line to each card they reach rather than a fan of lines out of its own code, and
a function called from three places in one card is still one line. A path takes the palette
colour of the first call site naming its callee, the colour every call to that callee in the
card is painted with, and ends in an arrowhead of the same colour at the callee, so a card
with several callers says which of its edges comes from where and the calls in the body say
which line is theirs. An edge leaves towards the callee and arrives on the side it comes
from, so a caller opened to the right of the card it calls is joined round the outside rather
than through it, and a callee sharing the caller's columns is joined through the edges that
face one another. The overlay is stacked under the cards, so a line between two cards never
covers the code of a third it passes. The overlay sits inside a `phx-update="ignore"` element — the server renders only the arrowhead markers,
which a path cannot carry inline — and its strokes are non-scaling, so they stay visible at
the smallest zoom.

### Page

`GraspWeb.ReviewLive` serves `/` (session `default`) and `/s/:name`. A left sidebar
(`GraspWeb.Sidebar`) starts from the project's entry points, in collapsible groups
ordered from the outside in — Routes (routes and live routes), Background jobs (Oban
workers), Live views (views and components), Processes (GenServers), Supervision
(supervisors and the application), Plugs and Other (any kind the viewer has no group
for) — with Modules last. Which groups arrive open is decided once at mount: the routes
while there are at most fifty of them, the module list when the project has no entry
points at all, nothing otherwise. A group with nothing in it is not rendered, which is
what makes the same sidebar readable in a library and in a web app; a group that is
rendered keeps its body in the DOM when collapsed, hidden, so its title's `aria-controls`
always names an element. Routes are bucketed by the router that declared them and ordered
by path, keeping their `VERB /path` label; every other group buckets its entries by
module, prints the module once as a heading and lists each callback under it as
`fun/arity` alone, with the full id on the row's `title`. Group titles stick to the top while the
list scrolls, and a group's count sits in its title. In PR mode a Changes list grouped by
module with added/modified/removed badges joins them. The canvas fills the rest.

The sidebar's header names the session and opens a menu of the sessions the viewer knows,
running or saved, each a link to `/s/<name>` (`default` to `/`), a field that creates a
session by name (Enter navigates to it; a name is letters, digits, `-` and `_`, up to 40
of them, and a taken name simply opens that session), and a delete control on every
session but the one shown. Deleting removes the file, stops the session and ends its agent
conversation; any tab on it is sent to the default session.

#### Module clusters

The cards of one module cluster: inside a flow, every card whose function belongs to the same
module is framed together, and the cards in no flow cluster the same way in the groupless
section. Membership is derived from the card's function id and never stored — no tool makes a
module cluster, no session file names one, and the same module open in two flows is two
clusters, one per flow. The node carries its module as `data-module`, which is the text before
the function's `name/arity` — an id with no module part stands for its own module — and a
stub card clusters by the module of the function it stands for.

A module frame is drawn round wherever its cards are, as a flow frame is, nested inside the
flow's frame: the flow's extent is the union of its module frames, so a flow frame closes
round its modules with its own padding, and a module frame closes round its cards with less
(`MODULE_PAD`) and a lighter border. Its label is the module name, kept one size on screen at
any zoom like a flow title. The hook draws both frame and label into the frames layer it
already owns; the label takes the pointer so that dragging it carries every card of the
cluster, through `move_cards`, the way a flow title carries its group, and a click on it does
nothing. Because a card cannot leave its module, a card dragged away stretches the module
frame with it, exactly as a card dragged out of a flow stretches the flow's frame; two module
frames may come to overlap by dragging, and placement is what keeps them apart. A drop is
still decided by the flow frames alone: a module frame changes no membership.

While clusters are drawn, a card's header shows only `fun/arity`: the frame carries the
module. A card is as wide as the wider of its title and its body, over a floor, so dropping
the module name narrows only a card whose title with that name is its widest line and stands
above the floor — a stub, or a card with a short body; a card with a wider body keeps the
width its body asks for. The cards in a cluster are the reader's to arrange: nothing inside a
module frame snaps, sorts or stacks, and a card lands where the placement rules below put it
and then moves only when the reader or a push moves it.

Placement reads clusters two ways. A card whose module already has a cluster in its flow
lands adjacent to that cluster rather than beside the call that opened it: the candidates are
the four clear spots against the cluster — to its right and to its left against the frame,
below it and above it against the cards the frame holds, since there the card is joining that
frame rather than clearing it and owes those cards one `GAP_Y` and no more — each swept clear
the way any candidate is, and the one nearest the card's ideal spot (beside the call, level
with it) wins. A card whose module has no cluster yet in its flow is placed by the ordinary
rule, nearest the call, and so is a root — a card the pass reaches from no call of its own
flow — whichever way its module stands.

A card is placed clear of every module frame but its own cluster's, wherever that cluster
stands, and of the flow frames of the flows that are not its own; its own two frames are no
obstacle to it, since it belongs inside both and each grows round it where it lands. What it
leaves a frame is `GAP_Y` plus the padding its own frames reach beyond it on that side, so the
frames it grows end a gap clear of their neighbour rather than cutting into it. Against a
cluster of its own flow that is `MODULE_PAD + GAP_Y`, the two standing inside one flow frame
neither has to clear; against a cluster of another flow the card's own flow frame has to clear
it too, so its padding counts as well (`MODULE_PAD + FRAME_PAD + GAP_Y` for a grouped card) —
a cluster of the groupless section has no flow frame of its own standing between the two, which
is why the case arises; and against another flow's frame it is `FRAME_PAD` plus the card's own
module padding plus `GAP_Y`.

The toolbar's `modules` toggle (or the `m` key) turns clusters off: the frames and labels go,
headers show the full id again, and placement returns to nearest-the-call. Clusters are on by
default, the state is the browser's like signature mode, and "reset layout" lays the canvas
out under whichever setting is current.

### Card

- Header: entry-point badges (a route's `VERB /path` in full, since neither the title nor
  the body carries it; the kind for every other kind, spelled as a reader says it — "live
  route", "worker", "GenServer" — since its label is what the title already says),
  `Mod.fun/arity`, or `fun/arity` while module clusters are drawn, `file:line` that opens the
  `--editor` URL scheme, change badge, Source/Diff toggle, callers menu, collapse, close.
  Which card's callers menu is open is server state (`callers_open`); opening it closes a
  frame rename under way and the other way round, so one panel stands at a time and a patch
  cannot drop it.
- A selected card carries `data-selected` and a dashed outline, which a stub carries too:
  a stub dragged into a frame is in that group like any other card and needs the same way
  out of it. Grouping is a canvas gesture rather than a control on the card, so the header
  holds nothing for it.
- Body: Lumis-highlighted source. Every resolved call is wrapped in a clickable span.
  The highlighted call gets a ring and is scrolled into view. Calls with an open child
  are marked. Calls to functions outside the index (deps, stdlib) render muted and open
  a stub card linking to hexdocs. A route call's span carries `data-kind="route"` and the
  route it matched as its `title` (`GET /users/:id`); it is underlined dotted rather than
  dashed, and the edge it opens is drawn dashed, so a reader tells an HTTP hop from a
  function call at a glance. Clicking it opens the action's card like any call.
- Footer: "Also calls" for hidden calls, then the outdated comment threads (see
  [Comments](#comments)); the anchored ones sit under their lines in the body.

### Comments

A reviewer comments on a line of a card the way a pull request is commented on, and the
agent reads, answers and resolves those comments over MCP — so "address every comment and
redraw the flow" is one prompt in the chat panel.

- **Store.** `Grasp.Comments` is one GenServer for the project, started after the index
  store. A thread is `%{id, function_id, side, line, snippet, body, author, created_at,
  resolved, replies}`: `side` is `"new"` for a line of the current source, numbered as the
  file is, or `"old"` for a line the diff deleted, numbered from 1 within `base_source` as
  the diff view numbers them; `snippet` is the trimmed text of the line when the comment
  was made; `author` is `"human"` or `"agent"`; `created_at` is ISO 8601 UTC; a reply is
  `%{id, author, body, created_at}`; `end_line` is `nil` for a thread on one line, or the
  last line of the range the thread covers (`end_line > line`, same side) — the snippet is
  always the first line's text, which is what re-anchoring reads; `github` is `nil` until the thread is published to a
  pull request, then `%{id, url, published_at}` — the review comment's id and link, kept
  so a second publish skips it. Ids are never reused. A body is stored trimmed and may
  not be blank. Every change broadcasts `:comments_changed` on the `"comments"` topic and
  rewrites `<project.root>/.grasp/comments.json` (`version`, `next_id`, `comments`), which is
  read back when the viewer starts, so comments outlive the viewer and travel with the
  checkout. When the root the index names is not a directory on this machine the store
  keeps its threads in memory only. `:grasp, :comments_path` overrides the file (tests write
  to a temporary one).
- **Anchoring.** A comment names a line by number, and the code moves under it: the agent
  edits the function and re-indexes. `Grasp.Comments.Anchor.place/2` decides, at render
  time and without changing what is stored, where a thread is shown against the current
  record: on its own line when that line still reads as the snippet; on the one line of the
  function that does when the text moved; otherwise the thread is *outdated* and renders in
  the card's footer quoting its snippet, like an outdated review comment. A thread whose
  function is no longer in the index is *orphaned* and is listed in the sidebar alone.
- **Card.** Every line number in a card body is a control: hovering shows `+`, clicking it
  opens a composer under that line (a textarea, Save, Cancel; ⌘/Ctrl+Enter saves, Escape
  cancels). Dragging down or up the line numbers selects a range on one side of one card —
  the lines tint while the pointer moves — and releasing opens the composer under the last
  line for the whole range; Shift-clicking another line number while a composer is open
  extends or shrinks its range. A ranged thread renders under its last line with every line
  it covers tinted, its label reads `L12–L18`, and folding keeps the whole range open. A deleted line in the diff view takes a comment on its `"old"` side. Threads
  render under their line: each comment with its author (`you` or `claude`), its time and
  its body as plain text with line breaks kept, then reply, resolve or reopen, and delete.
  A resolved thread collapses to one line, `Resolved · n comments`, that expands on click;
  which resolved threads a tab has expanded is that tab's own. The composer's draft is the
  browser's (`phx-update="ignore"`), so a patch from an agent run mid-sentence cannot wipe
  it; which line is being composed on, and whether it is a reply, is the LiveView's
  (`composing`), so one composer is open at a time. In signature mode threads and composers
  go with the body they hang under. The body is a `div` of block
  `span.line`s, no longer a `pre`, so a thread can sit between two lines.
- **Sidebar.** A Comments group heads the sidebar when there are open threads, counting
  them, one row per thread under its module — `name/arity · L12` and the first words of
  the body — that opens the function's card and highlights the line. It opens on arrival
  whenever it has rows, as Changes does, and is recomputed with the other defaults at mount
  and on an index reload only; a comment made later does not reopen a group the reader
  closed.
- **Agent.** `list_comments`, `add_comment`, `reply_comment` and `resolve_comment` (Part 3)
  give the agent the threads, with each one's placement, and `get_function` carries a
  function's open threads. The system prompt tells the agent what a comment is and how to
  answer one; in *edit mode* (see the chat panel) it can also act on one.
- **Publishing.** `publish_comments` (Part 3) posts the open threads to the pull request
  of the current branch as GitHub review comments through `gh`, so a review done in Grasp
  ends up where the author reads it. A thread on the `"new"` side whose line falls inside
  the pull request's diff (the changed lines and the context GitHub shows around them) is
  posted on that line, and a ranged thread whose first and last lines both fall inside the
  diff is posted as a multi-line comment (`start_line`, `line`); every other thread — a line outside the diff, or a `"old"`-side line,
  which Grasp numbers within the function rather than within the base file — is posted as
  a file-level comment that names the function, the side and the line and quotes the
  snippet. A thread the agent wrote is prefixed `claude:`; replies are posted as replies,
  in order. Each published thread is stamped with the comment's id and URL; the card shows
  the link in the thread's footer, and a second publish skips stamped threads.

### Highlighting and diffs

Lumis (tree-sitter) runs server-side. `Lumis.highlight/2` with the `:html_linked` formatter
returns one `div` per source line whose children are nested `span.l-*` runs; the HTML is
parsed into text runs, each carrying the class of its innermost span and a start column, so
a run can be split at a call range's boundary and the pieces inside a range wrapped in one
clickable span. A record whose file ends in `.heex` is highlighted with Lumis's HEEx
grammar; every other record with the Elixir one, which injects the HEEx grammar into a `~H`
body, so a component tag is a run of its own on both sides and the call range falls on it.
A record's source is numbered by its own lines, its final newline read as ending the last
one rather than opening an empty one after it — in the diff as in the source, so a
template, whose source is a whole file, is not drawn a line past its own `end_line`. The
theme is `github_light`, inlined into the root layout at compile time from
`Lumis.Theme.build_css!/1`; the rest of the UI uses the same GitHub Light palette.

tree-sitter is super-linear on deeply nested binary-operator trees — a twenty-step `|>`
pipeline parses in tens of milliseconds, a forty-step one in hundreds — and a card
re-renders on every LiveView pass, so the parse is memoised per function id in an ETS
table. The table is owned by `Grasp.IndexStore`, which clears it on every index reload: a
cached piece list carries absolute line numbers, so a stale entry would outlive the span it
was computed for. Only the source-derived pieces are cached; the range split and the call
wrapping depend on the card and on which of its calls are open, and stay per render.

The diff view runs `List.myers_difference/2` over the lines of `base_source` and
`source` and renders a unified diff with gutters. "After" lines keep their clickable
calls; removed lines are highlighted only. Removed functions show their base source in a
red-tinted card.

In diff view a card can show the change alone, the way a pull request does:
`Grasp.Diff.Hunks.fold/2` takes the per-line list, keeps every changed line, every line a
comment thread sits on, and three lines of context on either side of those, and folds each
remaining stretch of unchanged lines longer than one into a row — `⋯ n unchanged lines` —
that expands when clicked (which folds a tab has opened is that tab's own). The card's
preference is `context` on the card: `:auto` folds a function longer than 100 lines and
shows a shorter one whole, and the header's `all lines` / `changes only` toggle (or `z`)
sets it by hand; `set_view` takes it over MCP. The source view ignores it. An edge from a
call site inside a fold leaves the card at its port, as it does for any call site without
a box.

### Command palette

A JS hook opens a `<dialog>` on Cmd+K, Ctrl+K or `/`, the last of which a field the
reader is typing in keeps. The input's debounced `phx-change`
drives `Grasp.Index.search/3`; arrow keys move the selection client-side, Enter opens as a
new root, Shift+Enter as a child of the focused card. Results show id, def/defp, change
badge and file.

### Assets

> Superseded by [Part 4](#part-4--in-app-grasp) §Mounting: `GraspWeb.Assets` serves the
> bundle together with the host's own Phoenix and LiveView JavaScript.


esbuild bundles the three hooks (palette, keys, canvas). Styling is one hand-written CSS
file of custom properties over the GitHub Light palette, plus the Lumis theme stylesheet
inlined in the root layout. No Tailwind. `lazy_html` is a runtime dependency, not a
test-only one: it parses Lumis' HTML on every highlight the cache misses.

### Known gaps (milestone 2)

- **hexdocs links only reach the standard library.** A call target outside the index
  opens a stub card, and the stub links to hexdocs only when the module is loaded in the
  viewer's own VM and belongs to one of the applications Elixir ships. The target
  project's dependencies are not loaded there, so a call into one opens a stub with no
  link. Resolving a dependency's package and version would mean reading the target
  project's lockfile, which the index does not yet carry. Unchanged by milestone 3.

### Known gaps (milestone 3)

- **Route pipelines are not in the index.** `Phoenix.Router.routes/1` returns the route's
  verb, path, plug, plug options, helper and metadata, but not the pipelines it was
  declared through, so the sidebar cannot group or filter routes by `:browser`, `:api` or
  an auth pipeline. Recovering them means reading the router's own source or a private
  reflection function, neither of which is worth the coupling yet.
- **Template calls into dependencies are not shown.** The column-less rule keeps only
  targets the index holds, so a template's call into the project's contexts appears as a
  hidden call while its call into a dependency's helper — a component library, the HTML
  helpers — does not. The alternative is the ten-to-one flood of expansion internals that
  made the whole class unusable.
- **A `.heex` template file does not reach the call graph.** Resolved in milestone 6.1:
  templates `embed_templates` compiles are records with the template file as their source
  (see [Templates](#templates)).
- **`defimpl`, `defprotocol` and definitions nested under a control structure** are still
  invisible to the extractor, so a callback implemented there is neither a card nor an
  entry point. Unchanged from milestone 1.

### Known gaps (milestone 4)

- **One agent run at a time per session.** The CLI takes a single prompt per invocation,
  so the runner refuses a second prompt while one is in flight rather than queueing it.
  Nothing stops a reviewer from opening a second session name and running there.
- **The chat panel needs the Claude Code CLI on the machine.** It is spawned as an
  executable, found on `PATH` as `claude` or named by `GRASP_AGENT_COMMAND` /
  `--agent-command`; `GRASP_AGENT_MODEL` / `--agent-model` picks the model. With no such
  executable the panel reports that and the rest of the viewer is unaffected. A shell
  alias or function is not an executable and will not be found.
- **Transcripts are in memory.** A conversation lives in its runner process, so it
  survives a browser reload and is gone when the viewer stops. Sessions on disk
  (milestone 6) are where a transcript would be persisted, if it is worth persisting.
- **The agent only reads unless told otherwise.** Its built-in tools are `Read`, `Grep`
  and `Glob`, and Grasp is its only MCP server, so it cannot edit a file or run a command.
  Milestone 5.4 adds an edit mode the reader switches on per session; read is still the
  default.
- **No tours.** The agent can open, close, focus and highlight cards, which is enough to
  walk a chain, but it cannot author an ordered tour a reviewer steps through. Tours were
  dropped from the roadmap: groups and `set_cards` cover what they were for.
- **An edge leaving a stub card is not drawn.** An edge is named by a call site in the
  caller's rendered source, and a stub card — one standing for a function the index
  does not hold — has no source, so there is nothing for an edge to leave from. A card
  opened from a stub therefore arrives with no line joining it. Both cards are in the graph
  and laid out in columns as usual; only the line is missing.
- **The module is still named `Forest`.** `Grasp.Session.Forest` holds a graph, not a
  forest of trees. The rename waits for milestone 7 (polish); the persisted JSON is versioned,
  so the file can carry the new name when it comes.
- **Dragging a card moves that card alone.** A card reachable from several callers has no
  subtree of its own to carry along, and moving everything downstream of it would drag
  cards that other, untouched callers also point at. So a hand-placed card leaves what it
  calls where the automatic layout put it.
- **Rows are not aligned with their callers' rows.** A column orders its cards by the mean
  row of their callers, which keeps edges from crossing, but it cannot put a callee level
  with the call site that opened it: cards have different heights, and the server lays out
  the columns without knowing any of them. A heights-aware pass would have to run in the
  browser, where the measurements are.
- **`find_paths` is bounded three ways and says so only for one of them.** `max_depth`
  above 8 or `limit` above 20 is a schema violation the call is rejected for, not a value
  clamped down to the cap, so a client that asks for more gets an error to fix rather
  than a silently smaller answer. The third bound, a 20 000-node visit budget, is the one
  that can bite a caller who asked for nothing unusual; an exhausted budget comes back as
  `truncated?: true`, which says the answer is partial but not which part is missing.

### Known gaps (milestone 5)

- **A whitespace-only edit reads as modified.** A function is modified when its text
  differs from the base's, byte for byte, so reformatting or re-indenting it puts it in
  the Changes group with a diff of lines that say the same thing. Comparing the parsed
  forms instead would hide a change to a string literal or a heredoc, which is worse.
- **A rename is a removal and an addition.** A function is identified by
  `Module.name/arity`, so renaming it — or moving it to another module — is a definition
  the base had and this branch does not, plus one the branch has and the base did not. The
  two are not joined, and neither carries the other's source. An arity change is the same,
  with one exception: the two sides are matched under every arity a head declares, so
  adding or dropping a default argument keeps the function joined to its base version.
- **The base side is never compiled, only parsed.** Calls come from the compiler's tracer,
  which runs over the branch alone, so a removed function has no callers and no callees at
  all — its card shows its source and nothing else — and a modified function's calls are
  the ones it makes now. A call the branch deleted is visible in the diff body and nowhere
  in the graph.
- **Uncommitted and untracked work is part of the branch.** Changed files are the ones
  that differ from the merge base *in the working tree*, plus everything git reports as
  untracked, so a review reads the code as it is on disk. Re-running the index after a
  save is what refreshes it; there is no way to ask for the committed state instead.
- **The diff is line-based.** `List.myers_difference/2` over the two sources, one entry
  per line: a line that changed shows as a deletion above an insertion, with no marking of
  which words inside it differ. Both sides are highlighted as code, so a reader compares
  them by eye.

### Known gaps (milestone 5.4)

- **Comments are plain text.** A body keeps its line breaks and nothing else: no markdown,
  no code fences, no mentions. Rendering markdown would need a sanitiser the viewer does
  not carry, and the agent reads the raw text anyway.
- **A comment cannot be edited.** Delete it and write it again. The store keeps no history.
- **Re-anchoring is by exact text.** A thread follows its line only while the trimmed line
  reads exactly as it did; a line the agent edited is exactly the one that stops matching,
  so a thread addressed in place goes to the footer as outdated once the index is rebuilt.
  That is what GitHub does with an outdated comment, and the reply the agent leaves says
  what changed.
- **One store per project root.** Comments are keyed by function id, not by branch, so a
  checkout that switches branches under a running viewer shows one branch's threads over
  the other's code until they are resolved or deleted.
- **Frames overlap when cards are dragged across.** A frame follows its cards wherever they
  go, so two frames can cover the same ground; nothing pushes them apart, and a drop inside
  both joins the later section. Reset layout untangles them.
- **Opening a pull request switches the working tree.** Closed in milestone 7: `mix grasp.pr N`
  reads the pull request in a worktree of its own and the reader's checkout is left alone
  (see [Part 4](#pull-requests-from-worktrees)). `gh` still has to be installed and signed in.
- **Edit mode trusts the CLI's allowlist.** `Bash(mix:*)` admits every mix task, including
  ones that write outside the project; there is no sandbox beyond what Claude Code applies.
  The mode is off unless the reader turns it on, and per viewer session.

### Known gaps (milestone 6.2)

- **Cards can come to overlap.** Placement avoids overlap only at the moment a card is
  placed. A card that later grows (diff view, all lines, a thread) pushes the cards under it
  down by what it grew, and gives them back when it shrinks as long as they stand where the
  push left them; a card dragged onto another stays where it is. A push moves cards and not
  frames, so a grown card can reach into another group's frame. Reset layout untangles them.
- **A session saved before positions loads laid out afresh.** A version 1 file carries
  offsets from an automatic layout that no longer exists; it loads with every position
  empty and is placed again.
- **Placement is a heuristic.** Beside the opener, nudged down: a long chain opened out of
  order can zigzag, and nothing packs a canvas.

### Known gaps (milestone 6.1)

- **A column-less event is placed by name.** Two calls of one name and arity on one line of a
  template are handed out in document order, which the compiler's event order matches; a call
  whose receiver is not a literal alias (`@mod.greet(x)`) matches any module. A receiver
  written through a rename (`alias App.Money, as: Fmt`) is no suffix of the module the
  compiler resolved, so that call stays hidden. An interpolation that is not a complete
  expression on its own (`<% else %>`) has no sites; a literal inside a
  `phx-no-curly-interpolation` element is parsed like any other interpolation and yields sites
  no event lands on, which mis-highlights only if an event of that name and arity sits on the
  same line. A multi-line `{…}` body whose call sits on a continuation line is keyed at that
  line, as the compiler reports it.
- **Only the `…Controller` → `…HTML` convention is followed.** A controller that
  `put_view`s another module, or renders through `Phoenix.Template.render/4` or
  `render_to_string`, is not linked to its template.
- **A template's diff is the whole file.** Its `change` and `base_source` compare the
  template file with the base commit's copy, since a template has no smaller unit.
- **A deleted template is not reported as removed.** Writing a removed record for it needs
  the module that embedded a path which no longer exists, and the `.ex` file holding that
  `embed_templates` is in the diff only when it changed too. Added, modified and unchanged
  templates are all classified.
- **A single-line `~H"…"` is keyed where the compiler thinks it is.** `sigil_H/2` reports
  every sigil as if it were a heredoc — the content starting on the line after the sigil,
  at column 1 — so a tag in a one-line sigil is keyed at `sigil line + 1` and its column
  within the content, while the `range` the reader clicks is the tag's real place in the
  file. The two coordinate systems coincide for a heredoc and only diverge here.
- **`.eex` templates are records without call sites.** HEEx is the engine whose tags
  compile to component calls, so an `.eex` file an embed matches is a record the compiler's
  events still land on, with nothing clickable in it — and it is highlighted with the
  Elixir grammar, since only `.heex` selects the HEEx one.
- **A computed `:suffix` or `:root` reads as absent.** Both options are read from the
  literal keyword list at the `embed_templates` call; one given a module attribute or any
  other expression is a value no parser can know, and guessing it would name a function the
  compiler never defined, so the embed is globbed and named as if the option were not
  there.

### Known gaps (milestone 7.9)

- **Dragged module frames overlap.** Placement is what holds one cluster clear of the next;
  a reader who drags a card, or a whole cluster by its label, across another module's cards is
  left with the two frames over one another. "Reset layout" lays them out apart again.
- **A module of one card wears a frame.** A cluster is drawn round whatever cards of a module
  a flow holds, one included, so a flow that opens a card each from six modules is six frames.
  Nothing merges a frame with its neighbour and nothing drops one for holding too little.
- **A cluster is per flow.** Membership is the card's module inside the card's section, so a
  module open in two flows is two clusters, each framed, dragged and placed against on its own,
  and there is no gesture that gathers the cards of one module across flows.
- **With the clusters undrawn, a groupless card can stand inside a flow frame's padding.**
  The cards in no flow have no frame of their own for a placement to clear, so with nothing
  drawn round them the only obstacle a grouped card has there is the groupless card itself,
  one `GAP_Y` away, and the flow frame closing `FRAME_PAD` round the grouped card reaches the
  remaining 12px over the groupless one. While the clusters are drawn the groupless card's
  own module frame is an obstacle wherever it stands, cleared with the grouped card's flow
  padding as well (`MODULE_PAD + FRAME_PAD + GAP_Y`), so the two frames end a gap apart.

### Known gaps (milestone 7.5)

- **Only a worker named at the call site is followed.** An enqueue written through
  `Oban.Job.new/2` with a `worker:` option, a changeset built elsewhere and handed to
  `Oban.insert_all/2`, or a worker module held in a variable names no worker where the call
  is written, so nothing redirects it to a `perform/1` and it stays the call the compiler
  reported.
- **Dragged frames overlap.** Placement is what keeps the frames clear of one another; a
  reader who drags a card or a group across another frame is left with the overlap, and the
  later section wins a drop inside both. "Reset layout" lays them out apart again.
- **A section hemmed in on both sides grows round its neighbour.** A card that joins a group
  after another group has been laid out below it takes the room below its group, or else the
  room beside it; when both are taken it drops past the neighbour and its frame closes over
  that neighbour's. "Reset layout" lays the sections out apart again.
- **A graph drag follows the drawn edges only.** Alt and drag carries what the reader can see
  joined up, so a hidden call joins nothing, a call site whose callee is not open on the
  canvas reaches no card, and a card nothing joins to travels alone.

### Known gaps (milestone 7.4)

- **A rendered answer is memoised, and the memo can be dropped.** An assistant entry is
  re-rendered from Markdown on every line of CLI output, so the rendered HTML is cached in
  an ETS table keyed by the entry's text and the ids that text resolves against the index.
  The table is emptied when the index reloads, since the same words then resolve to a
  different set of links, and again once it passes a few hundred entries, since a session
  runs for hours and every answer is a new one. A dropped entry costs one re-render.
- **Function links resolve against the live index.** A function the agent named that the
  index does not hold — one it read in a dependency — stays inline code.
- **An id inside a raw HTML anchor is still linked.** An id written in a Markdown link or
  an autolink is left as the link's own text; one written inside an `<a>` the model
  authored is not detected as a link and is drawn as a button inside it, which is markup no
  browser agrees on and a click that both opens the card and follows the href.
- **A hand-written `data-fn` opens an empty card.** The sanitiser allows `data-fn` on a
  button so that a function link survives it, so a button the model wrote carrying an id
  the index does not hold reaches the hook like any other — and opens a card of nothing, as
  every request to open an unknown id does.
- **A queued prompt runs with the settings of the run before it.** Model and mode picked
  while a prompt waits apply to the run after it.
- **The clipboard needs a secure context.** Copy buttons do nothing over plain HTTP on a
  host other than localhost; the browser refuses the API there.

### Known gaps (milestone 7.3)

- **Only literal paths and `~p` are followed.** A route written through a helper
  (`Routes.user_path(conn, :show, id)`), an assign (`href={@path}`) or string concatenation
  yields no route site. A `method` that is not a literal falls back to the tag's default.
- **Specificity stands in for declaration order.** Two routes that both match a written
  path are resolved to the one with fewer dynamic segments; a router that declares the less
  specific route first and relies on it winning is resolved the other way.
- **Attributes inherited by htmx (`hx-get:inherited`, `hx-boost`) are not read.**
- **A `~p` outside a route attribute is a `GET`.** `redirect(conn, to: ~p"/…")` is one;
  a `~p` handed to a `Req.post/2` is drawn as a `GET` too.

### Known gaps (milestone 5.8)

- **Comments off the diff become file comments.** GitHub takes a line comment only on a
  line its diff shows; a Grasp comment on an unchanged line far from any hunk, and every
  comment on a deleted line (numbered within the function, not the base file), is posted
  at file level with the location and the snippet in the body. Anchoring deleted lines
  would need the base file's line for the function, which the index does not carry.
- **Publishing is one way.** Replies and resolutions made on GitHub after publishing do not
  come back into `.grasp/comments.json`; a thread published once is never posted again,
  even if its Grasp replies grew since.
- **Publishing takes the whole store.** `publish_comments` posts every open thread in
  `.grasp/comments.json`, including ones written against another branch that were never
  resolved, and the stamp is per thread, not per pull request — a thread that landed on the
  wrong pull request cannot be published again to the right one. Resolve or delete threads
  from an earlier review before publishing the next.
- **The launcher needs git and the network on first run.** Closed in milestone 7: the
  launcher is gone. `mix grasp.serve` clones the
  viewer and downloads its dependencies and esbuild once; after that it runs offline. The
  checkout is whatever branch the clone left it on and is never updated by the launcher —
  `git pull` in `~/.grasp/viewer` by hand.

## Part 3 — MCP

> Superseded in part by [Part 4](#part-4--in-app-grasp): in a host the transport is served by
> `Grasp.Plug` at `<mount>/mcp` on the host's endpoint. The tools below are unchanged.

Served by `anubis_mcp` at `/mcp` over Streamable HTTP, on the same endpoint as the viewer.
Every session tool takes a `session` name (default `"default"`) and creates that session on
first reference. Results are JSON text content, so any MCP client can read them.

- Read tools: `search_functions(query, limit)`, `get_function(id)` returning the record
  (module, name, arity, kind, file, span, source, calls, hidden calls) plus its callers and
  the entry points that lead to it, `get_callers(id)`, `get_callees(id)`,
  `find_paths(to, from?, max_depth, limit)`, `list_entry_points(kind?, query?, limit)`,
  `list_modules(query?, limit)`, `list_sessions()`.
- `find_paths` walks the call graph (visible and hidden calls) breadth first, shortest
  paths first, and returns at most `limit` distinct paths of at most `max_depth` hops
  (default 6, cap 8). With `from` omitted it walks callers backwards from `to` until it
  reaches an entry-point target, so "which controller or worker reaches this function"
  is one call. Each path is a list of function ids; a path that starts at an entry point
  carries the entry's kind and label. A visit budget bounds the walk on large graphs and
  the result says when it was hit.
- Session tools: `get_session(name)`, `set_cards(name, cards)`, `open_card(name,
  function_id, parent_card_id?, highlight?)`, `close_card(name, card_id)`, `focus_card(name,
  card_id)`, `highlight_card(name, card_id, highlight)`, `group_cards(name, title?,
  card_ids)`, `ungroup_cards(name, card_ids)`, `rename_group(name, group_id, title?)`. Every
  session tool returns the resulting graph as JSON — `focus`, `cards` (each with its id,
  `function_id`, `collapsed`, `highlight`, the `group` it is in and the ids in `callers` and
  `callees`), `edges` (`from`, `to`, the call `target` and the palette `color`), `groups`
  (`id`, `title` — null when the group has none — and the cards in each), `sections` (a
  group id or null, and its columns) and `columns`, the ids in layout order — so the agent
  can address cards it just created and see how they were laid out.
- `group_cards` frames cards already open under a title, creating the group when nothing
  carries that title yet, and `ungroup_cards` takes cards back out. With no title it frames
  them under a group of its own with no name, so an agent that has a set of cards to draw
  apart from the rest need not invent a heading for it. A card belongs to one group, so
  naming it in a second takes it out of the first, and a group left with no cards is
  deleted. An unknown card id is a tool error naming it.
- `rename_group` names a group by its id and changes only its title: the cards stay put and
  the id stands, so a `group` or `sections` entry already quoted still names the same group.
  It is how an untitled frame is given a name and, with the title left out, how a frame
  loses one. An unknown group id is a tool error naming it; the title is stored trimmed,
  since `group_cards` matches one exactly. Titles are neither required nor unique — a rename
  may give two groups the same one, and `group_cards` and `set_cards`, which address a group
  by title, then reach whichever was made first — so the id is the only handle that names
  one group for certain. The forest carries the operations this is built on — `new_group/3`,
  which always makes a fresh group, titled or not, `rename_group/3` and `add_to_group/3`,
  which joins cards to a group by id rather than by title and creates none — and the
  viewer's manual grouping drives the same ones.
- `set_cards` replaces the graph. `cards` is a flat list of `{key, function_id,
  parent_key?, group?, highlight?}`; `group` is a title rather than an id, so entries
  sharing one land in the same group and the groups are created in the order their titles
  first appear — one `set_cards` call lays out several flows, each in its own frame, and an entry that names no
  group under a parent that has one is drawn in the parent's frame, as a card opened from a
  frame is; `key` is any string the caller picks, `parent_key` names
  another entry, and entries are applied in order so a caller precedes what it calls. Two
  entries naming the same function describe one card with an edge from each caller, so a
  helper listed under each of its callers is drawn once. Unknown function ids or dangling
  parent keys make the whole call a tool error that names them, and the graph is left
  untouched. An edge from `set_cards` or `open_card` carries the caller's own spelling of
  the call when such a call exists, so the coloured edge and the marked call span render as
  if a human clicked.
- A highlight is `{call: target_id}` or `{lines: [first, last]}`. The card renders the
  highlighted call with a ring, or the highlighted lines with a tinted background, and the
  canvas reveals it when the card gains focus. A highlight stays until replaced or the
  card closes.
- PR mode adds two tools. `list_changes()` answers `total`, the `base_ref` the index was
  built against (`null` without one) and the changed functions sorted by id, each with its
  `id`, `change`, `file`, `line` and `module` — the first call of a pull-request review,
  from which each id is traced to its entry points with `find_paths`. `set_view(name,
  card_id, view)` shows a card as its `"source"` or its `"diff"` and answers the graph like
  every other session tool; only a modified function has two sides, so a diff of anything
  else is a tool error naming the function. `set_view` also takes `context` — `"hunks"`,
  `"full"` or `"auto"` — deciding whether the diff shows every line or only the changed
  hunks with context (see [Highlighting and diffs](#highlighting-and-diffs)).
- Comments add four tools, none of which takes a session: `list_comments(function_id?,
  include_resolved?)` answers `total` and the threads sorted by id — each with its fields,
  the function's `file`, its `status` (`anchored`, `outdated` or `orphan`) and the
  `anchored_line` it is shown at (null when not anchored); `add_comment(function_id, line,
  body, side?)` leaves a thread as the agent (`author: "agent"`) on a line of the function's
  current source (`side` `"new"`, the default) or of its base source (`"old"`), taking the
  snippet from the index, and is a tool error naming the function and its span when the
  line is outside it; `end_line` (optional, greater than `line`, inside the span) makes it
  a ranged thread, and every thread carries `end_line` in its map; `reply_comment(comment_id, body)` appends a reply as the agent;
  `resolve_comment(comment_id, resolved?)` resolves (default) or reopens a thread. Unknown
  ids and blank bodies are tool errors. `get_function` carries `comments`, the function's
  open threads with the same fields, and every thread carries `github_url` (null until
  published). There is no tool that deletes a comment: what a reviewer wrote is theirs to
  remove, from the card.
- `publish_comments(pull_request?, include_resolved?)` posts the threads to a pull request
  (see [Comments](#comments), Publishing). Without `pull_request` it takes the one open for
  the current branch (`gh pr view --json`). It reads the pull request's diff (`gh pr diff`)
  to decide which threads can be line comments, posts each unpublished thread with
  `gh api` (`POST repos/{owner}/{repo}/pulls/N/comments`, `commit_id` the pull request's
  head), then each of its replies, and stamps the thread. It answers `pull_request`
  (`number`, `url`), `published` (`comment_id`, `url`, `kind` `"line"` or `"file"`),
  `skipped` (`comment_id`, `reason` — already published), `failed` (`comment_id`, `error`
  — GitHub's refusal, or a function no longer in the index) and `warnings`: one when the
  index's `git.head` is not the pull request's head (the lines may be off), one per reply
  that failed after its comment landed, and one per comment that landed but could not be
  stamped (publishing again would post it twice). A number that is not positive, a missing
  or unauthenticated `gh`, no pull request for the branch, or a project root that is not a
  directory on this machine is a tool error carrying `gh`'s own message where there is one. The tool works in
  both chat modes: it writes to the pull request, not to the working tree.
- `reload_index()` makes the store read the watched index file now, instead of at its next
  mtime poll, and answers the loaded index's summary: `path`, `functions`, `changed`,
  `base_ref`, `branch` and `head` (the last three null without git). An agent that has just
  rebuilt the index calls it before `list_changes`, so it never reads the file the rebuild
  replaced. A file that does not load is a tool error carrying the store's reason.

Registering in Claude Code:

```
claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
```

### Chat panel

The viewer can drive an agent itself, so a reviewer types "show me the award bonus flow"
and watches the cards arrive. The panel is a server-owned dock over the canvas (toggle
with Cmd+I or the toolbar button) with a transcript, a prompt box, Send, Stop and New
conversation.

- `Grasp.Agent.Runner` is a GenServer per session name. On a prompt it spawns the Claude
  Code CLI headless (`claude -p PROMPT --output-format stream-json --verbose`) with the
  indexed project's root as its working directory, Grasp registered as its only MCP server
  (`--strict-mcp-config --mcp-config {"mcpServers":{"grasp":{"type":"http","url":
  ".../mcp"}}}`), built-in tools limited to `Read Grep Glob`, and `mcp__grasp Read Grep
  Glob` pre-approved through `--allowedTools`, so it never edits files or runs commands.
  The appended system prompt names the viewer session and tells the agent to discover with
  the read tools and answer with `set_cards`, starting at entry points and reusing one card
  for a function two callers reach. Follow-up prompts pass `--resume <session_id>` (taken
  from the stream's `system/init` event), and New conversation drops that id. The command
  is configurable (`:grasp, :agent_command`, default `claude`) so tests substitute a
  script.
- The panel offers the model the CLI runs with: `Grasp.Agent.models/0` — `haiku`, `sonnet`,
  `opus`, `fable` — plus a default entry that leaves the choice to `:agent_model`
  (`--agent-model` / `GRASP_AGENT_MODEL`) or, failing that, to the CLI itself.
  `Grasp.Agent.set_model/2` records the pick on the runner, which reads it when it builds
  the next command, so a live run is not disturbed and New conversation keeps the pick while
  dropping the transcript. A name the facade does not know is refused rather than passed to
  the CLI; the select cannot offer one.
- The panel also offers the agent's *mode*, `read` or `edit` (`Grasp.Agent.modes/0`,
  `set_mode/2`, recorded on the runner like the model and read when the next command is
  built; `read` unless picked). In `read` mode the tools are as above. In `edit` mode the
  built-in tools are `Read Grep Glob Edit Write Bash` and the pre-approved set is
  `mcp__grasp Read Grep Glob Edit Write Bash(mix:*) Bash(git status:*) Bash(git diff:*)
  Bash(git fetch:*) Bash(git switch:*) Bash(gh pr view:*) Bash(gh pr checkout:*)`, so the
  agent can change files under the project root, run mix, and bring a pull request's branch
  into the working tree — nothing else runs without the CLI asking, and headless it cannot
  ask. `git switch` rather than `git checkout`: the latter also discards files, and the
  former refuses to leave changes behind unless told to, which the prompt forbids. The appended system prompt tells the
  agent in either mode what review comments are and how to answer them; in `edit` mode it
  adds the working order: act on the comment, `mix format` the touched files, rebuild the
  index with the command the prompt spells out (`mix grasp.index`, with the `--base` the
  index was built with and the `--out` the viewer watches when that is not the default), so
  the cards reload from it, and only then arrange the cards again. In `read` mode a comment
  that asks for a code change is answered with the change the agent would make and a note
  that the chat must be switched to edit mode.
- "Open PR 1212" is one prompt in `edit` mode. The system prompt carries the recipe: read
  the pull request with `gh pr view N --json baseRefName,headRefName,title,url`; `gh pr checkout N` in the reader's own working tree — uncommitted changes and untracked
  files travel along, since git carries them across a switch, and a checkout git refuses
  because it would overwrite a modified file is final: the agent reports the files and does
  nothing else, never stashing, resetting or forcing; `git fetch origin <base>`; rebuild the index against
  `origin/<base>` (the `--out` the viewer watches when that is not the default); call
  `reload_index` so the viewer reads the new file at once rather than on its next poll;
  then `list_changes` and `set_cards` with one group per flow, roots at the entry points,
  so the whole change is on the canvas in frames. Comments from an earlier review of another
  branch stay in `.grasp/comments.json` until resolved or deleted; the prompt says so. In
  `read` mode the same request is answered with a note to switch the chat to edit mode.
- "Publish the comments to the PR" is one prompt in either mode: the system prompt names
  `publish_comments`, says to pass the number when the request has one, and asks the agent
  to report which threads went on their line and which as file comments, and any failure,
  from the tool's answer.
- The runner parses the JSON stream line by line: `assistant` text blocks stream into the
  transcript, `tool_use` blocks become tool rows showing the tool name and its main
  argument, `tool_result` blocks mark the row done or failed, `system/init` records the
  session id and reports when the `grasp` MCP server is not connected, and `result`
  closes the run with its cost. Lines that are not JSON (stderr is merged) are kept as a
  log shown when the run fails. Stop kills the OS process. One run at a time per session;
  a second prompt while running is queued.
- **Rendering.** An assistant entry is Markdown. `GraspWeb.ChatMarkdown` renders it
  server-side with MDEx — GitHub-flavoured (tables, strikethrough, task lists, autolinks),
  raw HTML sanitised against an explicit allow-list, so model output can never inject markup
  — highlights fenced code with Lumis so a snippet in the chat reads like the card it came
  from, and turns every function id the index holds (`Mod.fun/arity`, in backticks or in
  prose) into a button that opens that function's card. A user entry stays plain text.
- **Working state and streaming.** The CLI runs with `--include-partial-messages`, so text
  arrives as deltas: `Grasp.Agent.Stream` folds them into a partial assistant entry that the
  full block replaces when it lands, and the panel reads token by token. While a run is live
  the panel says so in one place that stands for the whole run: a status line carrying three
  animated dots, the elapsed time (the runner publishes `started_at`; the hook ticks the
  seconds) and the number of tool calls this turn, with a spinner on the tool call under
  way. A row that came and went between the run's events would flicker at tool-call speed,
  since a line of CLI output is a patch, so nothing is inserted into or removed from the
  log between them;
  Send stays where it is and a Stop button appears beside it for the duration, so a prompt
  can be queued while a run is live.
- **Tool rows.** Consecutive tool calls fold into one group, "Used N tools", open while one
  of them is running or while the live run has said nothing since, and closed once the run
  has moved past the group or ended; each row carries a human label — "Searched “award”",
  "Read MyApp.Wallets.credit/3", "Arranged 4 cards", "Ran mix format" — its duration, and,
  when it failed, the tool's error text under it. A finished turn ends with its cost, its
  number of turns and its wall time, from the `result` event.
- **Prompt box and queue.** The prompt is a textarea that grows to six lines: Enter sends,
  Shift+Enter breaks a line, ArrowUp on an empty box recalls the previous prompt. A prompt
  sent during a run is queued, shown under the log with a way to withdraw it, and starts when
  the run ends; Stop and New empty the queue. An empty transcript offers starting prompts —
  what changed (in PR mode), explain the focused card, publish the comments, follow the first
  route — each sent as typed.
- **Scrolling, failures, copying.** The log follows new output only while the reader is at
  its bottom; otherwise a "latest" pill offers the way down. A failed run shows the CLI's log
  inline under the error with a Retry button that sends the last prompt again. Every
  assistant message and every code fence has a copy button.
- The runner broadcasts its transcript on `agent:<name>`; `ReviewLive` subscribes, so
  every tab on the session sees the same conversation, and card changes arrive through
  the ordinary session broadcast because the agent went through MCP like any other client.

## Part 4 — In-app Grasp

Milestone 7 changes how Grasp is installed and where it runs, the way Tidewave and
LiveDashboard run: as one development dependency mounted inside the reviewed application's
own endpoint. Where this part contradicts Parts 1–3, this part wins; the earlier text stays
as the record of how the pieces work.

### One package

`grasp_index` and the viewer become one Mix project and one Hex package, `grasp`, whose
modules keep their names (`Grasp.Index.*` for the indexer, `Grasp.*` and `GraspWeb.*` for
the viewer). The reviewed project installs it with one line:

```elixir
{:grasp, "~> 0.1", only: :dev}
```

Its dependencies are what the viewer needs — Phoenix `~> 1.8`, LiveView `~> 1.1` (the viewer
uses nothing newer; it is tested against 1.1 and 1.2), Phoenix.HTML, Jason, Lumis `~> 0.8`,
LazyHTML, anubis_mcp, Sourceror — and they resolve against the host's lock file. That is the
trap accepted: a host on an older LiveView or Lumis upgrades to use Grasp. Bandit is
optional, used only by the standalone endpoint.

The OTP application starts Grasp's core — PubSub, the index store, the comments store, the
session and agent registries and supervisors, the MCP server, the reindexer — whenever Mix
is running (a release has no Mix and gets nothing, as Tidewave does). The viewer's own
endpoint starts only when `config :grasp, standalone: true`, which `mix grasp.viewer` and
the test environment set; embedded in a host it starts no endpoint of its own.

### Mounting

The host adds Grasp to its router inside a scope that runs its `:browser` pipeline, and adds
one plug to its endpoint:

```elixir
import Grasp.Router

scope "/" do
  pipe_through :browser
  grasp "/grasp"
end
```

```elixir
if code_reloading? do
  plug Grasp.Plug
end
```

That plug carries both of Grasp's reasons to run before the router. It **guards** the mount:
`GraspWeb.Plugs.LocalOnly` has to cover the page and its assets, not only the MCP endpoint,
since a page whose DNS rebinds to `127.0.0.1` is same-origin with the dev server and Grasp
serves it every indexed function's source and an agent that edits files — and a host cannot be
asked to put a loopback check in the pipeline its own pages run through. And it **serves the
MCP transport**, because a browser pipeline declares `plug :accepts, ["html"]`, an MCP client
asks for `application/json, text/event-stream`, and no route option exempts a route from the
pipeline that fronts it.

The plug takes `:at`, the prefix Grasp is mounted at (default `/grasp`), and `:mcp`, where the
transport answers (default `:at` with `mcp` under it). `:at` must be the path `grasp/2` was
given; `"/"` guards the whole application, which is what Grasp's own standalone endpoint wants
and what a host does not. `grasp/2` takes `:mcp_path` to match `:mcp`, since that is the
address the chat panel hands the agent. Everything else under the prefix passes through to the
router once it has been checked, and everything outside it passes through untouched.

`grasp/2` expands, as `live_dashboard/2` does, to a `live_session` named `:grasp` with
Grasp's own root layout and no app layout, routing `/grasp` and `/grasp/s/:name` to
`GraspWeb.ReviewLive`; and `/grasp/assets/:asset` served by `GraspWeb.Assets`, a plug
that embeds at compile time the host's own `phoenix.js`, `phoenix_html.js` and
`phoenix_live_view.js` (read
from those applications' `priv/static`, so the JavaScript always matches the LiveView the
host runs) followed by Grasp's hooks bundle, and Grasp's stylesheet, each under a content
hash. Grasp's bundle therefore does not bundle Phoenix or LiveView: `app.js` reads them from
the globals those files define and connects its own `LiveSocket` to the host's live socket
path (`live_socket_path` from the endpoint's configuration, `/live` by default). The Lumis
theme stays inlined in the root layout. The standalone endpoint mounts the same macro at
`/`, so the viewer's own tests exercise the mounted form.

The root layout carries an inline `<style>` for that theme and a same-origin `<script>`, so a
host whose dev environment sends a strict `Content-Security-Policy` needs `style-src` to admit
the inline block — by nonce or by exception — for the page to render as designed.

Configuration lives under `:grasp` in the host's `config/dev.exs`, all optional:
`index_path` (default `.grasp/index.json` under the project root), `editor`, `agent_command`,
`agent_model`. The project root is the directory the host was started from. When the index
file does not exist the page says so and names `mix grasp.index`; nothing crashes.

### The tracer rides the code reloader

Grasp's reindexer installs `Grasp.Index.Tracer` into the VM's compiler options when it
starts (and `parser_options: [columns: true]`), so every compile the host's code reloader
performs — the incremental compile that follows a save — reports its call events to Grasp.
Events accumulate; 300 ms after the last one, the reindexer updates the index incrementally:
it takes the set of project files the events name, re-extracts those files with Sourceror
(a file that no longer exists drops its definitions), joins the new events to the new
definitions, recomputes entry points from the modules now loaded, resolves every record the
document holds against them — the rebuilt records and the kept ones alike, since the document
carries each record's own inputs, so a route or a worker that appears or goes moves the edges
of a function whose file nothing recompiled, while a record written without those inputs is
left as it is — classifies the changed files against the base commit the document records as
`git.base_sha` (the commit is verified once per flush, then each changed file's base source
comes from `git show`; nothing is cached — a flush reads only the files the save touched, and
a git that cannot answer leaves the records with the classification they already had), writes
the whole document back to the index file and reloads the store. Cards
therefore follow a save within a second or two, with no `mix grasp.index` run. The 300 ms
throttle on the tracer's notifications is held per compiler process, in that process's own
dictionary, so a compile of a thousand files costs of the order of one message per file.
Two rules keep an event from being joined to a file that moved under it: an event carrying
a column that lands on no call site is dropped (where a full build keeps it as a hidden
call), and an event older than the mtime of the file it names is not joined at all. A batch
naming more than fifty project files is a rebuild rather than a save: the reindexer says so
and leaves the index to `mix grasp.index`. The reindexer follows a document only while its
`project.root` is Grasp's home directory: `mix grasp.pr` writes an index rooted in a
worktree, and the host's compiles describe a different tree, so live reindexing pauses —
once, with a line saying so — until an index of the host's own tree is loaded again. What the
incremental path cannot see — a compile that happened before Grasp started, a change to
which files are compiled at all — is what `mix grasp.index` is for; it stays the full build.

`mix grasp.index` compiles in a build directory of its own, `_build/grasp` (`--build-path`),
seeded by copying the host's `_build/dev` the first time it is missing, so the forced
recompile never contends with the running dev server's build lock and never invalidates its
beams.
The full build and the incremental update share `Grasp.Index.Builder`'s stages:
`source_files/2`, `extract/2`, `Grasp.Index.Join.join/3` (options `:known_ids` and
`:unmatched_positions`), `entry_points/2` (app and records), `classify/3` (records, resolved
base, compile paths) and `document/5`.

### Pull requests from worktrees

"Open PR 1251" no longer switches the reader's working tree. `mix grasp.pr N` does the
whole recipe deterministically: reads the pull request with `gh pr view` (base branch,
head branch, title, URL), fetches both branches, adds a worktree at
`.grasp/worktrees/pr-N` detached at the fetched head — or detaches the one already there at
it, so a pull request pushed to since the last review is re-read rather than left where it
was — and then works in the worktree's copy of the host project: the worktree itself when
the project is the repository's top, and otherwise the same directory below it that the host
project is below its own top (`git rev-parse --show-prefix`), as in a repository holding
several projects. There it symlinks the host's `deps/`, seeds its build path from the host's
`_build/dev` when missing, and runs the index build against `origin/<base>`, writing the
index to the host's `.grasp/index.json` with that directory as `project.root`. `--base REF` reviews
against a ref other than the one the pull request targets, and `mix grasp.pr N --close`
removes the worktree. The agent's
edit-mode recipe becomes: `mix grasp.pr N`, then `reload_index`, then `list_changes` and
`set_cards` one group per flow; the allowlist drops `git switch` and `gh pr checkout` and
gains nothing, since the task does the git work. In edit mode the agent's edits land in the
worktree (`project.root`), as do `mix format` and the rebuild; the host keeps running the
code it started with.

Comments and sessions belong to the reader, not to the tree under review: their files live
under the host project's own `.grasp/` — `:grasp, :home`, recorded at start as the directory
Grasp started in — whatever `project.root` the index names, so a review survives the worktree
being removed. `mix grasp.viewer` pins that home to the indexed project's root instead when
it is a directory on this machine: the standalone viewer is started from Grasp's own
checkout, which is nobody's review, so its comments and sessions stay with the code they are
about.

### What goes away

`mix grasp.serve`, the launcher and its checkout under `~/.grasp/viewer`, and port 4040.
`mix grasp.viewer` remains for working on Grasp itself. The known gap "Opening a pull
request switches the working tree" is closed.

### Known gaps (milestone 7)

- **The first index is still a full build.** The reindexer only sees compiles that happen
  after Grasp started; `mix grasp.index` (30 s on a large project, in its own build
  directory) is how a canvas begins.
- **One host, one Grasp.** Two dev servers of the same project share `.grasp/` and would
  fight over the index file; run one.
- **The worktree's dependencies are the host's.** The index build runs with the host's
  `mix.lock` in place of the pull request's, since Mix refuses a lock pinning versions the
  lent `deps/` does not hold, and puts the pull request's back when the build ends,
  succeeded or not. An upgraded dependency is compiled at the host's version, so the index
  may miss or mis-resolve calls into what the upgrade changed; a dependency the host does not
  have stops the build with Mix's message.
- **Version coupling.** Grasp's Phoenix, LiveView and Lumis requirements are the host's
  to satisfy.
- **The build seed goes stale.** `_build/grasp` is copied from `_build/dev` once. A
  dependency rebuilt afterwards is not copied again; deleting `_build/grasp` takes a fresh
  seed. A worktree's seeded build directory ages the same way.
- **Two prefixes, no check.** `grasp "/grasp"` in the router and `plug Grasp.Plug, at: "/grasp"`
  in the endpoint must name the same mount; nothing verifies it, and a host that changes one
  gets a partly unguarded page or an agent pointed at a 404.
- **The loopback guard is a browser defence.** `GraspWeb.Plugs.LocalOnly` checks `Host`
  and `Origin`, which stops a page from another origin reaching Grasp through DNS
  rebinding; it does not stop a peer that sends `Host: 127.0.0.1` itself. A host whose dev
  server binds every interface (a container, WSL, a `0.0.0.0` bind) exposes every indexed
  function's source and, in edit mode, an agent that writes files, to anyone on that
  network. The bind address is the host's choice; Grasp inherits it.
- **Worktrees are not cleaned up.** `.grasp/worktrees/` grows one checkout and one seeded
  build per pull request until `mix grasp.pr N --close`, which discards uncommitted edits.

## Testing

- `grasp_index`: a fixture project at `test/fixtures/sample_app` with phoenix,
  phoenix_live_view and oban as deps (no database, nothing started) containing a router,
  a controller, a LiveView, an Oban worker, a GenServer, nested modules, default
  arguments, multi-clause functions, a `~H` function-component call, and calls through
  an alias and an import. An integration test runs `mix grasp.index` in the fixture as a
  subprocess and asserts on the JSON. Unit tests cover Sourceror extraction, the tracer
  to range join, and the git base diff against a temporary git repository built in the
  test.
- `grasp`: a committed fixture `index.json` generated from the sample app.
  `Phoenix.LiveViewTest` covers: clicking a call opens the callee to its right, clicking it
  again focuses the card already there, the same function reached from two callers being one
  card with two edges, closing a card and closing a chain, opening a caller to the left,
  palette search and Enter, the diff toggle,
  and a comment saved under a line, answered and resolved. `Grasp.Session` has a persistence round-trip test. MCP is
  tested as JSON-RPC over `/mcp` with `Phoenix.ConnTest`: initialize, tools/list, then
  `set_cards` followed by an assertion that the LiveView re-rendered.
- CI: GitHub Actions on Elixir 1.20 / OTP 29 for both packages: format check, compile
  with warnings as errors, tests.

## Milestones

1. Repo scaffold and `grasp_index` steps 1 to 3 and 6: definitions, calls, JSON. Run it
   on a real Phoenix project. Done.
2. Viewer: load the index, card graph with click-to-open, highlighting, palette. Done.
   - Milestone 2.1 went back over the viewer: Lumis highlighting with the `github_light`
     theme, the GitHub Light palette and denser 60rem cards, per-card layout offsets in
     the session, and a canvas that pans, zooms, drags cards and draws its own
     connectors. Routers and entry points are unchanged — they remain milestone 3.
3. Entry points: index step 4 and the sidebar. Done.
   - The sidebar now starts from entry points rather than from the module list, cards
     carry an entry badge, and the join keeps a template's calls into the project as
     hidden calls, so a controller reaches its context through its template. Route
     pipelines are the one thing step 4 set out to carry and could not.
4. MCP tools and the chat panel: read tools, `find_paths`, card tools with highlights,
   Streamable HTTP at `/mcp`, and the in-viewer agent runner. The agent proves the
   arrangement loop before PR mode and tours build on it.
5. PR mode: base ref extraction, change badges, Changes sidebar, diff view, `list_changes`.
   Done, then groups and semantic zoom (5.1, 5.2), selection (5.3) and, in 5.4, review
   comments with the agent's edit mode, frames that follow their cards, and the far-zoom
   retune; 5.5 opens a pull request from the chat (`gh pr checkout` in place, rebuild
   against the base, `reload_index`, one group per flow); 5.6 the bottom toolbar, manual
   signature mode and group drag; 5.7 the changes-only diff; 5.8 `publish_comments` and
   `mix grasp.serve` from the reviewed project (the viewer's own task becomes
   `mix grasp.viewer`).
6. Sessions on disk: persistence of the forest and its groups, a session menu, saved
   sessions listed by `list_sessions`. Tours (the former milestone 7) were dropped.
   - Milestone 6.1 makes HEEx code the graph knows: component tags are clickable calls,
     `embed_templates` files are records, `render` reaches its template.
   - Milestone 6.2 turns the canvas into a whiteboard: absolute positions, the hook places
     a new card beside its opener, nothing else moves; session files move to version 2.
   - Milestone 7.1: ranged comments — drag along the line numbers, `end_line` on a thread,
     multi-line review comments on GitHub.
   - Milestone 7.2: interpolations are code — a call written in `{…}` or `<%= … %>` inside
     a `~H` body or a `.heex` file is a clickable call, placed by name where the compiler
     reports no column.
   - Milestone 7.3: routes are edges — `href`, `hx-*`, form actions and `~p` sigils resolve
     against the router to calls of kind `route`, drawn dashed to the controller action or
     LiveView they reach.
   - Milestone 7.4: the chat panel — Markdown with highlighted fences and links to cards,
     token streaming, working state, folded tool rows with labels and durations, a growing
     prompt box with a queue and suggestions, sticky scrolling, inline failures with Retry,
     copy buttons.
   - Milestone 7.5: jobs are edges — a `Worker.new/1` in front of an `Oban.insert` is a
     dashed hop to the worker's `perform/1`, carrying the queue it runs on; the canvas lays
     each section out clear of the other sections' frames, so the frames come out a gap apart
     instead of interleaving; the zoom reaches 5%; Alt and drag carries a whole flow; `?`
     opens the keys-and-gestures list.
   - Milestone 7.6: an update resolves every record — the document carries each record's
     route sites and the call an enqueue edge stands for, so a route or a worker that
     appears or goes moves the edges of a function whose file nothing recompiled.
   - Milestone 7.7: `h` `j` `k` `l` walk the graph beside the arrows, `z` folds and `/`
     opens the palette; a callee lands in the clear spot nearest its call site; edges are
     drawn over the cards rather than under them; `@decorate` joins the attributes a
     definition's span starts from.
   - Milestone 7.8: a card that grows pushes the cards it would cover down by the amount it
     grew, and the cards those run into after them, in one `move_cards`; a card that shrinks
     back gives that room again, newest push first, and only while the cards it pushed are
     still where the push left them.
   - Milestone 7.9: module clusters — inside each flow the cards of one module are framed
     together under the module's name, the toolbar's `modules` toggle and the `m` key draw the
     frames or drop them, dragging a label carries every card of the cluster, and a card whose
     module already stands in its flow lands beside that cluster and clear of the frames of the
     modules and the flows it is not in.
7. In-app Grasp: one dev dependency mounted in the host's endpoint, the tracer riding the
   host's code reloader for incremental indexing, pull requests reviewed from worktrees
   (see [Part 4](#part-4--in-app-grasp)).
8. README for strangers, CI, editor links, polish.

## Verification

- `mix grasp.index --base main` in a Phoenix project produces `.grasp/index.json`; a
  known chain (controller action to context to `Repo`) resolves with ranges.
- `mix grasp.serve` at http://127.0.0.1:4040: click through a four-deep chain, open a
  second branch from the same card, Cmd+K to a function, toggle diff on a modified
  function.
- From Claude Code with the MCP registered: `set_cards`, watch the browser
  update live, reload the page and confirm the session file restored it.
- Both packages pass `mix format --check-formatted`, `mix compile --warnings-as-errors`
  and `mix test`.
