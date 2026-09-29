# Indexing

The index is the call graph everything else reads: the canvas draws it, the palette searches
it, and the MCP tools answer from it.

## What the index holds

```
mix grasp.index [--out PATH] [--base REF] [--build-path PATH] [--no-tests]
```

The task forces a full recompile with a compiler tracer attached, so every call the compiler
resolves is recorded with the position of the call in your source. Those calls are then
joined with the function definitions Sourceror finds, and the result is written as one JSON
document.

Because the calls come from the compiler rather than from a text search, resolution is exact:
an alias, an import and a fully qualified name all reach the same function, and a call through
a default-argument arity resolves to the definition that carries it. A call the compiler
reports at a position nothing in the source can be clicked — code a macro generated, or a
call in an interpolation the extractor could not place — is kept as a *hidden call*, so the
callers and callees graph stays complete even where nothing is clickable; the card lists
those under "Also calls".

The document also lists the project's **entry points** — the places its code starts
executing. After compiling, the task loads the application's modules and reads what they
export and what behaviours they declare:

- Phoenix routers, by their `__routes__/0`, give a route per controller action and a live
  route per LiveView route, with the verb, path, router and helper as meta; a router mounted
  with `forward` has the mount's prefix on its paths.
- `Oban.Worker` gives `perform/1` with its queue and max attempts.
- `Phoenix.LiveView`, `Phoenix.LiveComponent`, `GenServer`, `Supervisor`, `Application` and
  `Plug` give the callbacks their behaviour declares, minus the few that configure a module
  rather than run its work.

A callback is listed only when the index holds a definition for it, so the defaults
`use GenServer` injects and a dependency's forwarded controllers stay out. Each module record
also carries the behaviours it declares, and its `@moduledoc`, read from source: the text of
a string, heredoc or `~S`/`~s` sigil, whether it is `@moduledoc false`, and the attribute's
lines. In a build against a base ref the moduledoc is compared with the base's, as a
function's source is.

**Templates are records.** A file an `embed_templates` pattern matched is a record of its own,
with the template path as its file and the whole file as its source, and the component tags
inside it are call sites. A component tag in a `~H` body is a call site the same way. A call
to `Phoenix.Controller.render/2,3` in a module named `…Controller`, whose second argument is
a literal atom or string, retargets at the `…HTML.<name>/1` record, so a route reads through
its action and its page into the contexts underneath.

**Interpolations are code.** The body of every `{…}` — in a tag body or an attribute value —
and of every `<%= … %>` or `<% … %>` expression tag is parsed at its position in the file, so
a call written inside one is a clickable call site over the callee, both on a `.heex` record
and on the card holding a `~H`. The compiler reports a `{…}` call with a line and no column,
and such a call is placed on the first site on that line with the same name and arity whose
written module, where the source spells one out, ends the target module. Two caveats follow
from that: a body that is not a complete expression on its own is parsed once more with an
`end` appended and otherwise yields no site, and two identical calls on one line are handed
their sites in document order rather than by what each one computes.

**Routes are edges.** A template that links to a page names a route, and the route names the
controller action or LiveView the router maps it to, so the hop over HTTP is a call site like
any other. The attributes read are `href`, `action`, `navigate`, `patch` and the htmx verbs
`hx-get`, `hx-post`, `hx-put`, `hx-patch` and `hx-delete`. An `hx-*` attribute carries its own
verb; `href`, `navigate` and `patch` are GET unless the tag writes a literal `method`, which
`<.link method="delete">` does; a form `action` takes the tag's literal `method` where it has
one, POST on a component tag (`<.form>`) and GET on a plain `<form>`. A `~p`
sigil is a GET route wherever it is written — as an attribute value, in an interpolation or in
a function body — so a controller's `redirect(conn, to: ~p"/greet/bob")` reaches the action
that path belongs to. Paths are matched against the router's routes segment by segment, an
interpolated segment matching any one of them, and the most specific route wins: `/users/new`
over `/users/:id`, and a `:param` over a `*glob`.

The path has to be written where the scanner can read it. One held in an assign
(`href={@path}`) or built by a helper names no route, and neither does an absolute URL, a
protocol-relative `//host/path` or a bare `#fragment`. Attributes are read on the tag that
carries them, so an `hx-post` a parent element passes down by htmx inheritance reaches no
route.

**Jobs are edges.** Queueing an Oban job is a hop of the same sort. `Worker.new(args)` is a
call to a `new/1` no source file defines, so on its own it reaches nothing; the work it sets
in motion is `Worker.perform/1`. A call to `new/1` or `new/2` on a module whose `perform/1`
the index lists as an Oban worker is redirected there, carrying the worker and the queue it
runs on, so the function that queues the job is a caller of the job and the call site is a
hop to follow. The entry points are what say which modules are workers: a worker that writes
a `new/1` of its own is followed all the same, and a `new/1` on anything else is left as the
call it is. A job queued in a way that names no worker where the call is written — an
`Oban.Job.new/2` with a `worker:` option, a changeset built elsewhere and handed to
`Oban.insert_all/2`, a worker module held in a variable — is not followed.

`--base REF` classifies every function against the merge base of `REF` and `HEAD` — added,
modified, unchanged or removed — and carries the base version of each modified function's
source. That is what turns the canvas into a pull-request review; see
[Pull requests](pull-requests.md).

## Where the file lives

`.grasp/index.json` under the project root, or wherever `--out` and `config :grasp,
index_path:` name. The viewer watches that path: rewrite the file and the canvas redraws over
the new code. It is derived from the checkout, so it belongs in `.gitignore`.

## The first build

The first index is a full build, and that is the only one you have to ask for. It is also the
slow one — a full recompile of the project.

The forced recompile happens in a build directory of Grasp's own, `_build/grasp`, seeded by
copying the project's current build the first time it is missing, so it neither waits on the
dev server's build lock nor invalidates the beams the server is running. `--build-path` names
another one; naming the project's own runs the build in place.

The seed is a copy, and it is taken once. A dependency rebuilt in `_build/dev` afterwards is
not copied across again — the forced recompile refreshes the project's own modules, not the
dependencies underneath them. Delete `_build/grasp` to take a fresh seed.

A project that fails to compile aborts the task with the compiler's own error. A single file
that cannot be read or parsed is reported and skipped; only its definitions are missing.

## Tests

A project with test paths — its `:test_paths`, or `test/` when it has that directory — has
its tests indexed too. Every `test` block with a body, every `setup` and `setup_all` block,
every function a test module defines, and every function of a support module the test build
compiles — an `.ex` file under the test environment's `elixirc_paths` and outside the dev
environment's, such as `test/support` — is a record, with the calls its body makes as edges. A test's id is its
module and ExUnit's compiled name, quoted: `SampleAppWeb.GreetControllerTest."test greet/2
says hello"/1`; its record carries a `test` field with its `describe`, its name as written and
its `@tag` names, and the document's `project.test_paths` names the test environment's test paths.

A request a test makes is a route edge: `get(conn, ~p"/greet")`, `post(conn, "/bonuses",
params)` or `live(conn, "/greet/live")` — a `get`, `post`, `put`, `patch`, `delete`, `head`,
`options`, `live` or `visit` whose second argument is a literal path — reaches the action or
LiveView the router maps that path to, so an interface-level test reads through the route
into the code it drives. The call counts when it is local, imported, or made on a module
whose name ends in `Test`, as `Phoenix.ConnTest` does; `Map.get(params, "/")` names no route.
With `--base`, a test file the branch touched is classified like any other source: its tests
are added, modified, unchanged or removed.

Test files compile only in the test environment, so the tests are traced by a subprocess:
`MIX_ENV=test mix run --no-start` over a script Grasp ships, which compiles the project's
test build, puts Grasp's compiled beams on the path, and requires the test-only support files
and the test files `mix test` loads with the tracer installed. Those are chosen as `mix test`
chooses them, from the test environment's `:test_paths`, `:test_pattern` and
`:test_load_filters`, so a fixture project a load filter keeps out of `mix test` is kept out
of the trace too. No test runs, and `test_helper.exs` is not loaded. The host adds nothing
when its test files compile without `test_helper.exs`: Grasp stays a dev-only dependency.

- **`_build/grasp_test`** is the trace's build directory, so a `mix test` in another
  terminal is never compiled under. The first time it is missing it is seeded by copying
  `_build/test`, when there is one; delete it to take a fresh seed. A pull request's
  worktree seeds its own from your `_build/grasp_test`, or your `_build/test`.
- **The first run compiles the test dependencies** when there is no `_build/test` to seed
  from, and prints only `grasp: tracing tests (MIX_ENV=test)` until it finishes, since its
  output is kept back to report a failure with.
- **A trace that fails** — a test file that does not compile — prints the last 40 lines of
  the subprocess's output after `grasp: tests not indexed:` and leaves the application
  indexed: the index is written without tests, never not at all.
- **A test file that needs `test_helper.exs` to compile fails the trace.** A test file that
  `use`s, `import`s or otherwise needs at compile time something `test_helper.exs` defines or
  `Code.require_file`s cannot compile without it, and one file failing leaves every test out
  of the index.
- **`--no-tests`** leaves the tests out.
- **Tests refresh on a full build only.** The code reloader never compiles a test file, so a
  test edited while the viewer runs keeps its record until the next `mix grasp.index`.
- **Tests a macro other than ExUnit's defines** — a property-based `property`, a project's own
  test macro — have no record unless the macro expands to a `test`.

## Live reindexing

Once Grasp is running in your dev server it installs the same tracer into the VM's compiler
options, so every compile your code reloader performs after a save reports its calls too.
A third of a second after the last one, Grasp re-extracts the files the compile touched,
rebuilds their records, recomputes entry points from the modules now loaded, resolves every
record in the document against those entry points — so a route or a worker that appears or
goes moves the edges of a function whose file nothing recompiled — reclassifies the changed
files against the base commit the document records, writes the document back and reloads the
store. Cards follow a save within a second or two, with no `mix grasp.index` run.

What that path cannot see is what the full build is for:

- a compile that happened before Grasp started;
- a change to which files are compiled at all;
- a branch switch, a new `--base`, a dependency;
- a Grasp upgrade: a document written by an earlier Grasp carries no inputs for the edges a
  later one derives, so the first build after an upgrade has to be a full one; a route or a worker
  added afterwards reaches every record on the next save.

A batch naming more than fifty project files is a rebuild rather than a save: the reindexer
says so and leaves the index to `mix grasp.index`. Reindexing also pauses, once and with a
line saying so, while the loaded index is rooted in a pull request's worktree, since your
dev server's compiles describe a different tree.

## What is not indexed

The join is only as complete as the definitions the extractor finds, and a tracer event whose
caller has no definition record is dropped.

- **`defimpl` and `defprotocol` bodies.** The extractor walks `defmodule` only, so the
  functions inside a protocol or an implementation get no definition record.
- **Definitions nested under a control structure.** A `def` written inside `if`, `for`, `case`
  or `quote` in a module body is invisible to the extractor for the same reason.
- **Macro-generated functions.** A function a `use` injects has no source of its own to
  extract. The one exception is `embed_templates`, whose functions have a source: the template
  file.
- **Only the `…Controller` → `…HTML` convention is followed.** A controller that `put_view`s
  another module, or renders through `Phoenix.Template.render/4` or `render_to_string`, is not
  linked to its template.
- **A template's diff is the whole file**, since a template has no smaller unit, and a deleted
  template is not reported as removed.

## The loopback guard

Grasp serves every indexed function's source, and in edit mode drives an agent that writes
files. `Grasp.Plug` therefore guards its whole mount: `GraspWeb.Plugs.LocalOnly` checks the
`Host` the request was addressed to and the `Origin` the browser declares, for the page, its
assets and the MCP endpoint alike.

That stops a page on another origin from reaching Grasp through DNS rebinding — binding the
dev server to `127.0.0.1` alone does not, since a domain whose DNS resolves to `127.0.0.1`
becomes same-origin with the server.

It does **not** stop a peer that sends `Host: 127.0.0.1` itself. A dev server bound to every
interface — a container, WSL, a `0.0.0.0` bind — exposes every indexed function's source, and
in edit mode an agent that writes files, to anyone on that network. The bind address is the
host application's choice; Grasp inherits it.

One more thing nothing checks: `grasp "/grasp"` in the router and `plug Grasp.Plug,
at: "/grasp"` in the endpoint must name the same mount. Change one and you get a partly
unguarded page, or an agent pointed at a 404.
