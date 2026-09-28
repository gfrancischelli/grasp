# Grasp Comments Per Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review thread belongs to the session it was written in: every session shows, lists, publishes and hands the agent only its own threads, so two reviews of one checkout never mix their comments.

**Architecture:** The store keeps one document and one id counter; each thread records its `session`, every read and write names one, and a thread read from a document written before threads carried a session belongs to `default` (Task 1). The LiveView, the session menu's delete, the MCP comment tools, `get_function`'s comments and the GitHub publisher pass the session they act for (Tasks 1–2). Docs follow (Task 2).

**Tech Stack:** Elixir, Phoenix LiveView, the MCP server (`anubis_mcp`), Markdown.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` §Comments (Part 2) and the comment tools (Part 3). This plan changes the rule that comments belong to the project: they belong to a session. The spec is corrected in Task 2 and is the authority once corrected.

## Global Constraints

- Public repo: never name any other project or a local filesystem path anywhere in the repo or commit messages; fixture names stay within `SampleApp`/`acme`. Every public Elixir function has `@doc` and `@spec`; every module a `@moduledoc`; HEEx components use `attr`, never `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new field", "today", "changed", "used to" are forbidden).
- Gates from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Read exit codes directly (`; echo $?`, never through a pipe); never commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce — re-run once and report both runs. Never `git add -A`; add by path; never stage `grasp/priv/static/assets/app.js`/`app.css`. Commit trailer exactly `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Existing tests that assert a thread is shared across sessions are the behaviour this plan reverses: update them to the per-session rule and list each in the report; every other existing test passes unmodified.
- Never run the real `gh`, `claude` or the network in tests.

---

### Task 1: The store and the viewer scope threads to a session

**Files:** modify `grasp/lib/grasp/comments.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/sidebar.ex` if it counts threads, `grasp/lib/grasp/session.ex` (delete); tests in `grasp/test/grasp/comments_test.exs`, `grasp/test/grasp_web/live/comments_live_test.exs`.

**Rules:**
1. A thread carries `session: String.t()`, the name of the session it was written in, given to `add/1` (`attrs.session`, required, a valid session name as `Grasp.Session.Disk` defines one — `{:error, :invalid}` otherwise) and encoded as `"session"`. A thread decoded without `"session"` belongs to `"default"`; one whose `"session"` is not a string is dropped as malformed, like any malformed thread.
2. `list/2` takes `session:` and returns only that session's threads; `list/2` without `session:` keeps returning every thread (the publisher and tests of the store use it deliberately). `by_function/1` takes the session name and groups that session's threads.
3. `fetch/1`, `reply/2`, `edit/3`, `set_resolved/2`, `delete/1`, `delete_reply/2`, `mark_published/2` keep addressing a thread by id. `fetch/2` with a session answers `:error` for a thread of another session; the LiveView uses it for every event that names a thread id, so a forged id from another session does nothing.
4. `delete_session/1` removes every thread of that session and broadcasts once; `Grasp.Session.delete/1` calls it, so deleting a session from the session menu takes its threads with it.
5. The broadcast on `"comments"` carries the session (`{:comments_changed, session}`), and a LiveView refreshes only for its own session's changes. Update every subscriber (grep `:comments_changed`).
6. `ReviewLive` reads and writes its own session's threads only: the canvas's threads, the sidebar's Comments group and its count, `open_comment`, composing (a new thread carries the session), reply, edit, resolve, delete.
7. The moduledoc says threads belong to a session, why (two reviews of one checkout are two conversations), and that the legacy rule maps an unsessioned thread to `default`.

- [ ] **Step 1: Tests.** Store: a thread added to session `a` is listed under `a` and not `b`; `by_function("b")` excludes it; a document without `"session"` decodes into `default`; a malformed `"session"` drops the thread; `delete_session/1` removes exactly that session's threads and broadcasts `{:comments_changed, name}`; `add/1` refuses a missing or invalid session. View: two LiveViews on sessions `a` and `b`; a comment written in `a` shows in `a`'s card and sidebar and not in `b`'s; a forged `comment_delete`/`comment_resolve` from `b` naming `a`'s thread id changes nothing; deleting session `a` removes its threads. Run; expect failure.
- [ ] **Step 2: Implement** rules 1–7.
- [ ] **Step 3: Gates and commit.** Message: `A thread belongs to the session it was written in` plus trailer.

---

### Task 2: The agent, the publisher and the docs follow the session

**Files:** modify `grasp/lib/grasp/mcp/tools/{add_comment,list_comments,reply_comment,resolve_comment,publish_comments,get_function}.ex`, `grasp/lib/grasp/mcp/comments.ex` if it needs the session, `grasp/lib/grasp/comments/publisher.ex`, `grasp/lib/grasp/agent/command.ex` (the system prompt's instructions about comments); docs `docs/specs/2026-09-15-grasp-design.md` (§Comments: threads belong to a session; the store's thread shape gains `session`; the comment tools' parameters), `grasp/guides/reviewing.md` (the "Comments belong to the project" paragraph), `grasp/guides/agent.md` and `grasp/guides/pull-requests.md` where they describe comments; tests beside the existing MCP and publisher tests.

**Rules:**
1. `add_comment`, `list_comments`, `reply_comment`, `resolve_comment` and `publish_comments` take a required `session` field, described as the card tools describe theirs. `add_comment` writes into it; `list_comments` lists it; `reply_comment` and `resolve_comment` refuse, with the tools' not-found error, a thread id of another session.
2. `get_function` takes an optional `session` and returns that session's threads on the function; without it, it returns none (rather than every session's).
3. `Grasp.Comments.Publisher.publish/2` takes `session:` (required) and publishes that session's threads only.
4. The agent's system prompt names the session for comment tools as it does for card tools.
5. Docs state the per-session rule, the `default` mapping for threads written before sessions were recorded — phrased as a durable fact about decoding ("a thread with no `session` belongs to `default`"), and that deleting a session deletes its threads.

- [ ] **Step 1: Tests** over the MCP endpoint (as existing tool tests call tools) for each rule, and a publisher test that only the named session's threads are posted (with the existing fake `gh`). Run; expect failure.
- [ ] **Step 2: Implement** and write the docs.
- [ ] **Step 3: Gates and commit.** Message: `The agent and the publisher act for one session's threads` plus trailer.
