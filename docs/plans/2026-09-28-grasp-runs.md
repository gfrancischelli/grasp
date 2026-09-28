# Grasp Runs and Failures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reader runs a test, the tests reaching a function, the changed tests or a coverage pass from the canvas and watches it run; every test card then wears its result, and a failed test opens its stacktrace as a chain of cards with the assertion's `left` and `right` under the failing line; the agent starts runs and reads their outcome over MCP.

**Architecture:** `mix grasp.test` runs a script Grasp ships under `MIX_ENV=test mix run --no-start` that prepends Grasp's ebin and calls `mix test` in the same process with `Grasp.Test.Formatter`, which merges results into `.grasp/results.json` (Task 1). `Grasp.Runs` runs one command at a time as a port and broadcasts status and output; `Grasp.ResultsStore` polls the results file (Task 2). The viewer gains a runs panel, run controls and result badges (Task 3), and failures under the line and as chains of cards (Task 4). MCP tools start runs and read their status (Task 5). Docs close it (Task 6).

**Tech Stack:** Elixir, Mix, ExUnit formatters (`GenServer` receiving `ExUnit` events), Erlang ports, Phoenix LiveView and PubSub, JavaScript hooks (esbuild), CSS, Markdown.

**Spec:** `docs/specs/2026-09-28-grasp-tests-design.md` §Runs and failures (milestone 10.4) — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new panel", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching the fixture app or running a suite also `mix test --include integration`; tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index is regenerated only by the recipe in `grasp/test/fixtures/regenerate.exs`; frozen fixture files never edited (`greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, lines 1–15 of `greet_controller.ex`); never `mix format` inside the fixture app. Integration tests may run inside the fixture app writing only gitignored directories (`_build/*`, `cover/`, `.grasp/` if ignored — check) with outputs in temp paths, as the builder and coverage integration tests do. Existing tests pass unmodified except forced edits (list each).
- Never run the real `gh`, `claude` or the network in tests; a test of `Grasp.Runs` runs a fake command (e.g. `sh -c` echoing lines) or the fixture's suite under `:integration`, never the machine's host project.
- Grasp is a dev-only dependency of its host: nothing here may require it in the host's test environment. The mechanism is fixed by a spike: `ELIXIR_ERL_OPTIONS=-pa …` is pruned by Mix and `mix test` silently ignores a formatter it cannot load; a `mix run` script that prepends the ebin after Mix's load paths ran and then calls `Mix.Task.run("test", args)` loads the formatter and receives every `{:test_finished, test}`.

---

### Task 1: `Grasp.Test.Formatter`, the test-run script, `mix grasp.test`

**Files:** create `grasp/lib/grasp/test/formatter.ex`, `grasp/lib/grasp/test_results.ex` (`Grasp.TestResults`: merge, encode, decode, `for_test/2`), `grasp/priv/test_run.exs`, `grasp/lib/mix/tasks/grasp.test.ex`; add `priv/test_run.exs` to the package files in `grasp/mix.exs`; tests in `grasp/test/grasp/test_results_test.exs`, `grasp/test/grasp/test/formatter_test.exs`, an integration test running `mix grasp.test` in the fixture app.

**Rules (the spec, §Running tests and §Results):**
1. `mix grasp.test [TEST_ID ...] [--changed] [--all] [--index PATH] [--out PATH]` resolves test ids to `file:line` arguments through the index (`file` and `span.start_line` of each test record; unknown ids are an error listing them); `--changed` is the added and modified test records; `--all` passes no file arguments. It runs `mix run --no-start <priv>/test_run.exs <grasp_ebin> <out> <run_id> <index_path> -- <mix test args>` with `System.cmd/3` in the project root, env `MIX_ENV=test` over the inherited environment, output streamed (`into: IO.stream()`), and exits with the suite's status.
2. `priv/test_run.exs` prepends the ebin, ensures `Grasp.Test.Formatter` loads (a clear error otherwise), puts the output path, run id and index path where the formatter reads them (application env of a Grasp-owned key, or the formatter's options), and calls `Mix.Task.run("test", args ++ ["--formatter", "Grasp.Test.Formatter", "--formatter", "ExUnit.CLIFormatter"])`. The host's own configured formatters are replaced for this run; say so in the script's header.
3. `Grasp.Test.Formatter` collects `{:test_finished, %ExUnit.Test{}}`: id `Grasp.Index.Join.function_id(test.module, test.name, 1)`; status from `test.state` (`nil` → passed, `{:failed, errors}` → failed, `{:skipped, _}` → skipped, `{:excluded, _}` → excluded, `{:invalid, _}` → invalid); `time` (µs); for each error `{kind, reason, stacktrace}`: `kind`, `message` (`Exception.message/1` or `inspect`), for an `ExUnit.AssertionError` its `expr` (`Macro.to_string/1`), `left` and `right` (`inspect` with the CLI formatter's options, `:no_value` → absent), and `stacktrace` as `[%{module, function, arity, file, line}]` (relative file). On `{:suite_finished, _}` it merges into the results file (`Grasp.TestResults.merge/3`): existing results kept, this run's tests replaced; each result carries `run_id`, `finished_at` and the `source_hash` (sha256) of the test record's `source` read from the index at `index_path` (nil when the id is not in the index). The write is via temp file and rename.
4. `Grasp.TestResults.for_test(document, record)` answers `:none`, `{:stale, result}` (source hash differs) or `{:fresh, result}`.

- [ ] **Step 1: Tests.** Unit: `merge/3` keeps other tests' results and replaces a run's; `for_test/2` none/stale/fresh; formatter state mapping and error encoding, by sending the formatter process `ExUnit` event tuples built with `%ExUnit.Test{}` in the test (an assertion error with left/right, a raised error, a skipped test); the task's argv/env with a fake runner and id resolution (unknown ids listed). Integration (fixture app, `:integration`): `mix grasp.test` for one passing and one failing fixture test writes both results with the right statuses and the failure's message and stacktrace frames; a second run of only the passing test keeps the failing test's result. Run; expect failure.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Gates (with `--include integration`) and commit.** Message: `mix grasp.test runs the host's tests and records each result` plus trailer.

---

### Task 2: `Grasp.Runs` and `Grasp.ResultsStore`

**Files:** create `grasp/lib/grasp/runs.ex`, `grasp/lib/grasp/results_store.ex`; modify `grasp/lib/grasp/application.ex` (children beside the other stores, in the branch that starts them); tests in `grasp/test/grasp/runs_test.exs`, `grasp/test/grasp/results_store_test.exs`.

**Rules (the spec, §The run machinery and §Results):**
1. `Grasp.Runs.start(kind, argv, opts)` — kind `:tests` or `:coverage`, a description string, argv (`["mix", "grasp.test", ...]` / `["mix", "grasp.cover"]`) — spawns it as a port (`:spawn_executable` via `System.find_executable`, `:binary`, `:exit_status`, `:stderr_to_stdout`, line mode or chunk splitting into lines) in the project root (`Grasp.Application.home/0` or the index's project root — the checkout Grasp was started in) with the environment the viewer VM has; answers `{:ok, run}` or `{:error, {:running, run}}` while another runs. `cancel/0` closes the port and kills the OS process group (use a wrapper that makes the child killable — e.g. `setsid`-free approach: record the OS pid from `Port.info(port, :os_pid)` and `System.cmd("kill", ...)` the process and its children, or run through `sh -c 'exec …'`; choose and test it). `status/0` answers `:idle` or the run `%{id, kind, description, started_at, output: last 200 lines}`, and the last finished run with its exit status.
2. Every status change and every output line is broadcast on the `"runs"` topic (`{:run_started, run}`, `{:run_output, id, line}`, `{:run_finished, run}`); `subscribe/0`.
3. `Grasp.ResultsStore` holds the decoded results document and polls `.grasp/results.json` (beside the index; `:grasp, :results_path` overrides) like `Grasp.CoverageStore`, broadcasting `:results_reloaded` on `"results"`; `get/0`, `reload/0`.

- [ ] **Step 1: Tests** with fake commands: a run's lines broadcast in order and its exit status recorded; a second start while running refused with the running one; cancel stops a long-running command (e.g. `sleep 30` through the chosen wrapper) and reports it cancelled; the environment reaches the child (a variable set in the test VM echoed by the child). Store: poll, bad file keeps previous, missing file is no results. Run; expect failure.
- [ ] **Step 2: Implement.** Gates; commit. Message: `One run at a time, broadcast as it goes` plus trailer.

---

### Task 3: The runs panel, run controls and result badges

**Files:** modify `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/components/sidebar.ex` (run changed tests), create a component for the runs panel (e.g. `grasp/lib/grasp_web/components/runs_panel.ex`), the help dialog if a key is added (none are), `grasp/assets/css/app.css`, JS only if the panel needs a hook (sticky scroll of the output, as the chat panel does — reuse its approach); rebuild bundles; tests.

**Rules (the spec, §Controls and §Badges):**
1. The toolbar gains `runs` (toggles the runs panel; its label says `running…` while a run is under way). The panel shows the current or last run's description, status, streamed output (last 200 lines, newest at the bottom, sticky scroll), `cancel` while running, and `run coverage`. It sits where the chat panel sits; opening one closes the other.
2. A test card's header has `run` (runs that test); the callers menu's Tests section has `run all` (runs every test listed); the Changes group has `run changed tests` when there are changed tests. Each starts a run through `Grasp.Runs` with `mix grasp.test …` and opens the runs panel; while a run is under way the controls are disabled with a title naming the running command.
3. A test card wears its latest result: `passed`, `failed`, `skipped` (from `TestResults.for_test/2`, fresh), or `stale`; none without a result. The function card's tests badge reads `n tests · m failing` when fresh results mark any of its tests failed.
4. Results and run status reach the view by PubSub; nothing re-reads the results file per render; card result readings are computed when results or the index reload, keyed as coverage readings are.

- [ ] **Step 1: Tests** (view, with a fake `Grasp.Runs` command configured by the test — e.g. `:grasp, :test_command_override` or starting runs with a stub argv — and a results document written in the test): the panel toggles, shows streamed output from a fake run and its finish, cancel; a test card's `run` starts a run naming that test; `run all` and `run changed tests` name the right ids; controls disabled while running; badges for passed/failed/skipped/stale; the tests badge failing count. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`.
- [ ] **Step 3: Gates and commit** (bundles). Message: `Tests and coverage run from the canvas, and cards wear their results` plus trailer.

---

### Task 4: Failures under the line, and failures as chains of cards

**Files:** modify `grasp/lib/grasp_web/components/card_components.ex` (the failure panel), `grasp/lib/grasp_web/live/review_live.ex` (`open_failure`), `grasp/lib/grasp/session/forest.ex` / `grasp/lib/grasp/session.ex` if a chain-opening primitive is needed (reuse `open_callers`'s idiom for callees), `grasp/assets/css/app.css`; rebuild bundles; tests.

**Rules (the spec, §A failure is a chain of cards):**
1. A test card with a fresh failed result renders, for each error, a panel under the line its own frame names (the first stacktrace frame whose `module`/`function` is the test's own module and compiled name; else the test's first line): the message, and for an assertion `left` and `right` as recorded, preformatted, escaped. It is part of the result: not a comment, not stored in the comments file.
2. The failed card's header has `open failure`: it walks the first error's stacktrace from the frame after the test's own frame outwards — deepest last — keeping frames whose `{module, function, arity}` is an indexed function (`Join.function_id/3`), and opens them as a chain of callees from the test card: each card opened as a callee of the previous one (reusing a card already on the canvas as open_callers does), highlighting the frame's line (`Session.set_highlight` with the line), focus on the deepest. Frames through dependencies and non-indexed functions are skipped; a chain of none does nothing.
3. Edges drawn for the chain are the call edges the records hold; a frame whose caller does not call it directly (a skipped dependency frame in between) still opens as a child — say in the card's highlight title or the panel that the step passes through code outside the index.

- [ ] **Step 1: Tests** with a results document holding a failure whose stacktrace names fixture functions and a dependency frame between them: the panel under the right line with message/left/right escaped; `open failure` opens the indexed frames in order, highlights each line, skips the dependency frame, focuses the deepest; a failure with no indexed frames opens nothing. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates; commit (bundles). Message: `A failed test shows why, and opens the path it failed down` plus trailer.

---

### Task 5: MCP `run_tests`, `run_coverage`, `run_status`

**Files:** create `grasp/lib/grasp/mcp/tools/{run_tests,run_coverage,run_status}.ex`; register in `grasp/lib/grasp/mcp/server.ex`; the tool-name list test (forced edit); the agent's system prompt names the three tools (`grasp/lib/grasp/agent/command.ex`) and its test; tests in `grasp/test/grasp/mcp/`.

**Rules (the spec, §MCP):**
1. `run_tests(test_ids: [string] | changed: true)` starts `mix grasp.test` through `Grasp.Runs` and answers `{"started": run}` or `{"running": run}` when another run is under way; unknown ids are an error listing them. `run_coverage()` starts `mix grasp.cover` likewise.
2. `run_status()` answers `{"running": run with its last 50 output lines}` or `{"last": run with exit status, and for a test run the results of its tests from the results document: id, status, and for failures the first error's message, left, right and the first indexed frame}` or `{"idle": true}`.
3. Descriptions say that runs are asynchronous and `run_status` reads their outcome, and that a test's id quotes its name.

- [ ] **Step 1: Tests** with a fake run command. **Step 2: Implement.** Gates; commit. Message: `The agent starts runs and reads their outcome` plus trailer.

---

### Task 6: Docs

**Files:** `docs/specs/2026-09-28-grasp-tests-design.md` (correct §Runs and failures sentences Tasks 1–5 found untrue; `### Known gaps (milestone 10.4)`: a run replaces the host's own configured formatters for its duration; results of tests deleted from the suite stay in the results file until a run of `--all` rewrites… — state whatever the merge rule does for deleted tests; a run started outside Grasp (`mix test`) records nothing; cancel's reach on grandchildren; one run at a time), `docs/specs/2026-09-15-grasp-design.md` (§Milestones 10.4; Part 3 tools), `grasp/guides/reviewing.md` (runs panel, run controls, badges, failures), a "Running tests" section in `grasp/guides/coverage.md` or a guide of its own (`mix grasp.test`, options, `.grasp/results.json`, `:results_path`), `grasp/guides/getting-started.md` (toolbar gains `runs`), `grasp/guides/agent.md` (the three tools), the README's `.gitignore` block gains `.grasp/results.json`.

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: runs and failures` plus trailer.
