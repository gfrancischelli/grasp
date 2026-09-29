# Reviewing

The canvas, the cards on it, the edges between them, the comments you leave on their lines,
and the sessions that keep it all where you put it.

## The canvas is a whiteboard

Cards stay where you put them. A new card opens beside the card it was opened from, in the
clear space nearest the call that opened it, and nothing already on the canvas moves to make
room for it. `reset layout` in the toolbar lays everything out again.

- Drag a card by its header to move it, or hold Ctrl and drag from anywhere on it. Ctrl and
  press over a card is the drag gesture, so the context menu is suppressed there; a plain
  right-click still opens it.
- Hold Alt and drag a card to carry the whole flow: every card joined to it by an edge,
  callers and callees alike, travels with it and keeps its shape, so one flow is moved clear
  of another in a gesture. What travels is what you can see joined up — a card whose callee
  is closed carries nothing at that end.
- Drag the background to pan; hold Space to pan from anywhere, cards included.
- ⌘ or Ctrl with the wheel zooms about the cursor; the wheel alone pans, except over
  something that can scroll itself. The zoom runs from 5% to 250%.
- Arrow keys walk the graph from the focused card.
- `?` opens the list of every key and gesture, the toolbar's `?` button with it. Escape, the
  backdrop or its close button puts it away.

Placement is a heuristic: it avoids overlap at the moment a card is placed. A card that
later grows — a diff opened, a thread written — pushes the cards under it down by as much
as it grew, and the cards those run into after them, and when it shrinks back, the cards
it pushed return, as long as they are still where the push left them; a card dragged onto
another stays where it is, and a push moves cards rather than frames, so a grown card can
reach into another group's frame. `reset layout` untangles them. Each group is laid out
below the groups already down and clear of their frames, so a canvas laid out in one go
reads as a stack of frames a gap apart; dragging a card or a frame across another is free
to overlap them, and `reset layout` puts them back in their bands.

### Groups and frames

A group of cards is drawn as a frame round the cards themselves, wherever on the canvas they
sit, so two flows on one canvas are read apart rather than run together. The frame follows
its cards: drag one to the edge of a flow and the frame grows with it, header and all. The
header carries the title, how many cards are in it, and `ungroup`, which takes the frame
away and leaves the cards where they were. A title is a label rather than a requirement — a
frame may stand with none, and its heading then reads "Untitled group". Cards in no group
make a last, unframed section under the framed ones.

- **Shift+click** a card to pick it out; Shift+click again to put it back. Its code is the
  comment gutter's, so Shift there stretches the range being written rather than picking the
  card out. Selected cards wear a dashed outline. A plain click says which card you mean
  instead, so it lets the selection go — as do opening a card from the sidebar or the
  palette, and Escape. A card that closes leaves the selection with it. The selection is this
  tab's own: another tab reading the same session sees the frames you make, not the cards you
  are picking.
- **⌘G** frames the selected cards, or the focused card when nothing is selected. **⇧⌘G**
  takes the selected cards back out of whatever frames they are in, leaving them selected,
  so they can go straight into another one.
- **Drag a frame's title** to move the whole group: every card inside travels together and
  keeps its place relative to the others. A click on the title, with no drag, renames the
  group in place — Enter saves, a blank name leaves the frame with none, Escape or clicking
  away leaves it as it was. The group keeps its id and its cards, so an agent holding that
  id still finds it.
- **Drop a card inside another group's frame** — on a card there, in the space between them,
  on the padding at its edge — to move it to that group; drag a selected card and the rest
  of the selection goes with it. Dropping it anywhere else moves the card and nothing more.
- A frame's title keeps its size at any zoom, so you can read which group is which from far
  enough out that the cards inside it are specks.

A card opened from another — a callee by clicking a call, a caller from the callers menu —
joins the group of the card it was opened from when it is new to the canvas, so it lands
beside that card inside the same frame.

### Module clusters

Inside each group, the cards whose functions come from one module are framed together under
the module's name, in a lighter frame within the group's own. A flow then reads as the
modules it passes through rather than as a row of cards, and the cards in no group cluster
the same way. Which cluster a card falls into follows from the function it holds and nothing
else, so there is nothing to create and nothing to name.

- **Drag a module's label** to carry every card of that cluster together, the way a frame's
  title carries a whole group. The label opens nothing: it names the cluster, and a press
  that does not move does nothing.
- **The cards inside a cluster are yours to arrange.** Nothing snaps, sorts or stacks them —
  put them side by side, one under another or well apart, and the frame closes round wherever
  they stand, as a group's frame does.
- **modules** in the toolbar, or the `m` key, draws the frames or takes them away. While they
  are drawn a card's header reads `fun/arity` alone, since the frame round it carries the
  module name. Dropping the name narrows a card whose title is its widest line — a stub, or a
  card with a short body; a card whose code is wider than its title keeps its width.
- **A card lands beside its module.** Open a call to a module that already has cards in that
  flow and the card is placed against that cluster rather than beside the call, so a module
  stays in one block as the flow grows. The first card of a module lands beside the call that
  opened it, like any other.
- A cluster belongs to one flow, so a module open in two flows is framed once in each. A
  module frame decides nothing about membership: where a card lands is still read from the
  group frames alone.

## Cards

A card is one function: its header, its `file:line`, and its syntax-highlighted source with
every call it makes clickable.

- **Calls.** Click one to open the callee to the right. Calls the compiler reports at a
  position nothing in the source can be clicked — code a macro generated, or a call in an
  interpolation the extractor could not place — are listed in the card's "Also calls"
  footer.
- **The callers menu** opens a caller to the card's left. Open several and the card keeps
  one edge from each of them. It counts and lists the application's callers first; the
  test suite's setups and helpers that call the function sit under a **Test helpers**
  heading after them, and the tests that call it are listed with the other tests (below).
  A press anywhere else on the canvas closes it.
- **`file:line`** links into your editor when `editor` is configured. A removed function's
  `file:line` is the base commit's, so it is printed rather than linked.
- **Badges.** A card wears a badge for the entry point it is, and in a review against a base
  ref for what the branch did to it. A modified card counts its lines (`+3 −1`) beside the
  title.
- **`diff` / `source`** in a modified card's header swaps its body between the branch's
  source and the diff against the base — deleted lines from the base, inserted lines from
  the branch, highlighted as code either way. The `d` key does the same to the focused card,
  and passes over a card with nothing to compare.
- **`changes only` / `all lines`** folds the unchanged lines away, the way a pull request
  shows a file: the changed lines, three lines of context on either side, every line a
  comment sits on, and one `⋯ n unchanged lines` row per stretch in between, which draws its
  lines when clicked. A function longer than 100 lines arrives folded; a shorter one arrives
  whole. The `z` key does the same to the focused card.
- **Collapse** (`c`) hides the body and leaves the header. **Close** (`x`) takes the card
  off the canvas; `Shift+x` closes it together with everything that had no other way to be
  reached.
- **Signature mode** (`s`, or `signatures` in the toolbar) turns every card down to its
  signature: the body goes, and the header and the syntax-highlighted line naming the
  function are scaled up so they stay readable however far out you are. The header's buttons
  keep working, so you can close or collapse a card without leaving the mode. A test card
  shows its assertions there instead (see below).

A `.heex` template is a card like any other, its markup highlighted and its `file:line`
linked into your editor. A component tag inside it — or inside a `~H` body — is a call site
you click to open the component, and a controller's `render` opens the template it names, so
a route reads through its action and its page into the contexts underneath.

### Tests

A test is a card too, and so is a `setup` block. A test card wears a `test` badge and is
titled with the test's name as written, its `describe` — or its module, outside any — where a
function card prints its module; a setup card wears `setup` and is titled `setup` or
`setup_all`. The body is the test's source, its calls clickable like any other, so a test
opens the code it exercises the way a function opens its callees.

In signature mode a test card reads what it promises: under its title, its assertions — every
`assert`, `refute`, `assert_*` and `refute_*` written as a local or imported call or as any
stage of a `|>` pipeline — each whole across the lines it spans, a piped one from the line its pipeline
starts on, in source order and highlighted as code. A test that asserts nothing, an assertion
made through another module's helper (`Helpers.assert_ok(x)`), and a setup show the title
alone.

The sidebar's **Tests** group, after the entry points, lists the test modules by file. Each
opens into its setup callbacks, then its tests under their `describe` headings, then the
helpers it defines; a support module under the test paths — a case template, a factory — is
listed there too, and none of them in the Modules group. Clicking a test opens its card. The
palette finds a test by the words of its module, `describe` and name.

### Tested by

A function card that any test reaches wears an `n tests` badge in its header. A test reaches
a function when it calls it, or calls something that does, within four calls; a `setup`
block reaching it counts for every test of its module. A test or setup card wears no such
badge, and neither does a card no test reaches.

The badge opens the callers menu, which lists the tests under a **Tests** heading after the
callers, nearest first, each titled by its `describe` and name and marked `direct` or with
the number of calls between them. A direct test opens to the card's left as a caller does. A
farther one opens the whole path back to it, each function on the way opened as a caller of
the next, so every edge the canvas draws is a call; a folded card on the path unfolds. A
test that reaches the function nearest through its module's `setup` opens the path to that
setup.

In a review against a base ref, every function the branch added or modified that no test
reaches is marked `untested` in the Changes group, and an **Untested changes** group, open
whenever it has any, lists them. Under each changed function the Changes group lists the
tests the branch added or modified that reach it, so code and tests changed together read
as pairs; clicking one opens the test's card. Tests, setups, removed functions and files
under the test paths are never counted as untested.

Reach is read from the calls the compiler saw: a test that reaches a function only through
`apply/3`, a function passed as a value, a behaviour dispatched at runtime or a test double
is not counted, and a function more than four calls from every test reads as untested. A Mox
double is drawn on the canvas (see [Edges](#edges)) but never counts as reach.

### Test review

In a review against a base ref, the tests the branch touched are read for what they stopped
promising. Assertions are compared by their parsed form, so reformatting one, moving it to
another line or editing a comment beside it changes nothing.

- **`assertion weakened`** marks a modified test when it makes fewer assertions than the
  base did (`removed:` and the assertion), calls an `assert_*` or `refute_*` function fewer
  times (`dropped:` and its name), or turns an `assert left == right` (or `===`) into one
  that accepts more — `left =~ …`, `left in …`, a `match?/2` on `left` or a bare
  `assert left` (`loosened:` and the assertion). Hovering the badge reads the reasons. An
  edit that keeps the number of assertions, such as a different expected value, is not a
  weakening unless it drops an `assert_*`/`refute_*` call or loosens an equality: renaming
  `assert_receive` to `assert_received`, or replacing an `assert_*` helper with a plain
  `assert`, keeps the count and still reads `dropped:`.
- **`asserts nothing`** marks an added test with no assertion in its body.

Both are badges on the test card, and the sidebar's **Test review** group, after Untested
changes and open whenever it has a row, lists every marked test with its badge; clicking
one opens the test's card. Only assertions written in the test count: a test that asserts
through a helper reads as asserting nothing, and moving assertions into a helper reads as
removing them.

### Coverage

Once `mix grasp.cover` has written what the suite ran (see [Coverage](coverage.md)), the
cards can show it. **coverage** in the toolbar, or the `v` key, turns the mode on and off;
the button is disabled while no coverage is loaded.

- **Tints.** A line the suite ran is tinted green and a line it never ran red. A line the
  coverage does not count — a bodiless head, a `do` line, a blank line — stays untinted. In a
  diff only the inserted lines are tinted, so the tint reads on what the branch wrote.
- **Gaps.** A clause, or an arm of a `case`, `cond`, `with`'s `else`, `receive`, `try` or
  multi-clause `fn`, that holds a counted line and never ran any of them is marked with a bar
  on its first line: the suite never entered it. A clause and an arm starting on the same line
  are marked as the clause.
- **Stale.** A function whose source changed after the coverage was written says `coverage
  stale` in its header and tints nothing, since its counts describe another body. Run
  `mix grasp.cover` again to bring it back.

The mode is this tab's own and draws nothing outside it, so a canvas read without it looks as
it always does.

### Runs and results

Tests run from the canvas, and their results show on the cards (see
[Running tests](running-tests.md) for the task and the results document).

- **Run controls.** `run` on a test card runs that test, `run all` in the callers menu's
  Tests section runs every test listed there, and `run changed tests`, at the top of the
  Changes group when the branch added or modified tests, runs those. One run goes at a
  time: while one is under way each control is disabled and says what is running.
- **The runs panel.** **runs** in the toolbar opens it where the chat panel floats, and
  opening either closes the other; starting a run opens it too. It names the run, says
  whether it is running, finished, failed with its exit status, or cancelled, and streams
  the suite's output, the last 200 lines of it, with `cancel` while it runs and
  `run coverage` beside it. The run is shared by every tab.
- **Badges.** A test card wears its latest result — `passed`, `failed`, `skipped`,
  `invalid` for a test whose module's `setup_all` failed — or `stale` once the test changed
  after it ran. A function card's tests badge adds how many of its tests are failing,
  `3 tests · 1 failing`.
- **Failures.** A failed test card draws each error under the line of the test its
  stacktrace passed through: the message, an assertion's `left` and `right` as ExUnit
  printed them, and the stacktrace, each frame outside the index said to be. It is the
  result, not a comment, and goes when the result goes stale. **open failure** in the
  header opens the stacktrace's indexed frames as a chain of callees from the test, each
  card with the line the failure passed through highlighted, so the path from the red test
  to the code that raised is on the canvas.

## Edges

An edge runs from a card to each card its open calls reach, one line per callee however many
times the card calls it, leaving from the card's header rather than from the call. It takes
the colour the calls to that callee are painted in, so the calls in the body say which line
is theirs, and arrows into the callee, drawn beneath the cards so a line never covers their
code. Double-click an arrow to jump to the card at its far end — the
caller or the callee that is out of sight — which takes focus and pans into view.

A dashed edge is a hop rather than a function call, and its call site is underlined with dots
instead of dashes. One kind is a hop over HTTP: a link, a form action, an `hx-*` attribute or
a `~p` sigil the router resolved to the action or LiveView it maps that path to, hovering it
reading the verb and path the router matched. Another is a job put on a queue: a
`Worker.new(...)` in front of an `Oban.insert` opens the worker's `perform/1`, so the
function that queues the work is a caller of the work itself, and hovering the call reads the
worker and the queue it runs on.

A request a test makes is a hop over HTTP too: `get(conn, ~p"/greet")`, `post(conn,
"/bonuses", params)` or `live(conn, "/greet/live")` draws a dashed edge from the test card to
the action or LiveView the router maps that path to, so an interface-level test reads through
the route into the code it drives.

A test double is a hop too. A Mox `expect(Mock, :fun, …)` or `stub(Mock, :fun, …)` in a test
draws a dashed edge to `fun` of every application module implementing the behaviour the mock
is declared for — `Mox.defmock(SampleApp.GeoMock, for: SampleApp.Geo)` in `test_helper.exs`
or a support file — at the arity of the `fn` or capture it is given, or at every arity of
`fun` for any other code. The `expect` or `stub` call itself is the double's site: clicking it
opens the first implementation by id, and hovering it reads the behaviour and every
implementation, `Mox double of SampleApp.Geo: SampleApp.Geo.Http, SampleApp.Geo.Static`.
Each other implementation is a button in the card's **Also calls** footer, whose edge is
dashed as well. The mock answers in the code's place, so the edge shows what the test stands
in for, never a caller: the doubled function's callers menu leaves the test out, and the
test does not count as reaching it.

## Comments

Click a line number to comment — hover it first for the `+` that marks it clickable. Drag
down or up the line numbers to comment on a range of lines instead of one, and Shift+click a
line number while the composer is open to stretch the range to it, or back to a single line.
⌘/Ctrl+Enter saves, Escape cancels. A thread takes replies, and can be resolved, reopened or
deleted. A resolved thread collapses to one line and expands on click.

**edit** beside a comment or a reply opens a box in its place holding its text; save the
rewrite and the entry is marked `edited`. A comment already published to a pull request
changes here only: GitHub keeps the text it was sent, so edit it there too.

In a diff body the line numbers on the base side are clickable the same way, so a thread can
land on a line the branch deleted. A range runs down one side: a drag that crosses to the
other side's numbers stops where it left its own.

A ranged thread tints every line it covers and sits under the last of them. A drag released
below a fold covers the lines the fold hides, and the thread it opens unfolds them.

A thread whose line moved re-anchors wherever its text went. One that matches nowhere sits
in the card's footer, marked outdated. One whose function has left the index is listed muted
in the sidebar and draws nothing.

The sidebar's Comments group lists every open thread of the session under its module and
jumps to the line when you click it.

Comments belong to the session they were written in. Two sessions on one checkout are two
reviews — say, two pull requests read side by side — and each keeps its own conversation: a
comment shows on the cards of its own session, and another session drawing the same function
does not show it. Deleting a session from the session menu deletes its comments with it.
Every session's comments are kept in one file, `.grasp/comments.json` under the directory
Grasp was started in; a thread in that file with no `session` belongs to `default`. The file
travels with the checkout — commit it alongside the changes it
is about if you want the discussion to go with the branch, or add it to `.gitignore` if you
would rather keep review chatter out of the repository.

An agent reads and answers the threads of the session it is driving, and can post them to
GitHub. See
[The agent](agent.md) and [Pull requests](pull-requests.md).

## Sessions

A session is one canvas: the cards on it, how they are grouped, where each one sits and
which one has the focus. The session named `default` is the canvas at `/grasp`; any other
name is the canvas at `/grasp/s/<name>`, so a review of one pull request and a walk through
a subsystem sit side by side instead of on top of each other.

The sidebar's header names the session being read and opens the menu of every session the
viewer is running or has saved. A row there goes to that canvas, the × beside it forgets the
session — its file and the agent conversation held under its name go with it — and the field
under the list opens a session by name, existing or new. Session names are letters, digits,
`-` and `_`, up to 40 characters. Deleting the session a tab is reading sends that tab to the
default canvas; deleting `default` itself clears it rather than taking it away, since the
next visit starts it again, empty.

Each session is a file under `.grasp/sessions/` in the project Grasp was started in, written
a moment after the canvas changes and read back when the viewer starts, so quitting and
coming back finds the cards where they were.

`.grasp/index.json` is rebuilt from whatever the checkout holds, so it is worth ignoring in
git, as is `.grasp/worktrees/`. The sessions are not derived from the code: a session is an
arrangement someone made, so commit `.grasp/sessions/` alongside a branch if you want the
canvas to travel with the pull request.
