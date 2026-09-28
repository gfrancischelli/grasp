# The agent

Grasp serves an MCP endpoint beside the page, so a coding agent reads the same index the
canvas draws and arranges the cards the reviewer is looking at. The viewer can run that
agent for you from a panel over the canvas.

## The chat panel

Press ⌘I, or the `ask` button in the toolbar. Type what you want to understand and the agent
opens the cards that answer it.

The panel runs the [Claude Code](https://claude.com/claude-code) CLI headless, with the
indexed project's root as its working directory and Grasp as its only MCP server. Stop kills
the run, and New conversation starts over.

### The panel

An answer is rendered Markdown: its code fences are highlighted as the cards are, and every
`Mod.fun/arity` the index holds is a button that opens that function's card. The words
arrive as the model writes them, and while a run is live a status line under the log
carries three animated dots, the elapsed time and the number of tool calls this turn.
Consecutive tool calls fold into one group — "Used 4 tools" — each row naming in plain words
what the agent did and how long it took, open until the run moves past the group; a call that failed shows the tool's own words under it.
A turn ends with its cost, its number of turns and its wall time.

The prompt box grows to six lines: Enter sends, Shift+Enter breaks a line, and ArrowUp on an
empty box recalls what was sent before. A prompt sent while a run is live is queued — it is
drawn under the log with an × that withdraws it, and starts when the run ends; Stop and New
throw the queue away. An empty transcript offers a few prompts to start from, drawn from
what the index and the canvas hold: the branch's changes, the focused card, the open comment
threads, the first route.

The log follows the newest line only while you are at the bottom of it; read further up and
a "↓ latest" pill offers the way back down. A run that fails shows the CLI's output under
the error, with a Retry that asks the same question again. Every answer and every code fence
has a copy button.

### Read and edit mode

In `read-only` mode, the one it starts in, the agent's built-in tools are `Read`, `Grep` and
`Glob`: it reads the project's files and reaches the index through Grasp's own tools, and it
edits no file and runs no command.

The panel's Mode select switches that. In `edit files` the agent also gets `Edit`, `Write`
and a `Bash` narrowed to five commands: `mix`, `git status`, `git diff`, `git fetch` and
`gh pr view`. Nothing in that set changes the branch you have checked out. That is what makes
"address all the comments and update the diagram afterwards" something you can ask for: the
agent works a comment at a time — reads what the thread points at, makes the change, replies
with what it did and resolves the thread — then runs `mix format` on what it touched,
rebuilds the index with the same `mix grasp.index` flags the viewer is watching, and lays the
cards out again over the code as it now reads. Rebuilding needs Grasp installed as a
development dependency of the reviewed project, or there is no `mix grasp.index` task to run.

The switch takes effect on the next prompt, and survives New conversation.

Nothing is sandboxed: edit mode is the agent editing your working tree, so point it at a
branch you can throw away and read the diff before you keep it. When the index is a pull
request's, the edits land in the worktree instead, so an edit made on a review comment lands
on the pull request's code rather than on yours.

### Model, limits and settings

The Model select picks which model the CLI runs: the four aliases `haiku`, `sonnet`, `opus`
and `fable`, or `default` to leave the CLI on whatever `agent_model` set, or on its own
default when nothing did. A pick takes effect on the next prompt rather than interrupting a
live run, and survives New conversation.

One run at a time per session: a second prompt while one is in flight waits in the queue. A
follow-up continues the same CLI conversation, so the agent remembers what it just
opened. A single run is capped at 60 agent turns; one that reaches the cap stops there and
says so in the transcript. Transcripts live in memory and are gone when the viewer stops.

The CLI has to be installed and signed in already — the panel runs whatever `claude` your
`PATH` resolves to. Two settings change that:

```elixir
config :grasp, agent_command: "/opt/homebrew/bin/claude", agent_model: "opus"
```

`mix grasp.viewer` takes the same two as `--agent-command PATH` / `GRASP_AGENT_COMMAND` and
`--agent-model NAME` / `GRASP_AGENT_MODEL`.

## Registering the MCP server

Any MCP client can drive the same canvas. `Grasp.Plug` serves the endpoint at `/grasp/mcp`,
on the same port as the page, over Streamable HTTP. Register it with Claude Code:

```
claude mcp add --transport http grasp http://localhost:4000/grasp/mcp
```

Requests under the mount are answered only when addressed to loopback: `Grasp.Plug` checks
the `Host` the request was addressed to and the `Origin` the browser declares, so a page on
someone else's domain cannot reach it even if its DNS points at `127.0.0.1`.

## The tools

### Reading the code

- `search_functions` — find functions by name. An exact `Module.fun/arity` ranks first, then
  ids containing the query, then a fuzzy match.
- `get_function` — one function's source, span, calls, callers, callees, the entry points
  that reach it, and, given a `session`, that session's review comments still open on its
  lines.
- `get_callers` / `get_callees` — one hop up or down the call graph.
- `find_paths` — shortest call paths down to a function, from another function or, with no
  `from`, from whatever entry points reach it. Each path reads in call order and carries the
  entry point it starts at.
- `list_entry_points` — routes, LiveView and GenServer callbacks, Oban workers, each with the
  function it dispatches to.
- `list_changes` — every function the branch added, modified or removed, with the base ref it
  was compared against. The first call of a pull-request review.
- `list_modules` — modules with their file and the behaviours they implement.
- `reload_index` — reload the index file and report what it now holds: the path, how many
  functions, how many the branch changed, and the git refs. Call it as soon as
  `mix grasp.index` finishes.

### Arranging the cards

- `list_sessions` — the review sessions the viewer is running or has saved.
- `get_session` — every open card with what it calls and is called by, its position, the
  edges between them, the columns ordering each section by depth, and which card has focus.
  The ids it returns are what the other card tools address.
- `set_cards` — replace the whole canvas with a graph described in one call and lay it out
  afresh. Each card is `{key, function_id, parent_key?, group?, highlight?}`; a card hangs
  under an earlier one by naming its `key`, and two entries naming the same function are one
  card with an edge from each. `group` is a title: cards sharing one are framed together
  under it. A card that names no group takes its parent's. Nothing changes unless every card
  is good.
- `open_card` — add one card, called by another or standing on its own. A function already on
  screen gains an edge instead of a second card.
- `close_card` — close one card and the edges touching it.
- `focus_card` — scroll a card into view, to say "look here".
- `highlight_card` — point at one call inside a card, or shade a range of its lines.
- `set_view` — show a card as its `source` or as its `diff` against the base. Only a modified
  function has a diff. `context` says how much of that diff is drawn — `hunks`, `full`, or
  `auto` for hunks past 100 lines.
- `group_cards` — frame cards already open, under a title and joining the group already
  carrying it, or under a frame with no title. A card belongs to one group, so naming it here
  takes it out of the one it was in, and a group left with no cards is gone.
- `ungroup_cards` — take cards out of their groups, back to the unframed section.
- `rename_group` — give a group another title, or none, keeping its id and its cards.

A session name defaults to `default`, which is the canvas at `/grasp`; any other name is the
canvas at `/grasp/s/<name>` and is created on first mention.

### Comments

Every comment tool takes a required `session`, the session whose threads it acts on. A
comment belongs to the session it was written in, so the agent reads, writes, answers and
publishes only the threads of the session it is driving, and a thread id of another session
is answered as an unknown comment. The chat's system prompt names the session for the
comment tools as it does for the card tools.

- `list_comments` — the session's review threads, the reviewer's and the agent's own, with
  their replies. Open threads only unless `include_resolved` is set. Each
  one says where it now sits: `anchored` on `anchored_line`, `outdated` when the line it was
  written on has been edited away, or `orphan` when the function has left the index.
- `add_comment` — write a comment on a line, or on a range of lines, of the session, as the
  agent. `side` is
  `new` for the branch's code and `old` for the base version of a modified function, which is
  how a comment lands on a line the branch deleted; `end_line` covers everything from `line`
  to it, for a finding about a whole clause rather than about one line of it.
- `reply_comment` — answer a thread, as the agent.
- `resolve_comment` — close a thread once it is dealt with, or reopen one.
- `publish_comments` — post the session's threads to a pull request as review comments, each
  with its replies under it. See [Pull requests](pull-requests.md).

`get_function` given a `session` carries that session's open threads on the function under
`comments`, so reading the code and reading what the reviewer said about it is one call;
without a `session` it carries none.

## Example prompts

- "Show me the flow from the checkout route to the ledger." The agent calls
  `list_entry_points`, then `find_paths` for the hops between the two, then one `set_cards`
  with a card per hop — the route's action as the root, each callee under its caller, a
  single card wherever two hops meet on the same function, and a highlight on the call that
  matters. The browser redraws as the call lands, so you watch the chain assemble instead of
  clicking it out.
- "Address all the comments and update the diagram." Edit mode: a comment at a time, then a
  reindex and a fresh layout.
- "Open PR 1251." Edit mode: `mix grasp.pr 1251`, `reload_index`, `list_changes`, then
  `set_cards` one group per flow.
- "Publish the comments to the PR." `publish_comments`, in either mode.
