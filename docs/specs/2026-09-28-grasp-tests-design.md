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
  own compiled beams — `grasp`'s `ebin` from the dev build — are prepended to its code path,
  then has the tracer installed and the test files required without running a test. The
  host changes nothing. Measured on a 258-file suite: 15 s, 115 000 events from 6 600 test-side
  functions.
- **Coverage and runs use the host's own `mix test`.** Grasp never runs a test itself: it
  runs the host's test command, with Grasp's beams on the path the same way, so the suite
  runs with the host's configuration, database and environment. Results and coverage are
  written by Grasp code loaded into that run (a formatter, a coverage export) and read back
  by the viewer.
- **Static first.** Test records, their edges and "tested by" need no test run and ship
  first; coverage and results are layers over the canvas that a run brings and a later run
  replaces.

## Test records (milestone 10.1)

### The trace

`mix grasp.index` traces the tests after it has traced the application, whenever the
project has a `test/` directory; `--no-tests` skips it. The dev indexer starts the test
trace as a subprocess:

```
MIX_ENV=test MIX_BUILD_PATH=_build/grasp_test mix run --no-start <script>
```

- `_build/grasp_test` is seeded from `_build/test` the first time it is missing, as
  `_build/grasp` is seeded from `_build/dev`, so a dev server and a `mix test` run are never
  compiled under. `mix run` compiles the project before the script starts, with no tracer
  installed and Grasp absent from the code path, so an unchanged tree compiles nothing and
  the test build is the one `mix test` compiles: a host's `Code.ensure_loaded?(Grasp.Router)`
  guard reads false there.
- The script is a file Grasp ships in `priv/`, run by path. It prepends the dev build's
  `grasp` `ebin` directory — the only one it needs, since extraction runs in the parent — to
  the code path, installs `Grasp.Index.Tracer`, sets `ignore_module_conflict: true`, starts ExUnit with
  `autorun: false`, and requires, with `Kernel.ParallelCompiler.require/2`, the test-only
  support files — the files under the test environment's `elixirc_paths` that the dev
  environment's do not include (`test/support`) — and then every `test/**/*_test.exs`.
  Nothing is run: requiring a test file defines its module and registers its tests with an
  ExUnit that never starts a run. `test_helper.exs` is not required, since it starts
  repositories and sandboxes the trace does not need.
- The script writes the events whose file is one of those it required, as
  `:erlang.term_to_binary/1`, to a file the parent names, and exits. The parent reads the
  events and joins them with what Sourceror extracts from the same files, as the
  application's are joined. A test trace that fails — a test file that does not compile —
  is reported with the compiler's output and leaves the application's records written:
  the index is the application's with no tests, never no index.

### Extraction

`Grasp.Index.Extract` reads a test file as it reads any Elixir file, and additionally
recognises ExUnit's blocks inside a module:

- `test "name"` (with or without a context argument), inside or outside a `describe`, is a
  definition of kind `:test`. Its compiled name is ExUnit's, `:"test <describe> <name>"`
  (`:"test <name>"` outside a `describe`), arity 1, which is the function the tracer names
  as the caller of every call in its body. Its span runs from any `@tag`/`@moduletag`
  attribute and leading comment attached to it through its `end`.
- `setup` and `setup_all` blocks are definitions of kind `:setup`, named as ExUnit compiles
  them (`:"__ex_unit_setup_<n>"` and `:"__ex_unit_setup_all_<n>"`, numbered in order, and
  per `describe` as ExUnit numbers them); a `setup :name` naming a function adds no
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
`post(conn, "/bonuses", params)`, `live(conn, "/greet/live")`, or a request helper of the
same shape. `~p` sigils already produce route sites. A call named `get`, `post`, `put`,
`patch`, `delete`, `head`, `options`, `live` or `visit` whose second argument is a literal
string or `~p` sigil is a route site too, with the verb the name gives (`live` and `visit`
are GET), and `Grasp.Index.Routes` resolves it like any other. The call counts when it is
local or imported, or remote on a module whose alias ends in `Test` (`Phoenix.ConnTest`,
`Phoenix.LiveViewTest`, a project's own `*Test` helper); a remote call on any other module
(`Map.get(params, "/")`, an HTTP client's `get`) is not a request. So an interface-level test
draws the chain it drives: test, route, controller action, context.

### Base ref

In PR mode the base side of every changed test file is extracted like any changed source
file, so test records are added, modified, unchanged or removed against the base, and a
modified test has a diff.

### Viewer

- A test card wears a `test` badge and titles itself with the test's name, the `describe`
  above it in the header's module slot; a setup card wears `setup`.
- In signature mode a test card shows its name and, under it, its assertion lines — each
  line whose first token is `assert`, `refute` or an `assert_*`/`refute_*` call — in place
  of its body, so a zoomed-out canvas reads what each test promises.
- The sidebar has a **Tests** group listing test modules by file, each opening into its
  tests, grouped by `describe`. The palette finds tests by name.

### Known gaps

- **Test records refresh on a full build only.** The reindexer follows the code reloader,
  which never compiles a test file, so a test edited while the viewer runs keeps its record
  until the next `mix grasp.index`.
- **Tests defined by a macro other than ExUnit's** (a property-based `property`, a
  project's own `test_with_x`) are traced — their calls are events like any other — but have
  no definition to join to unless the macro expands to a `test`, and their calls land as
  hidden calls of nothing.

## Tested by (milestone 10.2)

- **Reach.** `Grasp.Index` computes, at load, for every application function the tests
  that reach it: a breadth-first walk from every test record over resolved calls
  (`call`, `route` and `enqueue` edges), up to `4` hops, keeping each test's shortest
  distance. `Grasp.Index.tests_for(index, id)` answers `[%{test: id, hops: n}]`, nearest
  first. A setup's reach counts for every test of its module.
- **Card.** A function card reached by any test wears a `n tests` badge in its header; the
  callers menu gains a Tests section listing them, nearest first with the hop count, each
  opening its test card as a caller does. A card no test reaches wears nothing.
- **PR mode.** In the Changes group every changed application function no test reaches is
  marked `untested`, and an **Untested changes** group lists them. Under each changed
  function the Changes group lists the changed tests that reach it, so code and tests
  changed together read as pairs.
- **MCP.** `tests_for(function_id, max_hops?)` and `untested_changes()`.

## Coverage (milestone 10.3)

- **Run.** `mix grasp.cover` — and the toolbar's `coverage` menu, and the MCP tool
  `run_coverage` — runs the host's test command (`:grasp, :test_command`, default
  `["mix", "test"]`, with the host's environment) with `--cover --export-coverage grasp`
  and Grasp's beams on the code path, then imports `cover/grasp.coverdata` with `:cover`
  in a subprocess and writes `.grasp/coverage.json`: per source file, the lines `:cover`
  counted and the count on each, stamped with the git head and the index's
  `generated_at`.
- **Tint.** While coverage is loaded and the `coverage` toggle is on (key `v`), a card body
  tints each counted line as run or never run; a line `:cover` does not count stays
  untinted. In a diff body the inserted lines that never ran are the ones marked. A card
  whose record's source differs from the source the coverage was taken against says
  `coverage stale` and tints nothing.
- **Clause gaps.** Extraction records, for every definition, the line range of each clause
  and of each arm of the `case`, `cond`, `with … else`, `receive` and `fn` clauses in its
  body. A clause or arm whose every counted line ran zero times is marked `never entered` at
  its head.
- **MCP.** `coverage(function_id)` answers the lines run and not run and the clauses and
  arms never entered.

## Runs and failures (milestone 10.4)

- **Run.** A test card has `run`; a tests badge has `run all`; the Changes group has `run
  changed tests`; MCP `run_tests(ids | "changed")`. Each runs the host's test command with
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
