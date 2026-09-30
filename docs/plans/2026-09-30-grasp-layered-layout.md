# Grasp Layered Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every card carries an architectural layer and a layer-floored column; **arrange** lays the canvas out as columns with rows ordered against crossings and modules kept together; a card opened later lands in its column and beside its module without moving anything.

**Architecture:** The server classifies each record into a layer (`Grasp.Layers`, computed at index load) and computes layer-floored columns per section (`Forest.columns_of/2`); nodes render `data-layer` and `data-column` (Task 1). A DOM-free `assets/js/layout.js` turns measured boxes, columns, edges and call lines into positions, tested with `node --test` driven from ExUnit; the hook's arrange pass uses it and the toolbar button reads **arrange** (Task 2). The hook's single-card placement gains the column and module rules (Task 3). Docs (Task 4).

**Tech Stack:** Elixir, Phoenix LiveView, plain ES modules, Node's built-in test runner, CSS, Markdown.

**Spec:** `docs/specs/2026-09-30-grasp-layered-layout-design.md` — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new layout", "today", "changed", "used to" are forbidden). Comments in `canvas.js` follow its existing long-form explanatory style.
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`; tasks touching `grasp/assets/**` run `mix assets.build` (no warnings) and commit `grasp/priv/static/assets/grasp.js`/`grasp.css`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.*`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe in `grasp/test/fixtures/regenerate.exs`; frozen fixture files are never edited (`greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex`, `router.ex`, lines 1–15 of `greet_controller.ex`); never run `mix format` inside the fixture app. Existing tests keep passing unmodified except forced edits (list each in the report).
- Never run the real `gh`, `claude` or the network in tests.
- No JS dependency and no `package.json`: `layout.js` tests use `node:test` and `node:assert` only.
- Performance: layers are computed once per index load, never per render.

---

### Task 1: Layers and layer-floored columns

**Files:** create `grasp/lib/grasp/layers.ex` (`Grasp.Layers`); modify `grasp/lib/grasp/index.ex` (hold `layers` keyed by record id / module name, computed in the load path beside `moduledoc_summaries`; reader `Index.layer/2`), `grasp/lib/grasp/session/forest.ex` (`columns_of/2`, and `sections/2` or an equivalent so the node list gets layer-floored columns), `grasp/lib/grasp_web/live/review_live.ex` (`nodes/4` passes each card's column and layer), `grasp/lib/grasp_web/components/card_components.ex` (`card_node` renders `data-column` and `data-layer`); tests `grasp/test/grasp/layers_test.exs`, `grasp/test/grasp/session/forest_test.exs` (or a new `forest_columns_test.exs`), a view test.

**Rules (the spec, §Layers and §Columns):**
1. `Grasp.Layers.layer(index, record_or_nil) :: :test | :html | :interfaces | :core | :private | :external`, first match wins, in the spec's order and with its exact rules (behaviour lists, name suffixes `HTML`/`Live`/`Components`/`Controller`, a first segment ending `Web`, entry-point modules, the core/private ancestor rule with the root namespace = first segment). A function takes its module's layer; a module record its own name's; a template is `:html`; `nil` is `:external`. `Grasp.Layers.rank/1` answers 0..5.
2. `Index.layer(index, id)` reads the precomputed map (function ids, module names, test ids); an id the index does not hold answers `:external`.
3. `Forest.columns_of(forest, layer_of)` where `layer_of` is a function `function_id -> layer`: per section, cycle-closing edges dropped (edges in opened order), column = max(1 + max caller column, layer floor), floors computed over the layers present in the section as the spec says, sources at their floor. `columns_of/1` and `depth/2` keep their behaviour.
4. Each node renders `data-column` (integer) and `data-layer` (the layer's name); `data-depth` unchanged.

- [ ] **Step 1: Tests**: every layer rule and first-match order over a hand-built index (a module both `...Web` and `Controller`, a LiveView, a `...HTML`, a context and its submodule, a submodule whose parent is not indexed, a `defp`, a module record, a test, a stub); columns: floors across layers, a missing layer, a core chain spreading right, a cycle, two sections, a card reached only from another section; node attributes in a view test over the fixture. Run; expect failure.
- [ ] **Step 2: Implement.** Gates; commit. Message: `Every card knows its layer and its column` plus trailer.

---

### Task 2: `layout.js` and arrange

**Files:** create `grasp/assets/js/layout.js` (pure ES module, named export `arrange(input)`), `grasp/assets/js/layout.test.mjs`, `grasp/test/grasp_web/layout_js_test.exs` (runs `node --test assets/js/layout.test.mjs` with `System.cmd`, asserts exit 0 and shows the output on failure; skips with a clear message when `System.find_executable("node")` is nil); modify `grasp/assets/js/hooks/canvas.js` (the pass after `reset_layout` — every card unplaced — calls `arrange` instead of the card-by-card loop, and pushes one `place_cards`; the card-by-card loop stays for a pass where some cards are placed), `grasp/lib/grasp_web/live/review_live.ex` (button text `arrange`, `data-tip="Arrange the canvas"`, id `reset-layout` kept); rebuild bundles.

**Interface:** `arrange({sections: [{group, head, cards: [{id, column, module, width, height}], edges: [{from, to, line}]}], gapX, gapY, sectionGap})` → `{id: {x, y}}` with integer coordinates. `line` is the call site's offset from the caller's top (or `null`). `head` is the room the section's frame takes above its first card. Sections stack in input order from y 0; components within a section stack in order of their first card.

**Rules (the spec, §Arrange):** column x from widest card of previous columns plus `gapX`; initial row order by call-site order; four barycentric sweeps (L→R, R→L, L→R, R→L) with same-module neighbours weighted 3 and edge-less cards taking their module's mean row in the neighbouring column; one module's cards adjacent in a column; a module's blocks in neighbouring columns sharing a top where the rows above allow; y at the call line when known, otherwise `gapY` under the card above, never overlapping the card above in its column. The hook detects "arrange" as a pass in which no card on the canvas has a position.

- [ ] **Step 1: Tests** (`layout.test.mjs`): column x with mixed widths; call-site order; a crossed pair uncrossed by the sweeps; module adjacency in a column; a module in two columns sharing a band; two components and two sections stacking with `head` and `sectionGap`; y at a call line and pushed below the card above; integer output. ExUnit wrapper test; button text in a view test. Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates (the wrapper runs inside `mix test`); commit with bundles. Message: `Arrange lays the canvas out in layered columns` plus trailer.

---

### Task 3: Opening a card beside its column and its module

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`placeCards` card-by-card loop), and, where the decision is pure, extract it into `layout.js` as a named export with tests in `layout.test.mjs`; rebuild bundles.

**Rules (the spec, §Opening a card):**
1. A card with an opener (or `near`) takes x = max(opener.right + GAP_X, left of the leftmost placed card of its section whose `data-column` equals its own); the sweep follows unchanged.
2. A card whose module already has placed cards in its section is placed against that module first: of the four spots round the cluster (the module frame when clusters are drawn, the bounding box of the module's cards otherwise), a spot in its own column or the next column wins over the rest; among those the nearest to the ideal spot wins. The call line never takes a card away from its module.
3. Roots and callers keep their rules; nothing already placed moves.

- [ ] **Step 1: Tests** for the extracted choice (column snapping, module-first spot choice, own-or-next column preferred, clusters undrawn using the cards' bounding box). Run; expect failure.
- [ ] **Step 2: Implement**, `mix assets.build`. Gates; commit with bundles. Message: `An opened card joins its column and its module` plus trailer.

---

### Task 4: Docs

**Files:** `docs/specs/2026-09-30-grasp-layered-layout-design.md` (correct any sentence Tasks 1–3 found untrue), `docs/specs/2026-09-15-grasp-design.md` (§Milestones entry 12; the Layout paragraph points at the layered layout), `grasp/guides/getting-started.md` (toolbar: **arrange**), `grasp/guides/reviewing.md` (how cards are laid out: layers, columns, modules kept together, arrange), the `canvas.js` header comment (the arrange pass and `layout.js`).

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: the layered layout` plus trailer.
