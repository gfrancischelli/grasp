# Grasp Test Records Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project's tests are function records of the index: every `test` and `setup` block and every function of a test module, with the calls its body makes as edges into the application, a request made with a path resolved to the route it hits, classified against a base ref in PR mode, and drawn as test cards the reader finds in a Tests group and the palette.

**Architecture:** Extraction learns ExUnit's blocks (Task 1). A test trace — a `MIX_ENV=test mix run` subprocess running a script Grasp ships, with Grasp's dev-build beams on its code path and the tracer installed — compiles the test-only support files and the test files without running them and hands the events back to the dev indexer, which joins them like the application's (Task 2). Request calls in tests become route sites, and the base side of test files is extracted (Task 3). The viewer draws test records (Task 4). Docs close it (Task 5).

**Tech Stack:** Elixir (Sourceror, the compiler tracer, ExUnit, Mix), Phoenix LiveView, CSS, Markdown.

**Spec:** `docs/specs/2026-09-28-grasp-tests-design.md` §Decisions and §Test records (milestone 10.1) — the authority for every rule below. The main design, `docs/specs/2026-09-15-grasp-design.md`, holds for everything this plan does not change.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new record", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks that touch the indexer, the fixture app or the fixture index also run `mix test --include integration`. Tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes; never commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe at the top of `grasp/test/fixtures/regenerate.exs`. Frozen fixture files, never edited: `greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, and lines 1–15 of `greet_controller.ex`. Any new dependency of Grasp is also fetched in `grasp/test/fixtures/sample_app` (`mix deps.get`), whose `mix.lock` is tracked.
- Existing viewer tests must keep passing unmodified. Extra records in the fixture index can move palette and search results: if one does, rename the fixture test (its module or its test names) so it stops matching, rather than editing the viewer test. A test that asserts a count of all records or all functions may be updated to the new count, and the report must list every such edit.
- Never run the real `gh`, `claude` or the network in tests.

---

### Task 1: Extraction reads ExUnit's blocks, and ids quote names that need it

**Files:** modify `grasp/lib/grasp/index/extract.ex`, `grasp/lib/grasp/index/join.ex` (`function_id/3`, and the function record type if it names kinds), `grasp/lib/grasp/index/builder.ex` (`function_json/1` writes the `"test"` field); tests in `grasp/test/grasp/index/extract_test.exs` and `grasp/test/grasp/index/join_test.exs`.

**Rules (the spec, §Extraction and §Ids):**
1. Inside a `defmodule`, a `test "name" do … end` or `test "name", context do … end` call is a definition of kind `:test`, arity 1, whose `name` is the atom ExUnit compiles: read it from ExUnit's own source in the installed Elixir (`ExUnit.Case.register_test/6` and `describe/2` in `lib/ex_unit/lib/ex_unit/case.ex`) and match it exactly — `:"test <describe> <name>"` inside a `describe`, `:"test <name>"` outside. A `test "name"` with no body (a pending test) is no definition.
2. `setup` and `setup_all` blocks with a `do` body (with or without a context argument) are definitions of kind `:setup`, arity 1, named as ExUnit compiles them — read `lib/ex_unit/lib/ex_unit/callbacks.ex` for the counters and the per-`describe` naming, and match exactly. `setup :fun` and `setup [:a, :b]` add no definition.
3. `describe "name" do … end` contributes no definition; its name is carried on every test inside it.
4. A test or setup definition's span runs from the first attached `@tag`/`@describetag` attribute or leading comment through its `end`; its call sites are collected from its body exactly as a function's are, so `Grasp.Index.Join` pairs them with the tracer's events (whose `function` is `{compiled_name, 1}`).
5. A test definition carries `test: %{describe: String.t() | nil, name: String.t(), tags: [String.t()]}` — the tags from `@tag :name` and `@tag name: value` attached to it (the key's name for a keyword tag). A setup carries `test: nil`; every other definition carries no `test` key, or `nil` (choose one and keep the record type consistent). `Builder.function_json/1` writes `"test"` only when the record has one, as a JSON object with string keys.
6. `Join.function_id/3` writes the name as a remote call writes it: `Macro.inspect_atom(:remote_call, name)` for an atom, so `:"test greet/2 says hello"` gives `SampleAppWeb.GreetControllerTest."test greet/2 says hello"/1`, and `:greet`, `:valid?`, `:+` keep today's spelling byte for byte (`greet`, `valid?`, `+`). For a binary name the same quoting is applied without creating an atom: a binary that `Macro.inspect_atom(:remote_call, …)` would leave bare is kept as it is, and any other is written the way that function writes a quoted atom (double quotes, `inspect/1`'s escapes). Never `String.to_atom/1`.

- [ ] **Step 1: Tests.** In `extract_test.exs`, extract a source string with a test module holding: a top-level `test`, a `describe` with two tests (one with a context argument, one with `@tag :slow` and a leading comment), a pending `test "later"`, a `setup` block, a `setup_all` block, a `setup :named` and a `defp helper`. Assert the definitions: kinds, compiled names (write them as the exact atoms ExUnit produces), arity 1, spans (the tagged test's span starts at its comment), the `test` maps, the helper as an ordinary `:defp`, no definition for the pending test or `setup :named`. Verify the compiled names against a real compilation: in the same test file, compile the same module source with `Code.compile_string/1` **only if** ExUnit accepts a module compiled after the suite has started; if it does not, assert the names against ExUnit's source reading instead and say so in the report. In `join_test.exs`, assert `function_id/3` for a quoted name and for `:greet`, `:valid?`, `:+`. Run; expect failures.
- [ ] **Step 2: Implement** rules 1–6. Run the two files, then the whole suite.
- [ ] **Step 3: Gates and commit.** Message: `Extraction reads ExUnit's tests and setups as definitions` plus trailer.

---

### Task 2: The test trace

**Files:** create `grasp/priv/test_trace.exs` (the script) and `grasp/lib/grasp/index/test_trace.ex` (`Grasp.Index.TestTrace`); modify `grasp/lib/grasp/index/builder.ex`, `grasp/lib/mix/tasks/grasp.index.ex` (`--no-tests`), `grasp/lib/grasp/index/incremental.ex` only if Task 2's check below needs it; create fixture tests `grasp/test/fixtures/sample_app/test/test_helper.exs`, `grasp/test/fixtures/sample_app/test/support/sample_case.ex` (a case template), and two test files under `grasp/test/fixtures/sample_app/test/`; modify `grasp/test/fixtures/sample_app/mix.exs` (`elixirc_paths(:test)` includes `test/support`); regenerate `grasp/test/fixtures/index.json`; tests in `grasp/test/grasp/index/test_trace_test.exs` and the integration test in `grasp/test/grasp/index/builder_test.exs`.

**Rules (the spec, §The trace):**
1. `Grasp.Index.TestTrace.run(root, dev_paths, opts)` returns `{:ok, %{events: [Tracer.event()], files: [String.t()]}}` or `{:error, output}`. It runs, with `System.cmd/3` from `root`:
   `mix run --no-start --no-compile <priv>/test_trace.exs <events_file> <grasp_ebin> <sourceror_ebin> <dev_paths joined by ",">` with env `MIX_ENV=test` and `MIX_BUILD_PATH=<root>/_build/grasp_test`, having first seeded `_build/grasp_test` from `_build/test` when it is missing and `_build/test` exists (same staging-and-rename idiom as `Mix.Tasks.Grasp.Index.seed/1`). The two ebin paths are `:code.lib_dir(:grasp)/ebin` and `:code.lib_dir(:sourceror)/ebin` of the running dev session. The events file is a temporary path under `<root>/_build/grasp_test/`; it is read with `:erlang.binary_to_term/1` and deleted. `opts[:runner]` replaces `System.cmd/3` (tests pass a fake).
2. The script: prepends the two ebins; runs `Mix.Task.run("compile")` (no tracer yet); computes the test-only support files as the `.ex` files under the test environment's `Mix.Project.config()[:elixirc_paths]` that are not under any of the dev paths passed in; installs `Grasp.Index.Tracer` (`start/0`, `install/0`), sets `Code.put_compiler_option(:parser_options, columns: true)` and `Code.compiler_options(ignore_module_conflict: true)`; calls `ExUnit.start(autorun: false)`; requires support files then `test/**/*_test.exs` with `Kernel.ParallelCompiler.require/2`; writes `%{events: events_from_those_files, files: relative_files}` as `term_to_binary` to the events file; exits 0. Any compile error exits non-zero with the compiler's output on stdout/stderr. `test_helper.exs` is never required.
3. `Builder.run/1` runs the test trace after the application's trace when `opts[:tests] != false` and `<root>/test` is a directory. It extracts the files the trace names with the same `extract/2`, joins them with the trace's events with `Join.join/2`, and appends the resulting records to the application's before `classify` and `Resolve.resolve` (so route resolution and base classification apply to them). A trace error prints `grasp: tests not indexed: <output>` with `Mix.shell().error/1` and the build continues with the application's records only. The summary line gains `, <n> tests` when there are test records (count kind `:test` only).
4. `mix grasp.index --no-tests` passes `tests: false`. The flag is forwarded to the delegated subprocess the task already starts.
5. The document's `project` block gains `"test_paths": ["test"]` when tests were indexed, so the viewer and the reindexer know which files are tests.
6. Check, and cover with a test: an incremental update (`Grasp.Index.Incremental`) after a recompile of an application file keeps every test record untouched and still re-resolves routes on them. If it drops or rewrites them, fix Incremental so records whose file is under a `project.test_paths` entry are kept as the other untouched records are.
7. Fixture app: `test/support/sample_case.ex` is a `use ExUnit.CaseTemplate` exposing one helper function (e.g. `SampleApp.SampleCase.build_conn_for/1` calling `Phoenix.ConnTest.build_conn/0`); one test file tests `SampleApp.Formatter` or `SampleApp.Counter` directly with a `describe`, a `setup`, a tagged test and a helper `defp`; one conn test file requests a route with `get(conn, "<a path the router defines>")` and one with `~p` if the fixture router supports verified routes — otherwise two plain-string requests (Task 3 resolves them; this task only needs them to compile). Name the test modules and tests so they do not match the palette queries the viewer tests use (grep `palette_search`/`search` in `grasp/test/grasp_web`); the report lists the names chosen and why they are safe. `test_helper.exs` holds `ExUnit.start()` only.

- [ ] **Step 1: Unit tests** for `TestTrace.run/3` with a fake runner: the argv and env it passes, the seeding of `_build/grasp_test` from `_build/test` (temp dirs), the events file read and deleted, a non-zero exit returned as `{:error, output}`. Run; expect failure.
- [ ] **Step 2: Implement** rules 1–6.
- [ ] **Step 3: Fixture and integration.** Add the fixture tests (rule 7), `mix deps.get` in the fixture app if its lock needs anything (it should not). Extend the builder integration test: after `mix grasp.index` in the fixture app, the document holds the test records with kind `"test"`, the `test` map, calls from a test into `SampleApp.*` functions, a `setup` record, the support helper as a record, and `project.test_paths == ["test"]`; `--no-tests` writes none. Regenerate the fixture index with the recipe. Run `mix test --include integration`.
- [ ] **Step 4: Gates and commit.** Message: `The index traces the project's tests` plus trailer. The report gives the fixture index's record count before and after, the time the fixture's test trace took, and every viewer test edit (there should be none).

---

### Task 3: Requests in tests reach routes; test files have a base side

**Files:** modify `grasp/lib/grasp/index/extract.ex` (route sites), `grasp/lib/grasp/index/base_ref.ex` and `grasp/lib/grasp/index/builder.ex` (base extraction over test files), `grasp/lib/grasp/index/changes.ex` if it filters by paths; tests in `extract_test.exs`, `base_ref_test.exs`, `builder_test.exs` (integration).

**Rules (the spec, §Routes from tests and §Base ref):**
1. A call named `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `live` or `visit` with at least two arguments, whose second argument is a literal string or a `~p` sigil, is a route site with the verb the name gives (`live` and `visit` give `GET`) and the path's segments as `Extract.path_segments/1` reads them. The route site the `~p` alone would produce is replaced by this one (one route per call). The call is local, imported or remote alike (`Phoenix.ConnTest.get(conn, "/x")`).
2. This applies in every file the extractor reads, test or not.
3. In PR mode (`--base`), the files the base diff reports under `project.test_paths` are extracted on the base side too, and test records are classified `added`/`modified`/`removed`/`unchanged` exactly as application records are, with `base_source` for modified and removed ones.

- [ ] **Step 1: Tests.** Extract tests for each verb form (literal string, `~p`, remote call, a `get` whose second argument is a variable — no site), and that a `~p` inside `get(conn, ~p"/x")` yields one site with verb GET. A base-ref test: a temp git repo whose base has a test file and whose head modifies one test and adds another — the classified test records read `modified` (with `base_source`) and `added`. Integration: in the fixture, the conn test's records carry a `route` call to the controller action the path maps to. Run; expect failures.
- [ ] **Step 2: Implement.** Regenerate the fixture index with the recipe if the fixture's records gained route calls.
- [ ] **Step 3: Gates (including `--include integration`) and commit.** Message: `A request in a test reaches the route it names, and test files diff against the base` plus trailer.

---

### Task 4: Test cards, their signatures, the Tests group

**Files:** modify `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/components/sidebar.ex`, `grasp/lib/grasp_web/live/review_live.ex` (only what the sidebar group and palette need), `grasp/lib/grasp/index.ex` (a `tests/1` reader if the sidebar needs one), `grasp/assets/css/app.css`; rebuild bundles; tests in `grasp/test/grasp_web/live/review_live_test.exs` (or a new `tests_live_test.exs`) and `grasp/test/grasp/index_test.exs`.

**Rules (the spec, §Viewer and §Ids):**
1. A card whose record has kind `"test"` wears a `test` badge beside its title; its title is the test's `name`, and the header's module slot (`.card__module`, the text the module-cluster mode hides) reads the `describe` when there is one and the module otherwise. A `"setup"` card wears `setup` and titles itself `setup` or `setup_all` as its compiled name says.
2. The node's `data-module` is the record's `module` field when the card has a record, and the existing derivation from the id otherwise (stubs).
3. In signature mode a test card shows its title and, under it, its assertion lines — every source line whose first token is `assert`, `refute`, or a call whose name starts with `assert_` or `refute_` — each highlighted as code, in place of the signature line an ordinary card shows. A test with no assertion line shows its title alone.
4. The sidebar gains a **Tests** group, after Entry points, when the index holds test records: one row per test module (sorted by file), each expanding into its tests, grouped under their `describe` names; clicking a test opens its card as a new root (as an entry point does). Its open/closed state follows the other groups' conventions.
5. The palette finds test records by their `name` and module as it finds functions; a result for a test shows the `test` badge.
6. `Grasp.Index` exposes what the sidebar needs (e.g. `tests/1`: test records grouped by module and describe), with `@doc`/`@spec`.

- [ ] **Step 1: Tests** against the fixture index (Task 2's test records): the test card's badge, title and module slot; `data-module` for a test card; signature mode showing assertion lines (toggle signature mode the way existing signature tests do); the Tests group rows and opening a test; a palette search that finds a test by a word of its name. Run; expect failures.
- [ ] **Step 2: Implement**, CSS for the badge in the existing badge idiom, `mix assets.build`.
- [ ] **Step 3: Gates and commit** (bundles included). Message: `Test cards, their assertions in signature mode, and the Tests group` plus trailer.

---

### Task 5: Docs

**Files:** `docs/specs/2026-09-15-grasp-design.md` (§Milestones gains 10.1 with a pointer to the tests design; Part 1's pipeline paragraph gains one sentence on the test trace; the Index JSON example gains a test record's `"test"` field and `project.test_paths`), `docs/specs/2026-09-28-grasp-tests-design.md` (correct any sentence Tasks 1–4 found untrue — ExUnit's exact setup names, the flag, the paths), `grasp/guides/indexing.md` (a "Tests" section: what is indexed, `--no-tests`, `_build/grasp_test`, full-build-only refresh), `grasp/guides/reviewing.md` (test cards, signature assertions, the Tests group), `README.md` files if they list what the index holds.

- [ ] **Step 1:** Write the docs; verify every sentence against the code at HEAD.
- [ ] **Step 2:** Gates; commit. Message: `Docs: tests in the index` plus trailer.
