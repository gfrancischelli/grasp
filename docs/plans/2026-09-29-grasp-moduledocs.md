# Grasp Module Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every module's `@moduledoc` is part of the index, a card shows it rendered (with its source and, against a base, its diff), a review lists changed moduledocs, and the agent reads them with `get_module`.

**Architecture:** The extractor reads each module's moduledoc and the builder writes module records carrying the same card keys a function record does, classified against the base (Task 1). `Grasp.Index` answers module records by name and every reader of a card's id goes through `fetch_record/2`; the forest keeps module cards, and a module card renders the doc, source and diff views (Task 2). The sidebar lists changed moduledocs, the palette lists modules, comments on module cards open and publish (Task 3). MCP tools and the agent's prompt (Task 4). Docs (Task 5).

**Tech Stack:** Elixir (Sourceror, MDEx), Phoenix LiveView, the MCP server, JS (canvas hook), CSS, Markdown.

**Spec:** `docs/specs/2026-09-29-grasp-moduledocs-design.md` — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new card", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching the indexer also `mix test --include integration`; tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.*`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe at the top of `grasp/test/fixtures/regenerate.exs`; frozen fixture files are never edited (`greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, lines 1–15 of `greet_controller.ex`); never run `mix format` inside the fixture app. Existing tests keep passing unmodified except forced edits (list each in the report).
- Never run the real `gh`, `claude` or the network in tests.
- Performance: summaries and module lookups are built once per index load, never per render.

---

### Task 1: The index holds module records

**Files:** modify `grasp/lib/grasp/index/extract.ex` (read the moduledoc), `grasp/lib/grasp/index/builder.ex` (`module_json`, classification), `grasp/lib/grasp/index/changes.ex` (classify modules), `grasp/lib/grasp/index/incremental.ex` (rebuilt modules classified or preserved), `grasp/lib/grasp/index.ex` (readers), `grasp/test/fixtures/regenerate.exs` (carry each module's `change`/`base_source`/`base_doc`/`removed` by name, and removed module records, as it carries functions'), the fixture app (one non-frozen module gets a multi-line Markdown heredoc moduledoc; choose a file whose line shifts no test pins, or add lines only after everything a test pins), then regenerate `grasp/test/fixtures/index.json`; tests in `extract_test.exs`, `changes_test.exs`, `builder_test.exs`, `incremental_test.exs`, `index_test.exs`.

**Rules (the spec, §Index):**
1. Extraction per `defmodule`: the first `@moduledoc` among the module body's own top-level statements. A string, heredoc, or `~S`/`~s` sigil without interpolation → `doc: %{text: value, hidden: false}`; `false` → `%{text: nil, hidden: true}`; anything else → `%{text: nil, hidden: false}`; none → `doc: nil`. With a moduledoc, `span` is the attribute's `start_line`..`end_line` (heredoc closing line included, from `Sourceror.get_range/1`) and `source` those file lines joined with `\n`.
2. Module JSON: `name`, `file`, `line`, `behaviours` as today, plus `id` (= name), `kind: "module"`, `doc` (`{"text", "hidden"}` or `null`), and `span`/`source` when the module has a moduledoc. `change`/`base_source`/`base_doc`/`removed` written only when classified against a base, as functions'.
3. Classification (in `Changes`, beside functions', from the base extract's modules, matched by name): `added` head-has/base-lacks a moduledoc; `removed` base-has/head-lacks (a module absent from the head entirely becomes a module record with `removed: true` and its base `file`, `line`, `span`, `source`, `doc`); `modified` both have one and `source` differs, with `base_source` and `base_doc`; `unchanged` otherwise. For `removed`, `base_source`/`base_doc` also carry the base side. A module whose file is not among the compared files is `unchanged`.
4. Incremental: modules of rebuilt files get their moduledoc and are classified against the base like the functions of those files; without a base, the previous document's `change`/`base_source`/`base_doc` for that module name are preserved.
5. `Grasp.Index`: modules held keyed by name at load (beside the existing list, which keeps its order and shape for `modules/1`); `fetch_module(index, name) :: {:ok, module_record} | :error`; `fetch_record(index, id)` → `fetch_function/2`, else `fetch_module/2`; `changed_modules(index)` sorted by name; `moduledoc_summary(index, name)` — the text's first paragraph (up to the first blank line), Markdown emphasis/code markers and line breaks flattened to plain text with single spaces, truncated to 300 characters with `…`, `nil` without text; summaries computed once at load.

- [ ] **Step 1: Tests**: extraction for each doc form (string, heredoc, `~S`, `false`, interpolated, none, nested module not stealing its parent's); span/source of a heredoc; classification of each change kind including a module removed from the head and a moved module; incremental with and without base; the readers and `moduledoc_summary/2` (paragraph cut, flattening, truncation). Run; expect failure.
- [ ] **Step 2: Implement**, regenerate the fixture by the recipe. Gates (with `--include integration`); commit. Message: `The index reads each module's moduledoc` plus trailer.

---

### Task 2: The module card

**Files:** modify `grasp/lib/grasp/session/forest.ex` (prune and open through `Index.fetch_record/2`), `grasp/lib/grasp_web/components/card_components.ex` (dispatch to a `module_card`, the title's module link and tooltip), `grasp/lib/grasp_web/live/review_live.ex` (`open_module` event), `grasp/lib/grasp_web/chat_markdown.ex` (a code span that is a module name the index holds links too; expose what the card needs to render with its own `known?`), `grasp/assets/js/hooks/canvas.js` (a module label press that does not move pushes `open_module`), `grasp/assets/css/app.css`; rebuild bundles; tests in a view test file `grasp/test/grasp_web/live/module_card_live_test.exs`, `forest_test.exs`, `chat_markdown_test.exs`.

**Rules (the spec, §Module card):**
1. `open_module` with `%{"module" => name, "card" => from}` (or no `card`) opens the module card as a new root at the nearest free spot to `from` (the placement a new root opened from a card takes), or focuses it when open. The module part of a function card's title is a button sending it, with `title` = `Index.moduledoc_summary/2` or the module name.
2. A card whose id `fetch_record/2` answers as a module renders `module_card`: header (name, `module` badge, a badge per behaviour, change badge, `file:line` link/text as function cards do, collapse, close — no callers menu, tests badge, run, entry badges), body views `doc` (default; sanitized Markdown via ChatMarkdown, code spans naming held ids open cards through the chat's existing link event), `source` (highlighted numbered lines of `source`, line comments as function cards), `diff` (when `modified`, as function cards). The view toggle offers what applies. Hidden, no-moduledoc, and non-literal states read as the spec says. A removed module is drawn from its base as removed function cards are.
3. Session save/load keeps module cards; prune drops a card whose id `fetch_record/2` answers `:error`.
4. `data-module` of a module card's node is its name, so it clusters in its module's frame. It draws no edges and has no call sites.
5. The canvas hook: a press on `.module__title` that ends without moving pushes `open_module` with the label's `data-module`.

- [ ] **Step 1: Tests**: open from a function card's title (root, focus when open), tooltip text, each body view and state, the view toggle offering diff only when modified, a code span link, save/load with a module card and prune of a gone module, node `data-module`. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates; commit (bundles). Message: `A module card shows its moduledoc` plus trailer.

---

### Task 3: Reviews, comments and the palette

**Files:** modify `grasp/lib/grasp_web/components/sidebar.ex` (moduledoc rows in Changes), `grasp/lib/grasp_web/live/review_live.ex` (`open_comment` through `fetch_record/2`; the Changes row opens the module card, in diff view when modified), `grasp/lib/grasp/comments/*.ex` and `grasp/lib/grasp/publisher.ex` (anything reading `fetch_function` on a thread's id reads `fetch_record/2`), `grasp/lib/grasp/index.ex` (`search/3` lists modules by name, marked), the palette component; tests.

**Rules (the spec, §Module card Comments, §Review against a base ref, palette):**
1. Changes: for each module with a changed moduledoc, the first row under its heading is `@moduledoc` with its change badge, opening the module card (diff view when `modified`); a module whose only change is its moduledoc gets a heading. Untested changes and test pairing ignore module records.
2. Comments on a module card anchor to `source`/`base_source` lines, open from the comments list, publish to GitHub (tests stub the publisher's command as the existing publisher tests do). In the `doc` view the card's threads render in its footer.
3. The palette answers modules by name beside functions (same scoring, ids), each result marked `module`; choosing one opens the module card.

- [ ] **Step 1: Tests**: a hand-built index with a modified moduledoc (row, badge, opens in diff); a module whose only change is its moduledoc; a comment on a module card's source line listed, opened, published; footer threads in doc view; palette result for a module. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build` if assets change. Gates; commit. Message: `A review lists the moduledocs a branch changed` plus trailer.

---

### Task 4: MCP

**Files:** create `grasp/lib/grasp/mcp/tools/get_module.ex`; register it in `grasp/lib/grasp/mcp/server.ex`; modify `list_changes.ex` (`moduledocs`), `open_card.ex` (a module name opens a module card) and the session tool it uses, `grasp/lib/grasp/agent/command.ex` (the prompt names `get_module`); the tool-name list in `grasp/test/grasp_web/mcp_test.exs` is a forced edit; tests beside the other tool tests.

**Rules (the spec, §MCP):** `get_module(name)` answers `{"name", "file", "line", "behaviours", "doc", "hidden", "change", "base_doc"}` (`doc`/`base_doc` the texts or `null`); unknown → the usual not-found error; `list_changes` gains `"moduledocs": [{"module", "change"}]` sorted; `open_card` with a module name opens its card; the system prompt tells the agent to read a module's moduledoc with `get_module` before explaining its functions and to flag a moduledoc the branch made untrue.

- [ ] **Step 1: Tests.** Run; expect failure. **Step 2: Implement.** Gates; commit. Message: `The agent reads a module's moduledoc` plus trailer.

---

### Task 5: Docs

**Files:** `docs/specs/2026-09-29-grasp-moduledocs-design.md` (correct any sentence Tasks 1–4 found untrue), `docs/specs/2026-09-15-grasp-design.md` (§Milestones entry 11; index schema's module fields; Part 3 tool list gains `get_module`), `grasp/guides/reviewing.md` (module cards, the tooltip, the Changes row), `grasp/guides/agent.md` (`get_module`, `list_changes.moduledocs`), `grasp/guides/pull-requests.md` if it lists the Changes group's rows.

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: module docs` plus trailer.
