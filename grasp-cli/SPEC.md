# grasp CLI — Spec

> Working name. It collides with upstream [gfrancischelli/grasp](https://github.com/gfrancischelli/grasp)
> (Apache-2.0), from which this project derives the concept and the index format. Rename before
> publishing (candidates: `graspx`, `gcr`, `canvas-review`).
>
> **Decision (2026-09-22): full independence from upstream.** Everything that was Elixir has
> been reimplemented in Go — indexer (tree-sitter), viewer (embedded in the binary via
> `embed.FS`), comments, publish, MCP server. Nothing in the flow requires Elixir on the
> machine. Initial language focus: **Elixir, JS/TS and Go**.

## Vision

Visual, language-agnostic code review as a **standalone CLI** — never a dependency of the
project under review. Upstream grasp is an Elixir dev dependency mounted in the app's router,
which restricts it to Phoenix 1.8+/Elixir 1.19+ projects and needs per-project setup. This CLI
is a single binary that runs in any git repo:

```bash
cd any-repo
grasp init      # once per repo
grasp pr        # PR picker → worktree + index + web + review
```

What lands in the repo: only `.grasp/` (gitignored, except the team's review rules).

## Principles

1. **Central contract: `index.json` v1**, compatible with the upstream schema
   (`{version, project, git, review?, modules[], functions[], entry_points[]}`; each function
   carries `id`, `file`, `span`, `source`, `base_source`, `change`, `calls[{target, range}]`).
   Indexers and viewer talk only through it — either side is replaceable.
2. **Zero footprint in the reviewed project.** No dependency, no router mount, no framework
   version constraint.
3. **Pluggable agent.** Claude Code is the default backend, but the agent layer is an adapter —
   other CLIs (Kimi, custom) come in through config.
4. **Local review first; publishing is always explicit.** The agent and the reviewer write
   threads into `.grasp/comments.json`. Nothing reaches GitHub without a deliberate gesture.
5. **Everything in this repo is written in English** — specs, docs, code comments, commit
   messages, UI copy.

## Commands

| Command | Description |
|---|---|
| `grasp init` | Repo setup: detect languages, remote, base branch; pick the agent profile; write config + `.gitignore` entries |
| `grasp pr [N]` | Without `N`: fuzzy picker over open PRs. With `N`: direct. Worktree → index → done in one shot. `--close` removes the worktree |
| `grasp index [--base REF]` | Index the working tree (uncommitted and untracked work included) |
| `grasp web` | Serve the embedded canvas on 127.0.0.1; keeps a PR's index while its worktree lives (`--reindex` overrides); auto-bumps the port when taken |
| `grasp publish [N]` | Send local threads to the PR as review comments via `gh` |
| `grasp doctor [--ping]` | Show how everything resolves: repo, base, gh auth, agent binary + profile, index freshness |

## Configuration

```
~/.config/grasp/config.toml    # user-global defaults
.grasp/config.toml             # per-repo, PERSONAL — gitignored (profile paths are local)
.grasp/review.md               # review rules — COMMITTABLE (the team's standards travel with the repo)
```

```toml
[agent]
backend    = "claude-code"     # v2: "kimi", "custom"
command    = "claude"
config_dir = "~/.claude-work"  # the CLAUDE_CONFIG_DIR profile picked at init
model      = "opus"

[review]
base = "main"                  # autodetected: origin/HEAD
auto = true                    # v2: run a review when the canvas opens (--no-review skips)

[index]
languages = ["elixir"]         # detected at init

[web]
port   = 4040
editor = "vscode"              # file:line deep links — vscode | cursor | zed | idea
open   = true
```

### Claude profiles

Users with several Claude Code profiles (`CLAUDE_CONFIG_DIR`) get nondeterministic behavior
when a tool spawns `claude` with inherited env. So: `grasp init` discovers the `~/.claude*`
directories and asks which one this repo's reviews use; every agent spawn sets that env
explicitly; grasp's MCP server is passed inline per spawn (`--mcp-config`), never registered
into any profile; `grasp doctor` prints the full resolution and `--ping` proves auth.

## Indexing

- **tree-sitter, syntactic** — no compile, no toolchain needed in the reviewed repo:
  - **Elixir**: def/defp/defmacro with multi-clause merging, aliases (`alias Foo.{Bar}`, `as:`),
    `__MODULE__`, imports (`only:` honored), captures `&fun/2`, default-argument arities;
    lookup tries the written arity, then +1 for pipes. What macros inject stays invisible.
  - **JS/TS** (JSX/TSX included): same-file names, project-relative imports (default, named,
    namespace), unique project-wide names; JSX component tags are call sites; `forwardRef`/
    `memo`-style wrappers unwrapped. Path aliases (`@/`) not resolved yet.
  - **Go**: package-level calls across a directory's files, `pkg.Fn` through imports inside the
    module (via go.mod). Method calls on variables need type info and are skipped.
- Ambiguous or external calls are dropped rather than guessed: a wrong edge misleads a review
  more than a missing one.
- Change classification against `merge-base(HEAD, base)`: added/modified/unchanged/removed,
  with `base_source` carried for modified functions (parsed from the base blob).
- Future: per-language precision backends (SCIP, LSP call hierarchy) emitting the same
  index.json.

## The viewer

Embedded in the binary, served on 127.0.0.1 with a Host-checked loopback guard (DNS-rebinding
safe). A review arrives already laid out: changed functions open as diff cards, edges drawn
where one calls another.

- **Whiteboard canvas**: free card positions, header drag, background pan, cursor-anchored
  zoom, Space-pan, arrow-key graph walking, signature mode (`s`), collapse (`c`), close (`x`),
  Shift+`x` closes the unreachable subtree.
- **Layered flow layout** (simplified Sugiyama): callers left → callees right by longest path
  from each flow's entry points; barycenter sweeps untangle crossing edges; each connected
  component is its own horizontal band; edge-less cards sit in a grid section below; a function
  nothing calls wears an `entry` chip.
- **Cards** size to their code's width (capped); height scrolls. Syntax highlighting (Elixir,
  JS/TS, Go). Calls are clickable in source and in the diff's new side; the callers menu opens
  a caller to the left; per-call-site colored edges, double-click jumps to the far end.
- **Diff view** (`d`) against `base_source`, with unchanged-line folding (`h`; >100-line diffs
  arrive folded; comment lines stay drawn).
- **Comments**: click a line number, or drag across them for a range (GitHub-style); base-side
  lines of a diff take threads too. Reply, resolve, delete inline. Threads live in
  `.grasp/comments.json` under the main checkout and survive `grasp pr --close`.
- **Explicit GitHub flow**: the composer's "comment & send to GitHub", a per-thread "send to
  GitHub" button, and the header's "send review" box (publishes every unpublished thread and
  posts optional final considerations as a top-level COMMENT review). Range threads publish as
  GitHub's native multi-line comments (`start_line` + `line`).
- **Selection**: ⌘/Ctrl+click toggles, Shift+drag boxes; a selected card drags from anywhere
  and moves the whole selection; ⌘A all, Escape clears.
- **Groups/frames**: ⌘G frames the selection (⇧⌘G unframes); the frame follows its cards; the
  title renames on click, drags the whole group, and counter-scales with zoom; a card opened
  from a member joins the group; dropping a card inside another frame moves it there.
- **Undo**: every structural change (open/close, agent `set_cards`, reset layout, grouping)
  pushes a snapshot; ⌘Z walks back through the last 30.
- **Sessions**: the whole arrangement (cards, positions, views, groups, pan, zoom) autosaves to
  `.grasp/sessions/<name>.json`; a PR review names its session `pr-N`; the header menu and
  `?s=<name>` switch; live reload keeps the session when the index is rewritten.
- **Sidebar** is review-first: Changes, open Comments, Related (modules one call away, ranked
  by connection strength, top 8 + "show more", with caller/callee direction markers); the full
  module list sits behind a toggle; ⌘K is a fuzzy palette over everything.

## The agent

### Chat panel (⌘I)

Runs the configured agent CLI headless — the reviewed tree (the PR's worktree, when reviewing
one) as its working directory, the pinned profile in env, grasp's MCP server wired in inline.
The system prompt frames it as a gateway: answer exactly what the message asks, no tools or
review unless asked; review context is reference, not a standing instruction.

- **read-only mode**: `Read`, `Grep`, `Glob`, grasp's MCP tools.
- **edit files mode**: adds `Edit`, `Write` and a Bash narrowed to `mix`/`go`/`git status`/
  `git diff`/`git fetch`/`gh pr view`.
- Model select (default/haiku/sonnet/opus/fable), one run at a time, 60-turn cap, Stop, per-
  session conversation resume, `new` starts over.

### MCP server

`/mcp` on the viewer's port (loopback-only, hand-rolled streamable HTTP). Any MCP client can
register it: `claude mcp add --transport http grasp http://127.0.0.1:4040/mcp`.

- **Reading** (from a cached parse of the index): `list_changes`, `search_functions`,
  `get_function` (source + callers + callees + open threads), `get_callers`/`get_callees`,
  `find_paths`, `list_modules`, `list_entry_points` (no-caller approximation), `reload_index`,
  `list_sessions`, `get_session`.
- **Arranging** (published over the live-events stream; the tab reading the session applies and
  autosaves): `set_cards` (whole graph in one call; per-card `group` titles frame flows, a card
  with no group takes its parent's), `open_card`, `close_card`, `focus_card`, `set_view`,
  `highlight_card`, `group_cards`, `ungroup_cards`, `rename_group`.
- **Comments**: `list_comments`, `add_comment` (line or range, either side, authored "agent"),
  `reply_comment`, `resolve_comment`, `publish_comments`.

## Auto-review (v2 — specced, not built)

With `review.auto = true` and no `--no-review`, opening the canvas spawns the agent with a
prompt built from an embedded template + `.grasp/review.md` (the committable team rules) + PR
metadata. The agent works through the MCP tools — search, trace, open cards, write threads —
and its comments appear on the canvas live. Publishing to GitHub stays manual (principle 4).

## Pluggable agents (v2 — specced, not built)

The agent layer is an adapter with three responsibilities: spawn (command + args + env),
streaming (normalize output for the chat panel), and MCP wiring. `claude-code` is the default;
`kimi` and a `custom` backend (command template with placeholders) come in through
`[agents.*]` config sections. The viewer and the MCP tools stay backend-agnostic.

## Roadmap

| Milestone | Delivery |
|---|---|
| **v0** ✅ | `init`, `pr` (picker + worktree), tree-sitter TS/JS index, `doctor`. Validated against real builder-ui PRs and against the upstream viewer (2026-09-22) |
| **v1.1** ✅ | Elixir and Go indexers; embedded viewer (canvas, edges, palette, diff/fold, comments, SSE live reload, loopback guard); `grasp publish`. Validated: platform Elixir 7.1k functions/11.5k edges in 0.73s |
| **v1.2** ✅ | MCP server (22+ tools; canvas driven over the events bus); chat panel auto-wired via inline `--mcp-config`; layered flow layout; review-first sidebar; sessions; PR-index preservation; port auto-bump |
| **v1.3** ✅ | Multi-select, undo, drag-select comment ranges (published as native multi-line comments), explicit GitHub send (composer/thread/"send review"), groups/frames with agent tools, adaptive card width |
| **v1.4** ✅ | **Delivered 2026-09-22:** comment re-anchoring (text anchors, outdated/orphan states surfaced in the card footer and sidebar, arity-rename re-matching, file-level publish fallback); `grasp web --watch` (reindex on HEAD/working-tree change) |
| **v1 remaining** | Framework entry-point detectors |
| **v2** | Auto-review on open (`review.auto` + `.grasp/review.md`, `--no-review`), pluggable agent backends (Kimi, custom), GitHub comment import (below), per-commit views (below), issues as MCP context, precision backends (SCIP/LSP), JS path aliases |

### Designed, not yet built

**GitHub comment import ("sync from GitHub").** One-way, on-demand: a header button (and an MCP
tool) fetches the PR's review comments via `gh api pulls/N/comments`, maps `path` + `line`/
`start_line` onto threads (author = the GitHub login, marked as imported), and merges — a
comment whose `html_url` matches a local thread's `published_url` is ours coming back and is
skipped; replies group via `in_reply_to_id`. Imported threads render read-only at first;
answering them can go through the existing publish path (`in_reply_to`). Never automatic — same
principle as sending.

**Per-commit views.** The default canvas stays the whole review (merge-base → head). A sidebar
Commits group lists the PR's commits (`gh pr view --json commits` or `git log base..head`);
clicking one builds an index of the tree at that commit against its parent (checked out to a
temporary worktree or read via `git archive`, cached under `.grasp/commits/<sha>.json`) and the
viewer swaps to it, session-per-commit (`pr-N-<sha7>`). Costs one index build per commit
(~0.5–1s), built lazily on first click. Worth doing after entry points.

## Open questions and risks

- **Name** — collides with upstream; decide before publishing.
- **`go install @latest` is blocked** — the Elixir grammar module
  (github.com/elixir-lang/tree-sitter-elixir) declares its path as
  github.com/tree-sitter/tree-sitter-elixir, which forces a `replace` directive that
  `go install remote@latest` ignores. Install is clone + `make install` until the grammar is
  vendored or prebuilt binaries ship (goreleaser).
- **License** — pick one before publishing (Apache-2.0 keeps things simple next to the
  upstream inspiration and the grammar dependencies).
- **Heuristic precision** — if syntactic resolution proves too loose in practice, pull SCIP
  forward.
- **Upstream relationship** — the index schema is shared on purpose; worth talking to the
  author about a "bring your own indexer" mode before diverging further.
