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
  entry: their bodies run when their callers compile, before `:cover` starts. The document
  is written to a file beside its path and renamed over it, so a reader never sees one half
  written.
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
- **The whole suite runs.** `mix grasp.cover` runs every test, and starting it from the
  viewer or the agent is milestone 10.4's.

## Runs and failures (milestone 10.4)

- **Run.** A test card has `run`; a tests badge has `run all`; the Changes group has `run
  changed tests`; the toolbar's coverage menu has `run coverage`, which runs
  `mix grasp.cover`; MCP `run_tests(ids | "changed")` and `run_coverage()`. Each runs the host's test command with
  `file:line` arguments and `--formatter Grasp.Test.Formatter --formatter
  ExUnit.CLIFormatter`, Grasp's beams on the path. The formatter writes
  `.grasp/results.json`: per test id, `passed`, `failed`, `skipped` or `excluded`, its time,
  and for a failure the assertion's expression, `left`, `right` and message, and the
  stacktrace as `{module, function, arity, file, line}` frames. One run at a time; output
  streams to a panel.
- **Badges.** A test card wears its latest result. A tests badge counts failures among the
  tests it lists.
- **A failure is a chain of cards.** `open failure` on a failed test lays its stacktrace out
  from the test card: each frame whose function is indexed becomes a card, opened from the
  previous one as a callee, highlighting the frame's line, so the red test reads as the
  path into the code that failed. The assertion's message and its `left`/`right` render as
  a panel under the failing line of the test card — part of the result, not a stored
  comment.

## Test review (milestone 10.5)

- **Weakened assertions.** In PR mode a modified test whose diff deletes an assertion line,
  turns an `==` or `===` assertion into `=~`, `match?` or `in`, or deletes an `assert_*`
  call is marked `assertion weakened`; an added test with no assertion line at all is marked
  `asserts nothing`. Both are badges on the card and rows in a **Test review** group.
- **Doubles.** A `Mox.defmock(Mock, for: Behaviour)` in any file the test trace reads names
  `Mock` a double of `Behaviour`. An `expect`, `stub` or `stub_with` naming `Mock` and a
  function in a test body is an edge of kind `double`, dashed, from the test to the
  function of that name in every indexed module declaring `@behaviour Behaviour`, so a
  reviewer sees which code the test stands in for rather than runs.

## Agent-written tests (milestone 10.6)

- **Prompt.** An MCP prompt, `plan_tests(target)` — a function id, or `changes` — has the
  agent lay out one group per function under test holding the function and the tests that
  reach it, comment on every clause or arm coverage says was never entered, and stop there
  for the reader to review before it writes a test.
- **Loop.** The tools of 10.2–10.4 are the loop an agent writes tests in: `coverage` for
  the gaps, `run_tests` for the result, `tests_for` for what already reaches a function.

## Milestones

1. **10.1** Test records: the test trace, ExUnit extraction, test ids, routes from test
   requests, base-ref classification, test cards, signature-mode assertions, Tests group.
2. **10.2** Tested by: reach, tests badge and callers-menu section, untested changes and
   paired changes in PR mode, `tests_for` and `untested_changes`.
3. **10.3** Coverage: `mix grasp.cover`, the coverage document, line tints, clause and arm
   gaps, `coverage`.
4. **10.4** Runs and failures: the formatter, results, run controls, badges, failure
   chains, `run_tests`.
5. **10.5** Test review: weakened assertions, empty tests, doubles.
6. **10.6** Agent-written tests: `plan_tests`.
