# Grasp Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `mix grasp.cover` runs the host's own test suite with coverage, every card can tint the lines that ran and the lines that never ran, mark the clauses and branches no test entered, and say when its coverage describes code that has since changed; the agent reads the same coverage over MCP.

**Architecture:** Extraction records clause and arm line ranges on every record (Task 1). `mix grasp.cover` runs the host's test command with Mix's cover export, imports the export with `:cover` in its own process, and writes `.grasp/coverage.json` keyed by function id with a source hash (Task 2). A `Grasp.CoverageStore` polls that file as `Grasp.IndexStore` polls the index; the viewer renders per-line coverage attributes and clause gaps server-side, and a client-side `coverage` toggle (`v`) shows them, as signature mode does (Task 3). An MCP `coverage` tool reads the store (Task 4). Docs close it (Task 5).

**Tech Stack:** Elixir, Mix, OTP `:cover` (the `tools` application), Phoenix LiveView, JavaScript hooks (esbuild), CSS, Markdown.

**Spec:** `docs/specs/2026-09-28-grasp-tests-design.md` §Coverage (milestone 10.3) — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new tint", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching the indexer or the fixture also `mix test --include integration`; tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" (debounce) — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe at the top of `grasp/test/fixtures/regenerate.exs`; frozen fixture files never edited (`greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, lines 1–15 of `greet_controller.ex`); never `mix format` inside the fixture app. Existing viewer tests pass unmodified.
- Never run the real `gh`, `claude` or the network in tests. A test that runs a test suite runs the fixture app's (integration-tagged) or a fake command, never the host of the machine.
- Grasp is a dev-only dependency of its host: nothing here may require it in the host's test environment.

---

### Task 1: Clause and arm ranges on every record

**Files:** modify `grasp/lib/grasp/index/extract.ex` (definitions gain `clauses` and `arms`), `grasp/lib/grasp/index/builder.ex` (`function_json/1` writes them), `grasp/lib/grasp/index/changes.ex` (removed records carry them), the index record type where kinds are listed; regenerate the fixture index; tests in `grasp/test/grasp/index/extract_test.exs`.

**Rules (the spec, §Coverage, Clause gaps):**
1. `clauses` is the list of `[start_line, end_line]` of each clause of the definition, in source order: a multi-clause `def` gives one per clause, a single clause one, a test or setup block one. `start_line` is the clause's `def`/head line.
2. `arms` is the list of `[start_line, end_line]` of every arm, anywhere in the definition's clauses, of `case`, `cond`, `with … else`, `receive` (including `after`), `try`'s `rescue`/`catch`/`else`/`after` clauses, and a `fn` with more than one clause. An arm's range runs from its pattern's line through its body's last line. Nested constructs contribute their own arms. Sorted by `start_line`, then `end_line`.
3. Both are written into the JSON record as lists of two-element lists, `[]` when empty; a template record has `[]` for both.

- [ ] **Step 1: Tests.** Extract a source with a two-clause function, a `case` with three arms (one multi-line), a `with … else` with two else arms, a `cond`, a `receive` with `after`, a `try` with `rescue` and `else`, a two-clause `fn`, a one-clause `fn` (no arm), and a nested `case` inside a `case` arm. Assert exact `clauses` and `arms`. Run; expect failure.
- [ ] **Step 2: Implement.** Regenerate the fixture index with the recipe.
- [ ] **Step 3: Gates (with `--include integration`) and commit.** Message: `A record knows where its clauses and branches are` plus trailer.

---

### Task 2: `mix grasp.cover` and the coverage document

**Files:** create `grasp/lib/mix/tasks/grasp.cover.ex` and `grasp/lib/grasp/coverage.ex` (`Grasp.Coverage`: build, encode, decode, and the per-function reading); tests in `grasp/test/grasp/coverage_test.exs` and an integration test running the task in the fixture app.

**Rules (the spec, §Coverage, Run and The coverage document):**
1. `mix grasp.cover [--out PATH]` (default `.grasp/coverage.json`, beside the index path `:grasp, :index_path` names when it names one) runs `test_command ++ ["--cover", "--export-coverage", "grasp"]` with `System.cmd/3` in the project root, env `MIX_ENV=test` over the inherited environment, output streamed to the terminal (`into: IO.stream()`). `test_command` is `Application.get_env(:grasp, :test_command, ["mix", "test"])`. A non-zero exit is reported (`grasp: the test run exited with status N; coverage covers what ran`) and the task continues when the export exists; with no export it raises with the command's status.
2. It loads the index (`Grasp.Index.load/1` of the index path), then `Mix.ensure_application!(:tools)`, starts `:cover`, imports `cover/grasp.coverdata`, and for every imported module analyses `:calls` by `:line`. Lines map to files through the module's compile `source` made relative to the project root.
3. `Grasp.Coverage.build(index, lines_by_file, meta)` produces the document: `%{"version" => 1, "generated_at", "git_head", "index_generated_at", "functions" => %{id => %{"source_hash" => hex sha256 of the record's source, "lines" => %{"<line>" => count}}}}` for every non-removed application record (not a test, setup or test-path file) whose span has at least one counted line; lines outside a record's span are not attributed to it. The document is written with `Jason.encode!/2` (pretty) via a temp file and rename.
4. `Grasp.Coverage.decode/1` reads a document back; `Grasp.Coverage.for_function(coverage, record)` answers `:none` (no entry), `{:stale, entry}` (source hash differs) or `{:fresh, %{lines: %{line => count}}}`; `Grasp.Coverage.gaps(record, lines)` answers the clauses and arms (from Task 1's ranges) that hold at least one counted line and whose every counted line is zero, as `%{clauses: [[s, e]], arms: [[s, e]]}`.
5. `cover/grasp.coverdata` is left where Mix wrote it.

- [ ] **Step 1: Unit tests** for `build/3`, `decode/1`, `for_function/2` (none / stale / fresh) and `gaps/2` (a clause never entered, an arm never entered, an arm with no counted line not reported, a fully run function with no gaps), and for the task's argv/env with a fake `:test_command` that writes a canned coverdata file — or, if a canned coverdata is impractical, cover the argv/env with a fake command and leave the import to the integration test. Integration: in a temp copy of the fixture app (as the builder integration test sets up its runs — never write into `grasp/test/fixtures/sample_app`), run `mix grasp.index` then `mix grasp.cover`; the document holds an entry for a function the fixture's passing tests call, with a non-zero count on a line of it. Run; expect failure.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Gates (with `--include integration`) and commit.** Message: `mix grasp.cover writes what the suite ran` plus trailer.

---

### Task 3: The viewer shows coverage

**Files:** create `grasp/lib/grasp/coverage_store.ex` (`Grasp.CoverageStore`); modify `grasp/lib/grasp/application.ex` (child after `Grasp.IndexStore`), `grasp/lib/grasp_web/live/review_live.ex` (subscribe; the toolbar `coverage` toggle), `grasp/lib/grasp_web/components/card_components.ex` and `grasp/lib/grasp/highlight.ex` if lines are rendered there (per-line attributes, the stale note, gap marks), `grasp/assets/js/hooks/keys.js` (key `v`), the help dialog (`grasp/lib/grasp_web/components/help.ex`), `grasp/assets/css/app.css`; rebuild bundles; tests.

**Rules (the spec, §Coverage, Loading, Tint, Clause gaps):**
1. `Grasp.CoverageStore` holds the decoded coverage document in `:persistent_term` and polls its file's mtime every two seconds exactly as `Grasp.IndexStore` does (mtime read before the file; a missing file is no coverage and no error; a document that cannot be read is logged once per mtime and the previous one kept), broadcasting `:coverage_reloaded` on the `"coverage"` topic after a load. `get/0` answers the document or `nil`.
2. A card whose record has fresh coverage renders every counted line of its body with `data-coverage="run"` (count > 0) or `data-coverage="missed"` (count 0); in a diff body only inserted lines carry it. A stale card renders a `coverage stale` note in its header and no line attributes. A card with no entry renders nothing. Server-side, recomputed when the coverage or the index reloads, never per render of an unchanged card (reuse the highlight cache idiom or an assign keyed by coverage generation).
3. Gaps: the first line of each gap clause or arm carries `data-gap="clause"` or `data-gap="arm"` and a visually hidden text `never entered` for screen readers; the CSS draws a marker.
4. The toolbar gains a `coverage` toggle beside `signatures` (key `v`, `data-key="V"` in the toolbar's idiom), enabled only when coverage is loaded; toggling adds or removes a `grasp-coverage` body class client-side, as signature mode does, and CSS tints `[data-coverage]` lines and shows gap markers only under `body.grasp-coverage`. The help dialog gains the `v` row.
5. `Help`, `keys.js` and the toolbar order tests follow the existing patterns.

- [ ] **Step 1: Tests.** Store: poll picks up a written file, a bad file keeps the previous document, broadcast. View (with a coverage document written for the fixture index in the test): run/missed attributes on a fresh card's lines; a stale card's note and no attributes; a gap marker on a clause never entered; the toolbar toggle present and enabled with coverage, disabled without; the help row. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`.
- [ ] **Step 3: Gates and commit** (bundles). Message: `Cards show what the suite ran and what it never entered` plus trailer.

---

### Task 4: MCP `coverage`

**Files:** create `grasp/lib/grasp/mcp/tools/coverage.ex`; register it in `grasp/lib/grasp/mcp/server.ex`; update the tool-name list test (`grasp/test/grasp_web/mcp_test.exs`); tests in `grasp/test/grasp/mcp/tools_test.exs`.

**Rules (the spec, §Coverage, MCP):**
1. `coverage(function_id)` answers `{"id", "status": "fresh" | "stale" | "none", "run": [lines], "missed": [lines], "gaps": {"clauses": [[s,e]], "arms": [[s,e]]}, "generated_at"}` — `run`/`missed`/`gaps` empty unless fresh. An unknown id is the tools' usual not-found error. The description says how to get coverage (`mix grasp.cover`) when the status is `none`.

- [ ] **Step 1: Tests**, **Step 2: Implement**, gates, commit. Message: `The agent reads what the suite ran in a function` plus trailer.

---

### Task 5: Docs

**Files:** `docs/specs/2026-09-28-grasp-tests-design.md` (correct §Coverage sentences Tasks 1–4 found untrue; `### Known gaps (milestone 10.3)`: coverage counts only modules Mix's cover compiles — the project's `elixirc_paths` in the test environment — so a function in a dependency or in a test-only support file has none; a line `:cover` does not count (a clause head with no expression, a `do` line) stays untinted; macro-generated code counts on the line of the macro call; `mix grasp.cover` runs the whole suite), `docs/specs/2026-09-15-grasp-design.md` (§Milestones 10.3; Part 3 tool list; the index record's `clauses`/`arms`), `grasp/guides/reviewing.md` (the coverage toggle, tints, gaps, stale), a "Coverage" section in `grasp/guides/indexing.md` or a guide of its own linked from the README (`mix grasp.cover`, `:test_command`, what the document holds), `grasp/guides/getting-started.md` (toolbar list gains `coverage` (`v`)), `grasp/guides/agent.md` (the tool).

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: coverage` plus trailer.
