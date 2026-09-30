# grasp CLI

Visual, language-agnostic code review as a standalone CLI. A single Go binary indexes a repo's
functions and call sites with tree-sitter, reviews branches and pull requests in worktrees, and
serves its own review canvas — no dependency added to the project under review, no other runtime
needed. Inspired by [gfrancischelli/grasp](https://github.com/gfrancischelli/grasp), fully
independent of it. See [SPEC.md](SPEC.md) for the design and roadmap.

**Languages:** Elixir, JavaScript/TypeScript (JSX/TSX included), Go. The index format is
language-neutral; more languages are a tree-sitter grammar plus an extractor away.

## Install

Requirements: Go 1.25+, a C compiler (the tree-sitter grammars compile in via cgo), `git`, and
the GitHub CLI (`gh`) signed in for the pull-request features. The chat panel and the MCP agent
run the [Claude Code](https://claude.com/claude-code) CLI, which is optional for everything else.

```bash
git clone https://github.com/gfrancischelli/grasp
cd grasp/grasp-cli
make install        # builds and symlinks into ~/.local/bin (PREFIX=... to change)
```

`make install` links rather than copies, so updating is just:

```bash
git pull && make build   # the installed grasp is the new build, nothing to re-install
```

> `go install …@latest` does not work yet: the Elixir grammar's Go module declares a path it is
> not served from, which needs the `replace` directive in go.mod — and `go install` ignores
> replaces. Clone and `make install`; prebuilt release binaries are on the roadmap.

## Quick start

```bash
cd any-repo
grasp init            # detect languages, base branch; pick a Claude profile; write .grasp/
grasp pr              # fuzzy-pick an open PR → worktree + index against its base
grasp web             # serve the canvas — it keeps the PR's index and opens the browser
```

Reviewing your own branch:

```bash
grasp web             # index the working tree against the base branch and serve
```

## Commands

| Command | What it does |
|---|---|
| `grasp init` | One-time repo setup: `.grasp/config.toml` (personal, gitignored), `.grasp/review.md` (committable team rules), `.gitignore` entries |
| `grasp pr [N]` | Open a PR in `.grasp/worktrees/pr-N` and index it against its base. No `N`: fuzzy picker over `gh pr list`. `--close` removes the worktree |
| `grasp index [--base REF]` | Write `.grasp/index.json` for the working tree (uncommitted and untracked work included) |
| `grasp web` | Serve the embedded review canvas on 127.0.0.1 (`--no-index` serves the index on disk, `--watch` reindexes when HEAD or the working tree changes, `--no-open`, `--port`) |
| `grasp publish [N]` | Send local comment threads to the PR as review comments via `gh`. Already-published threads are skipped |
| `grasp doctor [--ping]` | Show how everything resolves: repo, base, gh auth, agent binary + profile, index freshness |

## The canvas

The canvas is a whiteboard: cards stay where you put them, and a review **arrives already laid
out** — every changed function opens as a card, one column per module, modified cards showing
their diff, with edges drawn where one changed function calls another.

- **Drag a card by its header** (or Ctrl+drag from anywhere on it); drag the background to pan,
  hold Space to pan from anywhere; `⌘`+wheel zooms about the cursor, the wheel alone pans.
  `reset layout` re-stacks everything by call depth. Arrow keys walk the graph from the focused
  card. `s` turns every card down to its signature for a far-out view.
- **Click a call inside a card** and the callee opens to its right; the **callers menu** opens a
  caller to its left — each joined by a colored edge from the exact call site. Double-click an
  edge to jump to the card at its far end. Syntax highlighting for Elixir, JS/TS and Go.
- **`d` toggles diff/source** on the focused card; **`h` folds unchanged lines** into
  `⋯ n unchanged lines` expanders (a >100-line diff arrives folded; comment lines stay drawn);
  **`c` collapses to the header; `x` closes; `Shift+x` closes the whole subtree** nothing else
  reaches.
- **Click a line number to comment**, or drag across the numbers for a range (tinted). Works on
  the base side of a diff too. Threads persist in `.grasp/comments.json` under the main
  checkout — they survive `grasp pr --close` — and the sidebar's Comments group lists the open
  ones. Reply, resolve, delete inline.
- **Threads follow the code.** Each thread anchors to the text of its line: when the code moves
  — a new push reviewed, an agent edit, more work on the branch — the thread re-anchors
  wherever its text went on the next reindex. One that matches nowhere sits in the card's
  footer marked outdated; one whose function left the index shows muted in the sidebar as an
  orphan. Publishing an outdated thread falls back to a file-level comment that says so.
- **The sidebar is review-first**: Changes, open Comments, then Related — only the modules one
  call away from the change. The full module list stays behind a toggle; `⌘K` searches
  everything.
- **Sessions** keep the whole arrangement — cards, positions, views, pan and zoom — in
  `.grasp/sessions/<name>.json`, autosaved a moment after the canvas changes. A PR review names
  its session `pr-N` automatically; the header menu switches, creates and deletes sessions, and
  `?s=<name>` addresses one directly.
- **Live reload**: rewrite the index (`grasp index`, `grasp pr`) and the canvas redraws in about
  a second, keeping your session. The server answers loopback requests only (Host-checked,
  DNS-rebinding safe).

## The agent (`⌘I`)

The `ask` panel runs the configured agent CLI headless — Claude Code by default, under the
profile pinned at `grasp init` — with the reviewed tree (the PR's worktree, when reviewing one)
as its working directory, primed with the review's changed functions and `.grasp/review.md`.

- **read-only mode** gives it `Read`, `Grep`, `Glob` — it reads code and answers, edits nothing.
- **edit files mode** adds `Edit`, `Write` and a Bash narrowed to `mix`/`go`/`git status`/
  `git diff`/`git fetch`/`gh pr view` — nothing that changes the checked-out branch.
- Model select (default/haiku/sonnet/opus/fable), one run at a time, 60-turn cap, Stop kills
  the run, follow-ups resume the same conversation per session, `new` starts over.
- The agent gets **grasp's MCP server** wired in automatically (inline `--mcp-config`, no
  profile mutation), so it drives the canvas you are looking at.

## The MCP server

`grasp web` serves an MCP endpoint at `/mcp` on the viewer's port (loopback-only). The chat
panel's agent connects automatically; any MCP client can register it:

```bash
claude mcp add --transport http grasp http://127.0.0.1:4040/mcp
```

Reading tools answer from the index: `list_changes` (the first call of a PR review),
`search_functions`, `get_function` (source + callers + callees + open comments),
`get_callers`/`get_callees`, `find_paths` (call paths down to a function), `list_modules`,
`list_entry_points`, `reload_index`, `list_sessions`, `get_session`.

Arranging tools drive the browser tab reading the session, which applies and autosaves:
`set_cards` (replace the canvas with a whole graph in one call, laid out by the flow engine,
with per-card `group` titles framing flows apart), `open_card`, `close_card`, `focus_card`,
`set_view`, `highlight_card` (pans to a line and tints it), `group_cards`/`ungroup_cards`/
`rename_group`. Comments: `list_comments`, `add_comment` (line or range, either side),
`reply_comment`, `resolve_comment`, `publish_comments`.

Ask the chat "show me the flow from X into Y" and watch the chain assemble on the canvas.

## Claude profiles

If you keep several Claude Code profiles (`CLAUDE_CONFIG_DIR`: `~/.claude`, `~/.claude-work`, …),
`grasp init` asks which one this repo's reviews should use and pins it in the config. Every agent
spawn sets that env explicitly, and `grasp doctor` prints the full resolution.

## Indexing notes and limitations

- Call resolution is syntactic, per language:
  - **Elixir**: def/defp/defmacro clauses merged per name/arity; remote calls through aliases
    (`alias Foo.{Bar}`, `as:`), `__MODULE__`, imports (`only:` respected), captures `&fun/2`;
    pipe arity (+1) tried on lookup. No macro expansion — what `use` injects stays invisible.
  - **JS/TS**: same-file names, project-relative imports (default/named/namespace), unique
    project-wide names; JSX component tags are call sites; `forwardRef`/`memo`-style wrappers
    unwrapped. Path aliases (`@/`) not resolved yet.
  - **Go**: package-level calls across a directory's files, `pkg.Fn` through imports inside this
    module (via go.mod). Method calls on variables need type info and are skipped.
- Ambiguous or external calls are dropped rather than guessed.
- **Every changed file reaches the canvas.** A changed file the extractors have no function
  records for — a template, a stylesheet, a test DSL, a router — opens as a whole-file card
  with its diff, so coverage matches the PR's file list.
- Entry points (routes, workers) are not detected yet.

Groups read two flows apart on one canvas: select cards (`⌘`+click, or `Shift`+drag a box) and
`⌘G` frames them — the frame follows its cards wherever they go, its title (click to rename,
drag to move the whole group) stays readable at any zoom, a card opened from a member joins the
group, and dropping a card inside another frame moves it there. `⇧⌘G` or the frame's `ungroup`
takes the frame away, leaving the cards.

## Roadmap (SPEC.md has the detail)

Auto-review on open fed by `.grasp/review.md` (`--no-review` to skip) · pluggable agent
backends (Kimi, custom) · GitHub comment import ("sync from GitHub") · per-commit views ·
entry-point detectors.
