# Grasp — tests on the canvas

Grasp draws the functions of a project and the calls between them. A project's tests are
functions too, and reviewing them — or writing them with an agent — asks the same questions
of the same graph: what does this test exercise, which tests reach this function, which of
the lines a change touched did anything run. This document extends the Grasp design
(`2026-09-15-grasp-design.md`) with tests as records, the edges from tests into the code,
the coverage and results of a run, and the MCP tools an agent reviews and writes tests
with. Everything the main design says about records, edges, cards, sessions and the index
holds for test records unless this document says otherwise.

## Decisions

- **Tests are records in the one index.** A `test` block, a `setup` or `setup_all` block
  and every function a test module defines is a function record of `.grasp/index.json`,
  with the calls its body makes as edges, exactly as an application function is. One
  document keeps callers, callees, search, the palette, sessions and the agent's tools
  working on tests with no second store.
- **The test trace runs in the test environment, without Grasp as a test dependency.** Test
  files compile only under `MIX_ENV=test`, against dependencies a host declares for tests
  alone, and Grasp is a dev-only dependency. The full build therefore starts one extra
  subprocess, `MIX_ENV=test mix run --no-start`, which compiles the project before Grasp's
  own compiled beams — the `ebin` of the `grasp` the indexing session runs — are prepended to
  its code path, then has the tracer installed and the test files required without running a
  test. The host changes nothing when its test files compile without `test_helper.exs`.
  Measured on a 258-file suite: 15 s, 115 000 events from 6 600 test-side functions.
- **Coverage and runs use the host's own `mix test`.** Grasp never runs a test itself: it
  runs the host's test command, so the suite runs with the host's configuration, database
  and environment. Coverage is Mix's own cover export, which `mix grasp.cover` reads in a
  process of its own; results are written by Grasp code loaded into the run, a formatter on
  Grasp's beams put on the path the same way. The viewer reads both back.
- **Static first.** Test records, their edges and "tested by" need no test run and ship
  first; coverage and results are layers over the canvas that a run brings and a later run
  replaces.

## Test records (milestone 10.1)

### The trace

`mix grasp.index` traces the tests after it has traced the application, whenever the
project has test paths — its `:test_paths`, or `["test"]` when it has a `test` directory,
as `mix test` defaults them; `--no-tests` skips it. The dev indexer starts the test
trace as a subprocess:

```
MIX_ENV=test MIX_BUILD_PATH=_build/grasp_test \
  mix run --no-start priv/test_trace.exs EVENTS_FILE GRASP_EBIN DEV_PATHS CANDIDATES
```

`EVENTS_FILE` is where the script writes what it traced, `GRASP_EBIN` the `ebin` directory
of the `grasp` the indexing session runs, `DEV_PATHS` the dev environment's
`elixirc_paths`, joined by commas, and `CANDIDATES` a file holding the paths under the test
paths that the base commit has and the tree does not (see §Base ref). The test
environment's test paths, as the script reads them, are written to the document as
`project.test_paths`.

- `_build/grasp_test` is seeded from `_build/test` the first time it is missing, as
  `_build/grasp` is seeded from `_build/dev`, so a dev server and a `mix test` run are never
  compiled under. `mix run` compiles the project before the script starts, with no tracer
  installed and Grasp absent from the code path, so an unchanged tree compiles nothing and
  the test build is the one `mix test` compiles: a host's `Code.ensure_loaded?(Grasp.Router)`
  guard reads false there.
- The script is a file Grasp ships in `priv/`, run by path. It prepends `GRASP_EBIN` — the
  only directory it needs, since extraction runs in the parent — to the code path, installs
  `Grasp.Index.Tracer`, sets `ignore_module_conflict: true`, starts ExUnit with
  `autorun: false`, and requires, with `Kernel.ParallelCompiler.require/2`, the test-only
  support files — the `.ex` files under the test environment's `elixirc_paths` that lie
  under none of `DEV_PATHS` (`test/support`) — and then the test files `mix test` loads.
  Nothing is run: requiring a test file defines its module and registers its tests with an
  ExUnit that never starts a run. `test_helper.exs` is not required, since it starts
  repositories and sandboxes the trace does not need.
- The test files are selected as `mix test` selects them, from the test environment's
  project config by `Grasp.Index.TestTrace.test_files/2`, which runs in the script because a
  load filter may be a function only that session can call. `:test_paths` defaults to
  `["test"]` when the project has a `test` directory; every file matching `:test_pattern`
  (default `"*.{ex,exs}"`) under a test path, and a test path that names a file, is a
  candidate; a candidate is loaded when one of `:test_load_filters` (default a path ending
  in `_test.exs`) matches it — a path it equals, a regex it matches or a one-arity function
  answering true. `:test_ignore_filters` take no part: `mix test` loads a file a load
  filter matches whether or not an ignore filter matches it too, and consults the ignore
  filters only to decide which of the files left over it warns about. A project keeping
  fixture projects under `test/` therefore keeps them out of the trace with the load filter
  that keeps them out of `mix test`.
- The script writes the events whose file is one of those it required, the list of those
  files, the test paths and the `CANDIDATES` that `mix test` would load were they on disk,
  as `:erlang.term_to_binary/1`, to `EVENTS_FILE`, and exits. The parent reads
  them and joins the events with what Sourceror extracts from the same files, as the
  application's are joined. A test trace that fails leaves the application's records
  written: the index is the application's with no tests, never no index. A test file that
  does not compile is reported with the last 40 lines of the subprocess's output, after
  `grasp: tests not indexed:`, which end with the compiler's error. A `grasp` loaded from no
  `ebin` the test session could read is caught by the parent before any subprocess starts,
  and reported as `grasp: tests not indexed: no compiled grasp to load into the test
  environment (looked for Elixir.Grasp.Index.Tracer.beam in the ebin of …)`.
- In PR mode the worktree's `_build/grasp_test` is seeded by `Grasp.PullRequest` from the
  host's `_build/grasp_test`, or its `_build/test` when it has none, as its `_build/grasp`
  is from `_build/dev`, so the first trace of a pull request compiles the project rather
  than every test dependency.

### Extraction

`Grasp.Index.Extract` reads a test file as it reads any Elixir file, and additionally
recognises ExUnit's blocks inside a module:

- `test "name"` with a body (with or without a context argument), inside or outside a
  `describe`, is a definition of kind `:test`. Its compiled name is ExUnit's,
  `:"test <describe> <name>"` (`:"test <name>"` outside a `describe`), cut to ExUnit's own
  length limit, arity 1, which is the function the tracer names as the caller of every call
  in its body. Its span runs from any `@tag`, `@describetag` or `@moduletag` attribute and
  leading comment attached to it through its `end`. A pending `test "name"` with no body,
  and a test whose name or whose describe's name is not a literal string, contribute no
  definition.
- `setup` and `setup_all` blocks are definitions of kind `:setup`, arity 1, named by
  ExUnit's counters: `:"__ex_unit_setup_<n>"` and `:"__ex_unit_setup_all_<n>"`, where `<n>`
  counts every callback registered before it in the module — a `setup :name` and each entry
  of a `setup [...]` included — and `:"__ex_unit_setup_<d>_<n>"` for a `setup` inside a
  `describe`, where `<d>` is the describe's position among the module's describes and `<n>`
  counts that describe's callbacks alone. A `setup :name` naming a function adds no
  definition of its own, the named function being a definition already.
- A `describe` contributes no definition. Its name is carried on every test inside it.

A test record carries, beside what every record carries:

```jsonc
"kind": "test",
"test": { "describe": "create/2" /* or null */, "name": "redirects to the new bonus",
          "tags": ["slow"] }
```

### Ids

A test's id is `Module."compiled name"/1` — the module, a dot, the compiled name as an
Elixir quoted atom, `/1` — as in `SampleAppWeb.GreetControllerTest."test greet/2 says hello"/1`.
It is unique, readable and what a stacktrace prints. Code that needs a record's module reads
the record's `module` field rather than parsing an id, since a test name may hold any
character; the card's `data-module` for clustering is the record's module.

### Routes from tests

A test reaches a controller through a path, not a call: `get(conn, ~p"/greet")`,
`post(conn, "/bonuses", params)`, `live(conn, "/greet/live")`. `~p` sigils already produce
route sites. A call named `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `live`
or `visit` whose second argument — the first written, when the call is piped into — is a
literal string or `~p` sigil is a route site too, with the verb the name gives (`live` and
`visit` are GET), replacing the GET the `~p` it holds would read as, and
`Grasp.Index.Routes` resolves it like any other. The call counts when it is local or
imported, or remote on a module whose last alias segment ends in `Test`
(`Phoenix.ConnTest`, `Phoenix.LiveViewTest`, a project's own `*Test` helper); a remote call
on any other module (`Map.get(params, "/")`, an HTTP client's `get`) is not a request, and a
path held in a variable makes no site. So an interface-level test draws the chain it drives:
test, route, controller action, context.

### Base ref

In PR mode the base side of every changed test file is extracted like any changed source
file, so test records are added, modified, unchanged or removed against the base, and a
modified test has a diff. The base is read under the test paths the dev environment's
project config names (default `["test"]`), for every changed `.exs`, `.ex`, `.heex` and
`.eex` file there. Under the test environment's test paths only two kinds of file are then
compared: a file the test trace read — a test file `mix test` loads, or a test-only support
file — and a file the base has and the tree does not that `mix test` would load were it on
disk. The script answers the second for the paths the parent sends it as `CANDIDATES`: it
lays each out, empty, in a scratch directory and selects there with the same function, so
the pattern is matched as `Path.wildcard/1` matches it and a function filter is called
where it is defined. So a fixture project's files, a test file a load filter leaves out and
a file the test build never compiles have no base functions to read as removed, and a test
file the branch deleted reads as removed. A trace that fails leaves every file under the
test paths uncompared.

### Viewer

- A test card wears a `test` badge and titles itself with the test's name, its `describe`
  — or its module, outside any `describe` — in the header's module slot, and no arity; a
  setup card wears `setup` and is titled `setup` or `setup_all` under its module.
- In signature mode a test card shows its name and, under it, its assertions in place of
  its body, so a zoomed-out canvas reads what each test promises. An assertion is found by
  parsing the test's source: every call named `assert` or `refute`, or whose name starts
  with `assert_` or `refute_`, written as a local or imported call or as the right-hand side
  of a `|>`. Each is shown over the full range of lines it spans — a piped one from the line
  its pipeline starts on — highlighted as code, in source order, with overlapping ranges
  merged. A source that does not parse shows no assertions, and the card its title alone.
- The sidebar has a **Tests** group, after the entry points and before the modules,
  listing test modules by file, each opening into its setup callbacks, then its tests,
  grouped by `describe`, and then the helpers it defines. One test module is open at a
  time, apart from the module open in the Modules group. A module is a test module when it
  holds a test or a setup record, or when its file lies under the project's `test_paths` —
  a case template, a factory — and no test module is listed among the modules under review.
  Clicking a test opens its card as a root. The palette finds tests by the words of their
  module, `describe` and name, and a hit wears the badge its card does.

### Known gaps

- **A test file that needs `test_helper.exs` to compile fails the trace.** `test_helper.exs`
  is never loaded, so a test file that `use`s, `import`s or otherwise needs at compile time
  something `test_helper.exs` defines or `Code.require_file`s cannot compile in the trace,
  and one failing file leaves every test out of the index.
- **The base is read under the dev environment's test paths.** They are needed before the
  trace names the test environment's, so a project whose `:test_paths` differ between the
  two environments leaves the files under a path only the test environment names
  uncompared.

- **Test records refresh on a full build only.** The reindexer follows the code reloader,
  which never compiles a test file, so a test edited while the viewer runs keeps its record
  until the next `mix grasp.index`.
- **Tests defined by a macro other than ExUnit's** (a property-based `property`, a
  project's own `test_with_x`) are traced — their calls are events like any other — but have
  no definition to join to unless the macro expands to a `test`, and their calls land as
  hidden calls of nothing.
- **A support file the branch deletes outright does not read as removed.** The base side of
  the test paths is narrowed to the files the test trace required and the deleted files
  `mix test` would load, and a deleted support file is neither, so its functions vanish from the index without a
  `removed` record.
- **A cold first test trace prints only its start line until it ends.** The subprocess's
  output is captured so that a failure can be reported with it, so compiling the test
  dependencies into a fresh `_build/grasp_test` shows `grasp: tracing tests (MIX_ENV=test)`
  and nothing more until the trace finishes.
- **A `@moduletag` or `@describetag` joins the span of the block that follows it.** Both are
  attached attributes, so the test or setup written after one starts its span, and its
  source, at the tag, although the tag applies to every test of the module or `describe`.
- **An assertion written through a remote helper is not shown in signature mode.**
  `Helpers.assert_ok(x)` is a remote call, and only local, imported and piped `assert`,
  `refute`, `assert_*` and `refute_*` calls are read as assertions, so a test asserting only
  through such a helper shows its title alone.

## Tested by (milestone 10.2)

- **Reach.** `Grasp.Index.tests_for(index, id, max_hops \\ 4)` answers the tests that reach
  a function: a breadth-first walk backwards from it over the callers the index already
  holds — every resolved call, `route` and `enqueue` edges included — through any record,
  visiting each once, for up to `max_hops` hops, collecting each test met at its shortest
  distance, as `[%{test: id, hops: n}]`, nearest first and then by id. A test calling the
  function directly is one hop away. A setup met on the way counts for every test of its
  module, at the setup's distance, unless that test is nearer by another path. A removed
  test or setup runs nothing, so it is never collected and credits no test. An id the index
  does not define answers `[]`. Walking back from the few functions a reader looks at is
  cheaper than walking forward from every test on every index load, and answers the same
  question.
- **Card.** A function card reached by any test wears a `n tests` badge in its header, and
  the badge opens the callers menu. The menu gains a Tests section listing them, nearest
  first, each row titled by its `describe` and name and marked `direct` or `n hops`. A test
  one hop away opens as a caller does; a farther test opens the path to it — the records of
  a shortest backward path of calls (`Grasp.Index.path_back/4`), each opened as a caller of
  the next, so every edge the canvas draws is a call; a folded card on the path unfolds. A
  test reached nearest through its module's setup opens the path to the setup; one met at
  the same hop as such a setup opens its own path. A test or setup card, and a card no test
  reaches, wears no badge. The canvas walks again only when the index's generation or the
  set of functions on the canvas differs.
- **PR mode.** A changed application function is one the branch added or modified that is
  not a test or a setup and lies outside the project's `test_paths`; a removed function has
  no body for a test to reach and is never one. In the Changes group every changed
  application function no test reaches within four hops is marked `untested`, and an
  **Untested changes** group lists them, open whenever it has any. Under each changed
  application function the Changes group lists the added or modified tests that reach it,
  nearest first, so code and tests changed together read as pairs; a row opens the test's
  card as a root. Both answers are computed once, when the index is built from its
  document, so every render of the review reads them as they stand (`Index.untested_changes/1`,
  `Index.changed_tests/2`).
- **MCP.** `tests_for(function_id, max_hops)` — `max_hops` from 1 to 8, default 4 —
  answers `%{"id", "tests"}`, each test with its `id`, `name`, `describe`, `file` and
  `hops`. `untested_changes()` answers `%{"functions"}`, each with its `id`, `file` and
  `change`; it is empty for an index built without a base ref. The agent's system prompt
  names both for questions about tests.

### Known gaps (milestone 10.2)

- **Reach is static.** A test that reaches a function only through a dynamic call —
  `apply/3`, a function passed as a value, a behaviour dispatched at runtime — or through a
  test double is not counted.
- **Reach stops at four hops.** A function further than four call edges from every test
  reads as untested, and its card wears no badge.
- **A setup credits every test of its module.** A test that reaches a function only through
  its module's setup is counted for every test of the module, whether or not that test's
  own body needs the function.

## Coverage (milestone 10.3)

- **Run.** `mix grasp.cover [--out PATH] [--index PATH]` runs the host's test command —
  `:grasp, :test_command`, default `["mix", "test"]`, in the project root with
  `MIX_ENV=test` over the environment the task itself was started with — adding `--cover`
  and `--export-coverage grasp`, so the suite runs exactly as the host runs it and Mix's own
  cover tool counts the lines. The suite's output streams to the terminal. The export lands
  where the host's `:test_coverage` config puts it — its `:output` directory, `cover` unless
  set, named by its `:export` when it sets one, in which case no `--export-coverage` is
  added. An export an earlier run left there is removed before the suite starts, so the
  document never describes another run. A run whose tests fail still exports what ran: the
  task reports the exit status and writes the coverage; a run that leaves no export aborts
  the task. The task then loads `:tools`, imports the export with `:cover` in its own
  process — analysis of imported data needs no cover-compiled module, so Grasp is never
  needed in the host's test environment — and writes the document to `--out`, by default
  `coverage.json` beside the index (`--index`, else `:grasp, :index_path`, else
  `.grasp/index.json`). The task refuses when the index cannot be read, when `:cover` is
  already running in its VM, and at an umbrella root, whose apps each export their own
  coverage, saying to run it inside the app.
- **The coverage document** holds, per indexed application function, the `:cover` counts on
  the lines of its span, keyed by offset from the span's first line (a line `:cover` does
  not count is absent), and a sha256 of the record's `source` as the index held it when the
  coverage is written, beside the time it was written, the git head and the index's
  `generated_at`. Removed records, tests, setups and every record in a file under the
  project's `test_paths` get no entry, and neither does a function with no counted line. A
  function that moves in its file with its source unchanged keeps its counts, read on the
  lines it occupies; a function whose current source hashes differently reads as stale: its
  counts describe a body other than the one the record holds. Macros and guards get no
  entry: their bodies run when their callers compile, before `:cover` starts. A record's
  `source` is its whole span, which starts at its `@doc`, `@spec` and leading comments, so
  editing only those marks it stale. The document is written to a file beside its path and
  renamed over it, so a reader never sees one half written.
- **Whose code it describes.** The coverage describes the reader's own checkout and its
  suite: the counts come from the beams the suite compiled from the files in the task's
  project root. After the run the task keeps a record's entry only when its `source` equals
  the text of its `file` under the task's project root at `span.start_line..span.end_line`,
  joined as extraction joins it; a record whose file is missing there or differs gets no
  entry, and the task prints one line counting the records it skipped. The index's own
  `project.root` is not consulted, so while a pull request's index is loaded only the
  functions the pull request leaves as they are read fresh, counted by the checkout's tests,
  and the functions it changes get no entry; an index behind the files keeps only the
  functions it holds as they are on disk.
- **Attribution.** `:cover` counts by module and line, and a module can hold code whose lines
  are another file's. Each count goes to the one compiled function whose code carries that
  line, read from the debug info of the test build's beam, and a record takes the counts of
  every arity it defines that lie inside its span. Code the compiler marks as another file's
  (`@file`, `quote location: :keep`, templates embedded from their files) is never counted
  by `:cover`; a line carried by more than one function — a template compiled from a string
  whose lines overlap the module's own, a head whose default arguments every arity carries —
  is credited to none of them; and a module whose beam has no readable debug info
  contributes nothing. An uncounted line is untinted, so an ambiguity costs a tint, never a
  wrong one.
- **Loading.** The viewer watches the document as it watches the index, polling its mtime
  every two seconds, and reloads it when it changes. The path is `:grasp, :coverage_path`,
  else `coverage.json` beside the index the viewer reads. A missing file is no coverage,
  not an error; a file that cannot be read or decoded keeps the previous document and is
  logged once for each version of the file.
- **Tint.** The `coverage` toggle (toolbar, key `v`) is disabled while no coverage is
  loaded. While it is on, a card body tints each counted line as run or never run; an
  uncounted line stays untinted, and a stale card says `coverage stale` in its header and
  tints nothing. In a diff body only the inserted lines are tinted.
- **Clause gaps.** Extraction records, for every definition, the line range of each clause
  (`"clauses"`, from the line of its `def`, `test` or `setup` through its last line; a head
  with no body declares default arguments and is no clause) and of each arm (`"arms"`, from
  its pattern's line through its body's last line) of the `case`, `cond`, `with … else`,
  `receive` and its `after`, `try` (`rescue`, `catch`, `else`, `after`) — the same keys
  written straight on a `def`, a test or a setup included — and multi-clause `fn` in its
  body, in `do` block or keyword form. A clause or arm that has at least one counted line
  and whose every counted line ran zero times is marked `never entered` at its first line: a
  bar along the line's edge, and the words for a screen reader. A clause wins over an arm starting
  on the same line. In a diff the mark sits on the line of the current source that begins
  it, inserted or kept.
- **MCP.** `coverage(function_id)` answers `status` — `fresh`, `stale`, or `none` when the
  document holds nothing for the function or there is no document — with `run` and `missed`,
  the sorted lines run and never run, `gaps`, the clauses and arms never entered as
  `[start_line, end_line]`, and the document's `generated_at`. Only a fresh answer carries
  lines and gaps. Starting a coverage run from the viewer or the agent is part of the run
  machinery of milestone 10.4.

### Known gaps (milestone 10.3)

- **Only the project's own modules are counted.** Coverage counts only the modules Mix's
  cover compiles — the project's `elixirc_paths` in the test environment — so a function in
  a dependency has none.
- **A line `:cover` does not count stays untinted** — a bodiless head, a `do` line, a blank
  line.
- **A line two compiled functions carry is credited to neither.** A one-line function with
  default arguments, whose only line every arity carries, has no coverage.
- **Code compiled from another file is not counted.** Templates embedded with
  `embed_templates` and code a `location: :keep` macro injects are left out by `:cover`, so a
  template record and code a `use` injects carry no coverage.
- **A `case` inside a `~H` sigil adds no arm.** The walk reads Elixir, not template text.
- **Macros and guards carry no coverage.** They run at compile time, before `:cover` starts.
- **A module whose test-build beam has no debug info carries no coverage.**
- **The whole suite runs.** `mix grasp.cover` runs every test, whether it is started from
  the terminal, the runs panel's `run coverage` or `run_coverage`.
- **An edit saved while the suite runs is not caught.** The task compares the index with the
  files after the run, so an edit saved once the suite has compiled, with the index catching
  up before the comparison, keeps counts that describe the text the suite compiled.

## Runs and failures (milestone 10.4)

- **Running tests.** `mix grasp.test [TEST_ID ... | --changed | --all] [--index PATH]
  [--out PATH]` runs the host's own suite, or part of it, and records each test's result. It
  runs a script Grasp ships in its `priv`, `test_run.exs`, with `MIX_ENV=test mix run
  --no-start` in the project root over the environment the task runs in, as the test trace
  does: Mix compiles the project and settles the code path with Grasp absent from it, then
  the script prepends the `ebin` of the `grasp` the task itself runs from — a code path
  added from the command line is pruned by Mix before `mix test` would load from it — and
  calls `mix test` in the same process with the tests' `file:line` arguments and
  `--formatter Grasp.Test.Formatter --formatter ExUnit.CLIFormatter`. Those two replace the
  formatters the host configures, in its config or its `test_helper.exs`, for the run; the
  suite's output streams to the terminal. A formatter missing from that `ebin` stops the
  script before the suite runs. A test id names the record's `file` and the line of its
  `test` call, where its one clause starts, since a span starts at the attributes and
  comments above the test and `mix test` runs the test nearest at or before the line it is
  given. An id the index holds no test for aborts the task, listing every such id, and a
  `--` ends the switches, so every argument after it is an id. `--changed` runs the tests
  the index marks added or modified against its base ref, does nothing when there are none,
  and aborts for an index built without a base ref; `--all` runs the whole suite. `--index`
  defaults to `:grasp, :index_path`, else `.grasp/index.json`; `--out` to `results.json`
  beside the index. The task exits with the suite's status, and refuses at an umbrella root,
  whose apps each run their own suite.
- **Results.** `Grasp.Test.Formatter` runs in the host's test VM and calls nothing but
  Elixir's standard library. When the suite finishes — or when a SIGQUIT interrupts it,
  with the tests finished by then — it writes the run's results in the external term format
  to a run file beside the document, written beside its own path and renamed over it; a
  write that fails prints one line on stderr and the suite finishes as it would without the
  formatter, and it never raises. Per test id a result is `passed`, `failed`, `skipped`,
  `excluded` or `invalid` (a test whose module's `setup_all` failed, and any state the
  formatter cannot read, with that state inspected as its `reason`), its time in
  microseconds, and for a failure each error's kind, message and, for an assertion, its
  expression, `left` and `right` as ExUnit's CLI formatter prints them, with the stacktrace
  as `{module, function, arity, file, line}` frames, the file relative to the project root.
  The task merges the run file into `.grasp/results.json` and removes it; a run that leaves
  no run file — a project that does not compile, a suite that cannot start — aborts with the
  suite's status and leaves the document untouched.
- **The merge.** A run replaces the result of each test it names and leaves every other
  test's result as it stood, so running one test updates that test alone; an `excluded`
  result — a test the run loaded but did not run, as `mix test file:line` excludes the rest
  of its file — replaces only a missing or excluded one. Each result is stamped with the
  run's id, its finish time and the sha256 of the test's `source` as the index holds it at
  the merge; a test whose current source hashes differently reads as stale, as coverage
  does. The read, merge and write hold `results.json.lock`, a file created exclusively: a
  writer finding it polls every 100 ms for up to 30 seconds and then aborts, leaving its
  results unwritten, and a lock older than ten minutes is taken to belong to a writer that
  died holding it and is removed. The document is written to a file beside its path and
  renamed over it. A document that does not decode is renamed to
  `results.json.<timestamp>-<unique>.corrupt` beside it, so every one set aside is kept, and
  the results start again from the run.
- **Loading.** `Grasp.ResultsStore` watches the document as the coverage store watches
  coverage, polling its mtime every two seconds, and reloads it at once when a test run
  started through the viewer or the agent finishes. The path is `:grasp, :results_path`,
  else `results.json` beside the index the viewer reads. A missing file is no results; a
  file that cannot be read or decoded keeps the previous document and is logged once for
  each mtime.
- **The run machinery.** `Grasp.Runs` runs one command at a time — a test run (`mix
  grasp.test -- ID ...`) or a coverage run (`mix grasp.cover`), behind `:grasp,
  :runs_command`, default `["mix"]` — as a port on the executable found on `PATH`, given
  its arguments as argv. It runs in `:grasp, :runs_root` when that is set, and in Grasp's
  home (`Grasp.Application.home/0`) otherwise: the directory Grasp was started in, or the
  indexed project's root under `mix grasp.viewer`. It runs with the viewer VM's environment
  less `MIX_BUILD_PATH`, which would redirect the suite's build. Both tasks are given
  `--index`, the index the viewer holds, and `--out`, the document the viewer watches —
  the results document for `mix grasp.test`, the coverage document for `mix grasp.cover` —
  so a run resolves the ids the viewer checked in the index they were checked against and
  writes where the viewer reads, whatever the project's own config names. Its output, stderr merged, is broadcast a line at a
  time, each numbered by its `seq`, and a run keeps its last 200 lines. A second start while
  one runs is refused with the running one. A cancel freezes the whole process tree the port
  started, read from the parent pids `ps` lists, terminates it and continues every process
  it stopped, then closes the port; the run finishes as cancelled with no exit status. A
  cancel that lands once the program has exited signals nothing and finishes the run with
  its status. A runs server that stops takes its run with it.
- **Controls.** A test card has `run`; the callers menu's Tests section has `run all`,
  running every test it lists; the Changes group opens with `run changed tests` when the
  branch added or modified tests; the toolbar has `runs`, reading `running…` while a run is
  under way, which opens the runs panel where the chat panel floats, closing the chat, as
  opening the chat closes it. The panel names the run, says whether it is running,
  finished, failed with its exit status, or cancelled, and streams its output, each line cut
  to 4 000 characters; it has `cancel` while a run is under way and `run coverage`. While a
  run is under way every control that starts one is disabled and titled with the running
  command, and a start refused all the same shows the run under way. Starting a run opens
  the panel in the tab that started it; a run started elsewhere — by another tab or by the
  agent — changes every tab's toolbar and shows in every tab's panel once it is opened, but
  opens no panel. Keys: none.
- **Badges.** A test card wears its latest fresh result — `passed`, `failed`, `skipped` or
  `invalid` — or `stale`; an `excluded` result says nothing about the test and reads as no
  result. The tests badge on a function card adds `· m failing`, counting the tests it lists
  whose fresh result is `failed` or `invalid`.
- **A failure is a chain of cards.** A test card whose fresh result failed shows each error
  under the line the test's own frame names when that line is in the test's span, and under
  its first line otherwise — the message, an assertion's expression and its `left` and
  `right`, and the stacktrace, each frame outside the index noted — as part of the result,
  not a stored comment; it goes when the result goes stale, and a line the card does not
  draw puts the panel in its footer. When the first error's stacktrace holds an indexed
  frame above the test's own, the header has `open failure`, which lays the stacktrace out
  from the test card: each frame whose function is indexed becomes a card, opened from the
  previous one as a callee, with the frame's line highlighted, so the red test reads as the
  path into the code that failed. A frame of an anonymous function, a comprehension or an
  inlined body is read as a frame of the function it is written in; a function repeated in
  consecutive frames, as a recursion repeats one, is one card, highlighted at its deepest
  line; frames outside the index are skipped, and the panel says when a step was reached
  through them.
- **MCP.** `run_tests(test_ids | changed: true)` and `run_coverage()` start a run and answer
  at once with `started` and the run, or with `running` and the run already under way;
  every id must name a test the index holds, and nothing starts otherwise. `run_status()`
  answers `running` with the run's last 50 lines and how many it has printed, `idle` before
  any run, or `last`, the last run's exit status and whether it was cancelled with, for a
  test run, each test it named and its status in the results document — `stale` for a
  result recorded against another version of the test, `none` when the run recorded
  nothing for it — a failure carrying its first error's message, `left`, `right` and the
  deepest frame of its stacktrace in an indexed function. A test run's statuses are read
  from a results document read after the run finished: when the results store last read
  its file before the finish, `run_status` reloads it first. An MCP call does not wait for a
  suite. The chat agent in read mode is denied `run_tests` and `run_coverage` and keeps
  `run_status`: it reads a run the user started, and starts none, since a run executes the
  project's code.

### Known gaps (milestone 10.4)

- **A run replaces the host's own formatters.** `mix test` applies its command line's
  `--formatter` over the configured ones, so for a run through Grasp the terminal shows
  ExUnit's own report and nothing a project formatter adds, and a formatter that writes a
  file — a JUnit report — writes nothing.
- **A run started outside Grasp records nothing.** Only `mix grasp.test` loads the
  formatter, so a plain `mix test` leaves the results as they stood.
- **Results of tests deleted from the suite stay in the document.** A merge replaces the
  results of the tests a run names and never removes one, `--all` included; a deleted test
  has no record to wear its result, so the result is never read.
- **Two writers can lose a merge to a stale lock.** Taking over a lock older than ten
  minutes is a removal followed by a fresh exclusive create, not one atomic step, so two
  writers finding the same stale lock can both hold it, and the later write drops the
  earlier one's results.
- **A cancel does not always reach the whole tree.** A `ps` that does not take `-A -o pid=
  -o ppid=` (BusyBox's) cannot be read, and a cancel then closes the port without
  signalling, leaving the suite to run on. A VM that halts, or a runs server killed without
  running its termination, leaves the tree running too.
- **One run at a time.** A test run and a coverage run cannot run together, and a start
  while one runs is refused.
- **A frame line outside its card's span highlights nothing.** A frame whose line lies
  outside the indexed span of its function — code compiled from another file, or a function
  the index holds at other lines than the ones the run compiled — opens its card with no
  line marked.
- **An index behind the test files runs whatever test the indexed line holds.** A test id
  names the file and line the index recorded, and the dev server's reloader does not
  reindex test files, so after an edit that moves tests the line can fall in another test
  or in none. The named test then reads as excluded and keeps its previous result, and
  `run_status` answers `none` for it, while the test that did run is recorded against the
  hash of the old index's record and reads fresh until the next reindex.
- **A viewer at an umbrella root cannot run tests.** Both tasks refuse at an umbrella root,
  since each app runs its own suite, so every run such a viewer starts fails with that
  refusal. `:grasp, :runs_root` pointed at one app runs that app's suite.
- **The panel shows what the host's suite prints.** The output is the CLI formatter's and
  whatever the suite writes itself, so a noisy suite fills the 200 lines a run keeps.

## Test review (milestone 10.5)

- **Assertions compared.** An assertion is a call named `assert`, `refute`, or starting with
  `assert_` or `refute_` — local, imported or piped, as signature mode reads them, a piped
  one spanning its whole pipeline — taken from a parse of the test's source. In PR mode, for
  each modified test the assertions of its `base_source` are compared with those of its
  `source` by a canonical form of the parsed node — `Macro.to_string/1` of the node with its
  metadata and Sourceror's literal wrappers stripped — so layout, line breaks and comments
  do not count and the contents of a string do. A modified test is marked `assertion
  weakened` when:
  - the head makes fewer assertion calls than the base, with the reason
    `removed: <text>` for each assertion of the base the head makes fewer times;
  - an `assert_*`/`refute_*` name the base calls is called fewer times at the head, with
    the reason `dropped: <name>`;
  - an `assert left == right` or `assert left === right` of the base has no canonical
    counterpart at the head, and an `assert` at the head uses `=~` or `in` with the same
    `left`, holds a `match?/2` on `left`, or is a bare `assert left`, with the reason
    `loosened: <text>`.
  Reasons come in that order, each kind in the order the base makes its assertions. An edit
  that keeps the number of assertions — a different expected value, a different
  `assert_receive` timeout, a different `refute` — is not a weakening unless it drops an
  `assert_*`/`refute_*` call or loosens an equality: `assert_receive` renamed to
  `assert_received`, or an `assert_*` helper replaced by a plain `assert`, keeps the count
  and still reads `dropped:`. A reason's
  text is the base assertion's source with its whitespace collapsed. An added test with no
  assertion at all is marked `asserts nothing`. A test whose source or base does not parse
  is never marked.
- **Where it shows.** Both marks are badges, `assertion weakened` and `asserts nothing`, on
  the test card and on its row in a **Test review** group of the sidebar, after Untested
  changes; a weakened mark's `title` holds its reasons, one a line. The group lists the
  marked tests sorted by id, each row with its change and test badges and its title, opens
  on arrival whenever it has a row, and a row opens the test's card as a root. The review is computed
  once, when the index is built from its document, and only over the tests the branch added
  or modified, so an index without a base ref marks none. MCP `test_review()` answers the
  same list, each test with its `id`, its `mark` (`weakened` or `asserts_nothing`) and its
  `reasons`.
- **Doubles.** A `Mox.defmock(Mock, for: Behaviour)` — or a bare `defmock`, the options
  written bare or in brackets — names `Mock` a double of `Behaviour`. The
  declarations are read from each test path's `test_helper.exs` and every file the test
  trace read, the test-only support files and the test files, which are parsed, never run;
  their module names are expanded through the `alias` lines of the file that writes them.
  An `expect(Mock, :fun, …)`, an `expect(Mock, :fun, n, …)` or a `stub(Mock, :fun, …)` —
  local or `Mox.` remote, or piped from the mock — written in a test, a setup or any other
  function a test file defines, with a literal mock and a literal function name, is a call
  of kind `double` from that record to `fun` of every indexed application module (not a
  module under the test paths) whose behaviours include `Behaviour`: at the parameter count
  of the `fn` passed when it is a literal, at the arity of the capture passed
  (`&Impl.fun/1`), or at every arity of `fun` the implementation defines otherwise. A target
  the index holds no function for draws nothing. The call carries the mock and the behaviour
  under `double`. The `expect` or `stub` call is the site: the call the trace records for
  `Mox.expect/3`, `Mox.expect/4` or `Mox.stub/3` on the site's exact range is dropped once
  the site reaches anything. The site's first target by id holds its range, so its span
  opens that target and its edge leaves from there; that call's `double` also lists every
  implementation the site reaches, and the site is underlined with dots and titled
  `Mox double of Behaviour: Impl1, Impl2`. Every other target is a hidden call of kind
  `double` on the site's line, carrying the mock and the behaviour, listed in the card's
  **Also calls** footer, where its button opens it and its edge leaves from. A double's edge
  is dashed. Where several calls share one range, the narrowest wraps it and a `double`
  wins a tie with any other call. A double stands in for the code rather than running it, so
  a `double` call makes no caller: it is left out of `Index.callers/2` and so of the callers
  menu, `get_callers`, `find_paths`, `tests_for`, the walk back to a farther test, untested
  changes and the paired tests. A test that calls the doubled function outright as well
  still reaches it through that call. `Index.callees/3` keeps the double, since the test's
  card draws it, and leaves it out given `doubles: false`; MCP `get_callees` answers
  `callees` without the doubles and the doubles apart, as `doubles: [{target, behaviour,
  mock}]`. A double is never read as an enqueue, even on a worker's `new/1`.

### Known gaps (milestone 10.5)

- **Assertions made through a helper are invisible to the comparison.** Only calls
  written in the test are read, so moving assertions into a helper reads as removing them,
  and a test asserting only through helpers reads as asserting nothing.
- **An edit that keeps the number of assertions is not a weakening, except by the `dropped`
  and loosening rules.** Replacing a strict assertion with a looser one of a different
  shape, other than one that drops an `assert_*`/`refute_*` call or the `==`/`===` loosening
  rule, goes unmarked.
- **The canonical form reads different spellings of one literal as the same assertion.**
  `assert x == 0x10` and `assert x == 16` compare equal.
- **Some doubles draw no edge.** `stub_with/2`, a `for: [A, B]` list, a mock named through a
  module attribute or a variable, and a double made without Mox draw nothing.
- **A mock declared elsewhere draws no edge.** A `defmock` outside the `test_helper.exs`
  files and the files the trace read names no double.
- **Aliases in a declaration file are read file-wide.** An alias inside one module of the
  file expands names in every other.
- **Doubles are recorded on full builds only.** An incremental update keeps the `double`
  calls a record already carries and reads no declarations, so an expectation written since
  the last full build draws nothing until the next.
- **Fakes under the test paths are not implementations.** A module under the test paths that
  implements the behaviour is never a double's target.

## Agent-written tests (milestone 10.6)

- **The recipe.** `Grasp.TestPlan` holds one recipe, used by everything below: for a target —
  a function id, or the review's changes — the agent reads the functions under test
  (`get_function`), the tests that reach each (`tests_for`) and its coverage (`coverage`).
  For the changes, the functions under test are the changed application functions
  `list_changes` returns, not the tests and setups, beginning with those `untested_changes`
  names, since no test reaches them. When `coverage` answers `none`, the agent says that
  `mix grasp.cover` writes it and plans from the tests alone. It then lays the canvas out
  with one group per function under test, titled with its id, holding the function and the
  tests that reach it (`set_cards`, `group_cards`); comments on every clause and arm
  coverage reports never entered, and on the first line of every function no test reaches,
  saying what a test for it would have to exercise — the input, the path it takes and what
  to assert (`add_comment`); and stops there, telling the reader the plan is on the canvas
  for review, without writing a test. Asked afterwards to write the tests, the agent writes
  them against that plan and runs them (`run_tests`, `run_status`), and reads the coverage
  again once a coverage run has finished. In read mode it says it can neither write a test
  nor start a run, and leaves both to the reader. `Grasp.TestPlan.request/1` gives the
  words that ask for a plan: `Plan tests for <function id>`, or `Plan tests for the changes`.
- **The chat.** The agent's system prompt carries the recipe in both modes, after the
  comment paragraphs and before the pull-request recipe; it arranges cards and comments,
  which read mode may do. With an empty transcript the chat panel offers
  `Plan tests for the changes` beside `Show me what changed`, under the same condition —
  the index records a base ref or holds changed functions — and
  `Plan tests for <focused function>` beside `Explain <focused function>` when a card is
  focused. The suggestions read, in order: what changed, plan tests for the changes, explain
  the focused card, plan tests for it, publish the comments, the first route. Either plan
  suggestion sends exactly those words, which the recipe answers.
- **MCP.** The server declares the `prompts` capability beside `tools` and serves one
  prompt, `plan_tests(target, session)`, both arguments required: `target` a function id
  or `changes`, `session` a review session name under the rule the tools' `session` keeps.
  It answers one user message: the request for that target, the recipe, and the session its
  cards and comments go to. An id reached through a default-argument arity is answered with
  the id of its definition. A function id the index does not hold, a request with no index
  loaded, and a session name outside the rule are errors.

### Known gaps (milestone 10.6)

- **The recipe is instructions, not code.** Nothing checks that the agent followed it, so a
  plan is as good as the agent's reading of the recipe.
- **The chat agent reaches the recipe through its system prompt, not the MCP prompt.** The
  CLI the panel runs reads no MCP prompt; the two carry the same `Grasp.TestPlan.recipe/0`.
- **In read mode the agent plans but cannot write or run a test.** It lays the plan out and
  comments on it, then leaves writing and running the tests to the reader.

## Milestones

The tests work is milestones 10.1 to 10.6, listed under milestone 6 of
[the main design](2026-09-15-grasp-design.md).

1. **10.1** Test records: the test trace, ExUnit extraction, test ids, routes from test
   requests, base-ref classification, test cards, signature-mode assertions, Tests group.
   Done.
2. **10.2** Tested by: reach, tests badge and callers-menu section, untested changes and
   paired changes in PR mode, `tests_for` and `untested_changes`. Done.
3. **10.3** Coverage: `mix grasp.cover`, the coverage document, line tints, clause and arm
   gaps, `coverage`. Done.
4. **10.4** Runs and failures: `mix grasp.test`, the formatter, the results document, the
   run machinery, the runs panel and run controls, result badges, failure panels and
   chains, `run_tests`, `run_coverage` and `run_status`. Done.
5. **10.5** Test review: weakened assertions and added tests that assert nothing, their
   badges and the Test review group, `double` edges from Mox expectations, `test_review`.
   Done.
6. **10.6** Agent-written tests: the `Grasp.TestPlan` recipe in the chat's system prompt,
   the two plan-tests suggestions, and the MCP prompt `plan_tests`. Done.
