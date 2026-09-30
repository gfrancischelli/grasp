# Grasp — a layered layout for the canvas

A flow reads left to right and top to bottom, and an application reads from the outside in:
the markup a user sees, the interfaces that receive a request, the core that decides, and the
private modules the core is built from. This document extends the Grasp design
(`2026-09-15-grasp-design.md`) with a layout that follows both orders: every card is given an
architectural layer, a card's column is set by its callers and floored by its layer, and an
**arrange** action lays the whole canvas out as columns with rows ordered against crossing
edges. Opening one card keeps every card already on the canvas where it stands.

## Decisions

- **The layer is read from the index, the geometry from the browser.** Which layer a card is
  in and which column it takes are facts of the index and the forest, computed by the server
  and rendered on the node. How tall a card came out is known only to the browser, so the
  hook turns columns and rows into positions, as it places every card.
- **A layer is a floor, never a ceiling.** A card never stands left of the first column of its
  layer, and a call into the same or a later layer puts its callee to the right of its
  caller: a core function calling another core function stands one column further right,
  inside the core band. A call from a later layer into an earlier one — a controller
  rendering its template — sets no column, so the template stands in the html band, left of
  the controller that renders it.
- **Arrange moves every card; opening a card moves none.** Arrange is a request to throw the
  arrangement away. Opening a card is not, so a card opened later is placed by the columns
  already standing and never displaces one.
- **The pure layout step is a module of its own.** The step from measured boxes, columns and
  edges to positions has no DOM in it, so it lives in `assets/js/layout.js` and is tested with
  `node --test`, without a browser and without a dependency.

## Layers

`Grasp.Layers.layer(index, record)` answers one of six layers, in this order, for a function,
module or test record; a card with no record (a stub) is `external`.

- **`test` (0)** — a record `Index.test_side?/2` answers true for: tests, setups and the
  functions of test-only files.
- **`html` (1)** — templates (`kind: "template"`), and functions of a module whose behaviours
  include `Phoenix.LiveView`, `Phoenix.LiveComponent` or `Phoenix.Component`, or whose last
  name segment ends in `HTML`, `Live` or `Components`.
- **`interfaces` (2)** — functions of a module that receives calls from outside the
  application: a module whose behaviours include `Phoenix.Controller`, `Phoenix.Router`,
  `Plug`, `Oban.Worker`, `GenServer`, `Supervisor` or `Application`, a module the index lists
  an entry point for, a module whose last segment ends in `Controller`, and any module of a
  namespace whose first segment ends in `Web` that is not `html`.
- **`core` (3)** — functions of a module no indexed module stands between and the root
  namespace: `Acme.Accounts` is core, and so is `Acme.Accounts.Policy` when the index holds no
  `Acme.Accounts`. The root namespace is the module name's first segment.
- **`private` (4)** — functions of a module nested under an indexed module other than the
  root one: `Acme.Accounts.Policy` when the index holds `Acme.Accounts`, a context's schemas
  and queries.
- **`external` (5)** — a card whose function the index does not hold.

The first rule that matches decides. A function takes its module's layer whatever its kind,
so a `defp` stands with its module. A module card takes the layer its functions take. The
layers are computed once per index load, beside the other derived maps, never per render:
`Grasp.Layers.layers/1` answers every record at once, keyed by function id and by module
name, and `Index.layer/2` reads that map, answering `external` for an id the index does not
hold. `Grasp.Layers.rank/1` is the layer's place in the order above, 0 to 5.

## Columns

`Grasp.Session.Forest.columns_of/2` takes a function answering the layer of a card's function
id and answers each visible card's column within its section; `layered_columns_of/3` is the
same answer over sections a caller already holds, which is how the review view computes it
once per render. `columns_of/1` stays the call-depth answer for callers that hold no index.

- Inside a section the edges between its cards are taken in the order they were opened, and
  an edge that closes a cycle (recursion, a pair of functions calling each other) is left out,
  so the graph the columns are computed on has none.
- A card's column is the larger of one past the largest column among its callers of the same
  or an earlier layer and its layer's floor. A caller of a later layer — the controller that
  renders a template — is laid out after the card and moves it no further right.
- A layer's floor is one past the last column any card of an earlier layer takes in the
  section, and 0 for the first layer present. A layer with no card in the section takes no
  column, so a section without html starts its interfaces at column 0.
- A card with no such caller in its section is a source and stands at its layer's floor.

The column is rendered as the node's `data-column`, and the layer as `data-layer` (its name).
`data-depth` keeps its meaning for the placement order it drives.

## Arrange

The toolbar's **arrange** button (`#reset-layout`, the `reset_layout` event and
`Session.reset_layout/1`) empties every position, and the pass that follows lays the whole
canvas out as columns instead of placing card by card. The hook arranges on any pass in which
no card has a rendered position and no placement answer is still on the wire, so the first
layout of a fresh canvas and an agent's `set_cards` are arranged the same way; a card the
server refused stays unplaced for good and does not keep a later arrange from happening, and
a card opened while an arrange's `place_cards` is still travelling is placed card by card
against the boxes already asked for, so it never races the answer. The pure step is
`arrange/1` in `assets/js/layout.js`; the hook measures the boxes, reads each node's
`data-column` and `data-module`, and takes each call's line from the call site's box.

- **Sections** stay bands stacked top to bottom, in section order, each clear of the frame
  above by the gap placement leaves between sections.
- **Components.** Inside a section, the cards joined by edges are one component, and so are
  the cards of one module, since a module's cluster is one frame in its section: flows that
  share a module, a `Repo` or a schema, form one band. Components stack top to bottom, in the
  order of their first card.
- **x.** Column `c` of a section starts one gap right of the widest card of column `c − 1`,
  so a column is as wide as its widest card. While module clusters are drawn the gap carries
  two module paddings as well, so two module frames in neighbouring columns stand one gap
  apart.
- **Backward edges.** An edge whose callee stands left of its caller — the template a
  controller renders — joins its two cards into one component and counts in the sweeps, but
  orders no call-site pass and aligns no card to a line.
- **Row order.** Each column starts in call-site order: a card below another card of its
  column when the call that opened it comes later in its caller, callers taken in the order of
  their own rows. Four sweeps then reorder each column by the mean row of the cards it is
  joined to in the column before (left to right) or after (right to left), a card joined to
  none keeping its place. A neighbour of the card's own module counts three times in that
  mean, and a card with no edge into the neighbouring column takes the mean row of its
  module's cards there, so a module's cards across adjacent columns come to stand in one band.
- **Module blocks.** The cards of one module in one column are kept adjacent, at the place of
  the first of them, and a module's blocks in neighbouring columns share a top wherever the
  rows above allow, so a module frame is one compact rectangle rather than a staircase and the
  cards of a module stand closer to each other than to any other module's.
- **y.** Rows are placed top to bottom, each card with its port at the line of the call site
  that opened it when that line is known and below the card above it in its column by the
  placement gap otherwise — with room for two module frames between them when the two are of
  different modules — so an edge leaves its call and arrives at the callee's port without a
  bend wherever the column has room.
- **Frames apart.** Cards then move down, and only down, until no module frame holds or meets
  another module's card or frame, with a gap between them wherever they share a stretch of
  the x axis: of two rectangles that meet, the lower moves with all its cards to one gap under
  the other, and each column is stacked again. The rounds are bounded, and a clash still
  standing when they run out is settled by stacking the rectangles in the order of their
  tops, each one that meets any taken before it moved under the lowest of them, which holds by
  construction. A card this step moves off its call line lets its edge bend.
- The positions are pushed in one `place_cards`, as every placement pass does.

## Opening a card

A card opened from another keeps every rule placement has, with one more: its x is one gap
right of its opener, or the left edge of the leftmost card of its section already standing in
its column where that is further right (`snapToColumn` in `layout.js`). The sweep that follows
moves it clear of what stands there. An opened core card joins the core cards already down instead
of standing against the interface that opened it. A card opened from a card it names is lined
up the same way.

A card whose module already stands in its section — a callee, a caller, or a root opened from
a card it names — is placed against that module before anything else (`spotBesideModule` in
`layout.js`). The module is its cluster's frame while the clusters are drawn, and the box round
its standing cards while they are not. Of the four spots round it — right and left, level with
the call but kept within the module's band, and below and above, in the column its leftmost
card starts, one gap from the cards inside — each is swept clear down and up, and judged where
it settles. A settled spot in the card's own column or the next wins over the rest, so the card
keeps to the column its layer puts it in; among those, or among all of them where none falls
in either column, the one nearest its call takes it. The module wins over the call line: a
card stands beside its module and lets its edge bend, rather than standing level with its call
apart from its module. A card whose module has nothing down yet is placed by the ordinary
rule.

## Testing

- `Grasp.Layers` over a hand-built index: every rule, the first-match order, a `defp`, a
  module card, a stub.
- `Forest.columns_of/2`: floors, a layer absent from a section, a core chain spreading inside
  its band, a cycle, a card reached from outside its section.
- The review view: `data-layer` and `data-column` on nodes, the **arrange** button.
- `assets/js/layout.test.mjs` under `node:test` and `node:assert`, run inside `mix test` by
  `test/grasp_web/layout_js_test.exs`, which is skipped with its reason where `node` is not on
  the path: columns to x, call-site row order, the sweeps reducing crossings on a crossed
  pair, module adjacency within a column, a module's cards in two columns sharing a band,
  sections and components stacking, y aligned to a call line and clear of the card above, a
  backward edge aligning nothing, the cards of one module as one component, no module frame
  holding another module's card over a seeded batch of canvases, the fallback stacking when
  the rounds run out, and `snapToColumn` and `spotBesideModule` for a card opened later.

## Known gaps

- The layers are a convention of Phoenix applications; an application laid out otherwise is
  arranged by call depth with its modules classified as core and private.
- Crossing reduction is a heuristic; a dense graph still crosses. Each sweep weighs a card
  only against the column next to it, so an edge that spans several columns does not pull on
  its rows.
- Keeping module frames apart moves cards down, and a card moved that way leaves its call line
  and its edge bends.
- Edges are drawn straight between a call site and a port; nothing routes them round cards.
- Hand positions are lost on arrange, which is its purpose, and are not undoable.
- `layout.js` is tested under Node; the hook's DOM wiring round it — measuring the boxes,
  reading the call lines, deciding when a pass arranges — has no browser test.
