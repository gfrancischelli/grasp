# Grasp Test Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review of a pull request names the tests whose assertions it weakened and the added tests that assert nothing, and a test that mocks a behaviour with Mox draws a dashed edge to the implementations it stands in for — edges that never count as those implementations being tested.

**Architecture:** The indexer reads `Mox.defmock` declarations by parsing `test_helper.exs` and the test-only support files, recognises `expect`/`stub` sites in test bodies, and writes `double` calls from tests to the behaviour's implementations (Task 1). The viewer draws them dashed and keeps them out of reach (Task 2). `Grasp.Index` compares a modified test's assertions against its base at load and marks weakened and empty tests; the viewer shows the marks and a Test review group, and an MCP tool answers them (Task 3). Docs close it (Task 4).

**Tech Stack:** Elixir (Sourceror), Phoenix LiveView, the MCP server, CSS, Markdown.

**Spec:** `docs/specs/2026-09-28-grasp-tests-design.md` §Test review (milestone 10.5) — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new edge", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching the indexer also `mix test --include integration`; tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.*`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index is regenerated only by the recipe in `grasp/test/fixtures/regenerate.exs`; frozen fixture files never edited (`greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, lines 1–15 of `greet_controller.ex`); never `mix format` inside the fixture app. The fixture app has no Mox dependency: cover doubles with unit tests over source strings and hand-built definitions, not with the fixture. Existing tests pass unmodified except forced edits (list each).
- Never run the real `gh`, `claude` or the network in tests.
- Performance: the marks and double resolution are computed once per build or index load, never per render.

---

### Task 1: The indexer writes `double` edges

**Files:** create `grasp/lib/grasp/index/doubles.ex` (`Grasp.Index.Doubles`); modify `grasp/lib/grasp/index/extract.ex` (double sites in test bodies), `grasp/lib/grasp/index/builder.ex` (read the declarations, resolve the sites, write the calls), `grasp/lib/grasp/index/join.ex` and the call type if the kind list lives there, `grasp/lib/grasp/index/resolve.ex` if kept records must keep their double calls on an incremental refresh; tests in `grasp/test/grasp/index/doubles_test.exs`, `extract_test.exs`, `builder_test.exs`.

**Rules (the spec, §Test review, Doubles):**
1. `Grasp.Index.Doubles.declarations(sources)` parses each given source with Sourceror (never evaluates it) and answers `%{"Mock" => "Behaviour"}` for every `Mox.defmock(Mock, for: Behaviour)` (and `defmock` when imported), module names as the source writes them resolved through the file's `alias`es. `Builder` feeds it `test_helper.exs` under each test path and the test-only support files the test trace read.
2. Extraction records, in every definition's body, a double site for each call `expect(Mock, :fun, …)` or `stub(Mock, :fun, …)` — local, or `Mox.expect`/`Mox.stub` remote — whose first argument is an alias and second a literal atom: `%{mock, function, arity, range}` where `arity` is the parameter count of a literal `fn` third argument, else `nil`, and `range` covers the call's name.
3. The builder resolves each site of a test record: `Mock` → `Behaviour` via the declarations; the implementations are the indexed modules whose `behaviours` (the document's `modules[].behaviours`) include `Behaviour`; the targets are `Impl.fun/arity` (every arity of `fun` the implementation defines when `arity` is `nil`) that the index holds. Each target becomes a call `%{target, kind: :double, range, double: %{mock, behaviour}}`, written as `"kind": "double"` with a `"double"` object. A site whose mock is undeclared or whose behaviour has no indexed implementation adds nothing.
4. An incremental refresh keeps a test record's double calls (test records are refreshed on full builds only; make sure nothing drops them).

- [ ] **Step 1: Tests.** `declarations/1` over a source with two `defmock`s, one aliased, one with `import Mox`; extraction of double sites (local, remote, literal `fn` arity, non-literal third argument, a non-alias first argument ignored); builder resolution over hand-built definitions and a modules list (one behaviour, two implementations, one with two arities of `fun`) producing the calls; an undeclared mock producing none. Run; expect failure.
- [ ] **Step 2: Implement.** Gates (with `--include integration`); commit. Message: `A test's Mox expectations point at the code they stand in for` plus trailer.

---

### Task 2: Doubles on the canvas, never as reach

**Files:** modify `grasp/lib/grasp/index.ex` (the callers map used by `tests_for/3`, `path_back/4`, untested changes excludes `double` calls), `grasp/lib/grasp/highlight.ex` (the call site's `data-kind="double"` and title), `grasp/assets/css/app.css` (dashed like `route`/`enqueue`); rebuild bundles; tests in `grasp/test/grasp/index_test.exs`, `grasp/test/grasp/highlight_test.exs`, a view test.

**Rules (the spec, §Test review, Doubles):**
1. A `double` call renders as a call site with `data-kind="double"` and `title="Mox double of <Behaviour>"`, opens its target as any call does, and its edge is dashed.
2. `double` calls are not reach: `tests_for/3`, `path_back/4`, the untested-changes set and the paired changed tests ignore them. Whether they appear in `Index.callers/2` (the callers menu) is decided by this rule: they do not — a test doubling a function does not call it. State it in the `callers/2` doc.

- [ ] **Step 1: Tests**: a hand-built index where the only path from a test to a function is a `double` edge answers `tests_for == []` and lists it as untested; the callers menu omits it; the call site's attributes and title; the edge's CSS kind. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates; commit (bundles). Message: `A double is drawn, and never counts as a test reaching the code` plus trailer.

---

### Task 3: Weakened assertions and tests that assert nothing

**Files:** create `grasp/lib/grasp/test_review.ex` (`Grasp.TestReview`); modify `grasp/lib/grasp/index.ex` (compute the marks in `build/2`, stored like `untested`), `grasp/lib/grasp_web/components/card_components.ex` (badges), `grasp/lib/grasp_web/components/sidebar.ex` (the Test review group), `grasp/assets/css/app.css`; create `grasp/lib/grasp/mcp/tools/test_review.ex` and register it (tool-name list test is a forced edit); the agent's system prompt names the tool; rebuild bundles; tests.

**Rules (the spec, §Test review, Assertions compared and Where it shows):**
1. `Grasp.TestReview.assertions(source)` answers the assertion calls of a source as signature mode reads them (reuse the parse behind `Highlight.assertions/1` — move the call-finding into `Grasp.TestReview` and have Highlight call it, keeping Highlight's behaviour byte for byte), each as `%{name, text}` with `text` the call's source with runs of whitespace collapsed to one space, and for an `assert` whose argument is a binary operator, its `op` and its `left` text.
2. `Grasp.TestReview.review(record)` for a modified test (`change: "modified"`, kind `test`, a `base_source`) answers `{:weakened, reasons}` when: an assertion text of the base appears at the head fewer times than at the base (reason `removed: <text>`); an `assert_*`/`refute_*` name of the base is called fewer times at the head (`dropped: <name>`); an `assert` with `op` `==` or `===` at the base whose `left` text appears at the head in an assertion whose `op` is `=~` or `in`, or in a `match?` call, or as a bare `assert <left>` (`loosened: <text>`). For an added test (`change: "added"`) with no assertion it answers `:asserts_nothing`. Otherwise `:ok`. A source that does not parse answers `:ok`.
3. `Grasp.Index.build/2` computes the review of every changed test once and stores `test_review: [%{id, mark: :weakened | :asserts_nothing, reasons}]`, sorted by id; `Grasp.Index.test_review/1` reads it.
4. A marked test card wears `assertion weakened` or `asserts nothing`, with the reasons in its `title`. The sidebar's **Test review** group, after Untested changes, lists the marked tests (title as a test card titles itself, then the mark), each opening its card as a new root; it opens on arrival when it has rows, as Changes does.
5. MCP `test_review()` answers `{"tests": [{"id", "mark", "reasons"}]}`; `[]` without a base ref.

- [ ] **Step 1: Tests**: `assertions/1` (collapsed text, op and left of `assert a == b`); `review/1` for each weakening rule and its reason, a test reordering its assertions unmarked, an added empty test, a parse failure `:ok`; Highlight's assertion tests pass unmodified; the view's badges and Test review group with a hand-built index; the MCP tool. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates; commit (bundles). Message: `A review names the assertions a branch weakened and the tests that assert nothing` plus trailer.

---

### Task 4: Docs

**Files:** `docs/specs/2026-09-28-grasp-tests-design.md` (correct §Test review sentences Tasks 1–3 found untrue; `### Known gaps (milestone 10.5)`: assertions made through a remote helper are invisible to the comparison, so moving an assertion into a helper reads as removing it and a test asserting only through helpers reads as asserting nothing; the comparison is textual, so a renamed variable in an assertion reads as removing and adding one; `stub_with/2` and doubles made without Mox draw no edge; a mock declared outside `test_helper.exs` and the test-only support files draws no edge; doubles are recorded on full builds only), `docs/specs/2026-09-15-grasp-design.md` (§Milestones 10.5; Part 3 tool list; the call kinds list gains `double`), `grasp/guides/reviewing.md` (double edges, the marks, the Test review group), `grasp/guides/pull-requests.md` (the Test review group in the viewer list), `grasp/guides/agent.md` (the tool).

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: test review` plus trailer.
