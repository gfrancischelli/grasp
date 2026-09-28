# Running tests

Run the suite, or the tests on the canvas, and read each result on its card.

## Running from the terminal

```
mix grasp.test TEST_ID ...
mix grasp.test --changed
mix grasp.test --all
```

The task runs your own suite, or the part of it you name, and records each test's result
in a results document the viewer and the MCP server read. Build the index first: a test is
named by its id in the index, and the index says where it is.

- **A test id** quotes the test's name, `SampleApp.TallyTest."test init keeps the start
  count"/1`, and is run as `mix test file:line`, with the line of its `test` call. An id the
  index holds no test for aborts the task, listing every such id. Put `--` before ids that
  could read as switches: every argument after it is an id.
- **`--changed`** runs the tests the branch added or modified against the index's base ref,
  does nothing when there are none, and aborts for an index built without `--base`.
- **`--all`** runs the whole suite.
- **`--index`** names the index, by default `:grasp, :index_path`, and `.grasp/index.json`
  when that is unset. **`--out`** names the results document, by default `results.json`
  beside the index.

The suite runs in the project root with `MIX_ENV=test` over the environment the task was
started with, and its output streams to the terminal. The task exits with the suite's
status. An umbrella's apps each run their own suite, so the task refuses at the umbrella
root: run it inside the app.

- **Grasp stays a dev dependency.** The task runs `mix test` from a script in Grasp's
  `priv`, which puts Grasp's compiled formatter on the path only after your project has
  compiled, so nothing of Grasp is needed in the test environment.
- **The run uses its own formatters.** `mix test` runs with `Grasp.Test.Formatter` beside
  ExUnit's own CLI formatter, in place of any formatter your config or `test_helper.exs`
  sets, so for the run the terminal shows ExUnit's report and nothing a formatter of yours
  adds.
- **A run that records nothing** — a project that does not compile, a suite that cannot
  start — aborts with the suite's status and leaves the results as they were.
- **Only a run through Grasp is recorded.** A plain `mix test` leaves the results as they
  stood.

## The results document

`.grasp/results.json` holds, per test id, the latest result recorded for that test:

```json
{
  "version": 1,
  "tests": {
    "SampleApp.TallyTest.\"test init keeps the start count\"/1": {
      "status": "failed",
      "time": 1234,
      "run_id": "5f2c…",
      "finished_at": "2026-09-28T12:00:00.123Z",
      "source_hash": "9a1e…",
      "errors": [
        {
          "kind": "error",
          "message": "Assertion with == failed",
          "expr": "assert init_with(7) == {:ok, 8}",
          "left": "{:ok, 7}",
          "right": "{:ok, 8}",
          "stacktrace": [
            {
              "module": "SampleApp.TallyTest",
              "function": "test init keeps the start count",
              "arity": 1,
              "file": "test/sample_app/tally_test.exs",
              "line": 18
            }
          ]
        }
      ]
    }
  }
}
```

- **Statuses** are `passed`, `failed`, `skipped`, `excluded` — a test the run loaded but did
  not run — and `invalid`, a test whose module's `setup_all` failed, so it never ran. The
  time is in microseconds.
- **A run updates only its own tests.** Running one test replaces that test's result and
  leaves every other as it stood. An `excluded` result replaces only a missing or excluded
  one, so running one test of a file keeps the results of the rest of it.
- **A changed test is stale.** Each result carries a sha256 of the test's source as the
  index held it, so a test edited since reads as `stale` rather than wearing a result that
  describes another body.
- **Runs finishing together** keep each other's results: the merge holds
  `results.json.lock` while it reads and writes, and a run that cannot take it within 30
  seconds says so and writes nothing. A document that cannot be decoded is kept beside it
  as `results.json.<timestamp>-<unique>.corrupt`, and the results start again from the run.
- **Results of deleted tests stay** in the document: a run never removes one. They have no
  card to show on.

The document is derived from runs, so it belongs in `.gitignore` with the index.
`config :grasp, results_path:` names the file the viewer reads, by default `results.json`
beside the index — where `mix grasp.test` writes it. The viewer polls the file every two
seconds, and reloads it as soon as a test run the viewer or the agent started finishes. A
missing file is no results; a file that cannot be read keeps the results already loaded.

## Running from the viewer

**runs** in the toolbar opens the runs panel, where the chat panel floats; opening either
closes the other. The panel names the run under way, or the last one, says whether it is
running, finished, failed with its exit status, or cancelled, and streams its output. It
has **cancel** while a run is under way and **run coverage**, which runs
`mix grasp.cover` (see [Coverage](coverage.md)).

- **`run`** on a test card runs that test.
- **`run all`** in the callers menu's Tests section runs every test listed there — every
  test that reaches the function.
- **`run changed tests`** at the top of the Changes group runs the tests the branch added
  or modified.

Starting a run opens the panel in the tab that started it. A run started elsewhere — in
another tab, or by the agent — opens no panel, but every tab's toolbar follows it and every
tab's panel shows it once opened. One run goes at a time, shared by every tab: while one is
under way the toolbar button reads `running…`, and every control that starts a run is
disabled and says what is running. **cancel** stops the whole suite — the task and the test
VM it started — and the run finishes as cancelled.

The run is started in `config :grasp, runs_root:` when that is set, and otherwise in Grasp's
home: the directory Grasp was started in — a host's project root, where its dev server
starts — or, for `mix grasp.viewer`, the root of the indexed project. It runs with the
viewer's own environment, so a database name or a secret the viewer's environment sets
reaches the suite. `config :grasp, runs_command:` names the command in front of the task,
`["mix"]` unless configured.

A run from the viewer passes the task the viewer's own paths: `--index`, the index the
viewer holds, and `--out`, the results document it watches — or, for a coverage run, the
coverage document. The ids the viewer checked are resolved in that index, and the results
land where the cards read them, whatever your project's config names.

## Results on the cards

- **A test card** wears its latest result: `passed`, `failed`, `skipped` or `invalid`, or
  `stale` when the test changed since. A test the last run excluded, or one never run,
  wears nothing.
- **A function card's tests badge** adds how many of the tests reaching it are failing,
  `3 tests · 1 failing`, counting the ones whose result is `failed` or `invalid`.

### Failures

A failed test card draws each error under the line of the test the failure passed through,
or under its first line when the stacktrace names none inside it: the message, an
assertion's expression with its `left` and `right` as ExUnit printed them, and the
stacktrace, each frame outside the index said to be. The panel is the result, not a
comment: it goes as soon as the result goes stale. A line the card is not drawing puts the
panel in the card's footer.

**open failure** in the card's header lays the first error's stacktrace out from the test:
each frame in a function the index holds becomes a card, opened from the one before it as a
callee, with the frame's line highlighted, so the failing test reads as the path into the
code that raised. It is offered only when the stacktrace holds an indexed frame past the
test's own.

- **Closures are their function.** A frame of an anonymous function, a comprehension or an
  inlined body opens the function it is written in.
- **A repeated function is one card.** A recursion, or a closure inside the function,
  repeats its frames; the card is highlighted at the deepest of them, the line that went on
  to fail.
- **Frames outside the index are skipped.** A dependency's or the standard library's frames
  open no card, and the failure panel says which step was reached through them.

## What a run does not do

- **Your formatters are replaced for the run**, so a report a formatter of yours writes — a
  JUnit file — is not written by a run through Grasp.
- **One run at a time.** A test run and a coverage run cannot run together.
- **A cancel on a system whose `ps` Grasp cannot read** (BusyBox's) closes the run without
  stopping the suite, and a viewer that halts leaves a run's suite running.
- **A frame whose line lies outside its function's indexed span** — code compiled from
  another file, an index behind the files — opens its card with no line highlighted.
- **An index behind the test files runs whatever test the indexed line holds.** A test runs
  as the file and line the index recorded, and test files are not reindexed as you edit
  them, so after an edit that moves tests the line can land in another test or in none. The
  test you named then reads as excluded and keeps its previous result, while the test that
  ran is recorded against the old index and reads fresh until the next reindex. Rebuild the
  index after moving tests.
- **A viewer at an umbrella root cannot run tests.** Both tasks refuse at an umbrella root,
  so every run such a viewer starts fails with that refusal. Set `config :grasp, runs_root:`
  to one app's directory to run that app's suite.
