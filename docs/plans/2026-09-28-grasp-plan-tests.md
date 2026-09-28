# Grasp Plan Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reader asks the agent to plan tests for a function or for a review's changes, and gets, on the canvas, one group per function under test with the tests that already reach it and a comment on every branch no test enters — a plan to review before any test is written; the same recipe reaches outside MCP clients as a `plan_tests` prompt.

**Architecture:** One module, `Grasp.TestPlan`, holds the recipe text for a target. The agent's system prompt embeds it and the chat panel offers two suggestions that ask for it (Task 1). An MCP prompt component serves it (Task 1). Docs close it (Task 2).

**Tech Stack:** Elixir, Phoenix LiveView, the MCP server (`anubis_mcp` prompt components), Markdown.

**Spec:** `docs/specs/2026-09-28-grasp-tests-design.md` §Agent-written tests (milestone 10.6) — the authority for every rule below.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new prompt", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Read exit codes directly (`; echo $?`); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` "two compiles inside one window are one update" — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.*`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Existing tests pass unmodified except forced edits (list each). Never run the real `gh`, `claude` or the network in tests.

---

### Task 1: The recipe, the chat suggestions, the MCP prompt

**Files:** create `grasp/lib/grasp/test_plan.ex` (`Grasp.TestPlan`), `grasp/lib/grasp/mcp/prompts/plan_tests.ex`; modify `grasp/lib/grasp/mcp/server.ex` (register the prompt), `grasp/lib/grasp/agent/command.ex` (the system prompt embeds the recipe), `grasp/lib/grasp_web/live/review_live.ex` (`chat_suggestions/4`); tests in `grasp/test/grasp/test_plan_test.exs`, `grasp/test/grasp/agent/command_test.exs`, the chat suggestions' view test, an MCP test for `prompts/list` and `prompts/get`.

**Rules (the spec, §Agent-written tests):**
1. `Grasp.TestPlan.recipe/0` is the recipe as the spec's first bullet states it, as instructions to the agent naming the tools by their MCP names; `Grasp.TestPlan.request(target)` answers the words that ask for it — `"Plan tests for <function id>"` or `"Plan tests for the changes"` for `:changes`.
2. The agent's system prompt contains `recipe/0` under a heading the other recipes use, in both modes (read mode arranges cards and comments, which it may; the recipe's run step says that in read mode it leaves running to the reader).
3. `chat_suggestions/4` offers `TestPlan.request(focused)` when a card is focused and `TestPlan.request(:changes)` in a review against a base ref, beside the existing suggestions, in the order: what changed, plan tests for the changes, explain the focused card, plan tests for it, publish, the route.
4. The MCP prompt `plan_tests` (an `Anubis.Server.Component, type: :prompt`; read the prompt component's behaviour in `deps/anubis_mcp/lib/anubis/server/component/prompt.ex`) takes `target` (required: a function id or `changes`) and `session` (required, the session name rule the tools use) and answers one user message: the request, the recipe, and the session to lay cards out in. An unknown function id is an error.

- [ ] **Step 1: Tests** for each rule (the prompt over the MCP endpoint as tools are called: `prompts/list` lists it with its arguments; `prompts/get` answers the message; an unknown id errors). Run; expect failure.
- [ ] **Step 2: Implement.** Gates; commit. Message: `The agent plans tests on the canvas before it writes one` plus trailer.

---

### Task 2: Docs

**Files:** `docs/specs/2026-09-28-grasp-tests-design.md` (correct §Agent-written tests sentences Task 1 found untrue; §Milestones marks 10.1–10.6), `docs/specs/2026-09-15-grasp-design.md` (§Milestones 10.6; Part 3 gains the prompt), `grasp/guides/agent.md` (the recipe, the two suggestions, the prompt), `grasp/guides/running-tests.md` or `reviewing.md` where agent-written tests fit.

- [ ] **Step 1:** Write; verify every sentence against HEAD. **Step 2:** Gates; commit. Message: `Docs: agent-written tests` plus trailer.
