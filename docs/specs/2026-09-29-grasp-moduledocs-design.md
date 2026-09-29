# Grasp — module docs on the canvas

A module's `@moduledoc` says what the module is for, and a reviewer reads a module's
functions against that claim. This document extends the Grasp design
(`2026-09-15-grasp-design.md`) with the moduledoc as part of the index, a card that shows
it, its place in a review against a base ref, and the MCP tool an agent reads it with.
Everything the main design says about records, cards, sessions, comments and the index
holds for module records unless this document says otherwise.

## Decisions

- **A module is a record of the index.** Each entry of the document's `modules` carries its
  moduledoc: the text, whether it is `@moduledoc false`, and the lines of the attribute as
  `source` and `span`. The fields a card, a comment and a diff read from a function record
  (`id`, `kind`, `file`, `span`, `source`, `change`, `base_source`, `removed`) are the same
  keys on a module record, so the machinery that draws, anchors, diffs and publishes a
  function card serves a module card without a second path.
- **A module card is keyed by the module's name.** A function id always ends in `/arity`, so
  a card whose id is a module name (`SampleApp.Counter`) never collides with one. The forest,
  the session file and the comment threads store it in the fields they store a function id
  in.
- **The card shows the moduledoc, not the module.** It carries the rendered text, the
  module's behaviours and its change against the base. It lists no functions: search and the
  call chain are how a reader moves through a module, and a list of every function would
  bury the text the card is opened for.
- **The moduledoc is read from source, never from compiled docs.** The extractor already
  parses every file with Sourceror; the base side of a review is parsed the same way, so a
  changed moduledoc needs no compile of the base.
- **The text is rendered as Markdown, sanitized.** A moduledoc is written for ExDoc, in
  Markdown. It is rendered with the MDEx pipeline the chat uses, with the same sanitizing
  allow-list, since the text comes from the reviewed branch.

## Index

- **Extraction.** For each `defmodule` the extractor walks, the first `@moduledoc` among the
  module body's own statements (not a nested module's) is its moduledoc:
  - a string, a heredoc, or a `~S`/`~s` sigil with no interpolation gives `doc.text`, the
    string's value;
  - `@moduledoc false` gives `doc.hidden: true` and no text;
  - any other expression (a module attribute, an interpolated string) gives no text, and the
    source is still recorded;
  - a module without one has `doc: null` and no `source` or `span`.
- **Module record.** `modules[]` entries keep `name`, `file`, `line`, `behaviours`, and gain
  `id` (= `name`), `kind: "module"`, `doc` (`{"text": string | null, "hidden": boolean}` or
  `null`), and, when the module has a moduledoc, `span` (`start_line`, `end_line` of the
  attribute, heredoc included) and `source` (those lines of the file joined with `\n`, as a
  function's source is sliced).
- **Against a base ref.** The base side's modules are extracted as its definitions are. A
  module's `change` compares the moduledoc `source` of both sides, `@moduledoc false`
  counting as a moduledoc:
  - `added` when the head has a moduledoc and the base has none (the module is new, or the
    attribute is);
  - `removed` when the base has one and the head has none, with `base_source` and `base_doc`
    (the base side's `doc`); a module only the base defines becomes a module record with
    `removed: true`, its base `file`, `line`, `doc`, `span` and `source`, as a removed
    function does, and only when the base had a moduledoc: a module that had none leaves
    nothing for a card to show;
  - `modified` when both have one and the sources differ, with `base_source` and `base_doc`;
  - `unchanged` otherwise. A module that moved between files with the same moduledoc is
    unchanged.
- **Incremental updates** rebuild the modules of the files they rebuild, moduledoc included,
  and classify them against the base the way they classify the functions of those files;
  without a base, or when git cannot answer, they carry each live module's previous
  `change`, `base_source` and `base_doc`. A removed module record whose name a live module
  holds again is dropped.
- **Reading it.**
  - `Grasp.Index.modules/1` answers the live modules only, in document order; a removed
    module record describes a module only the base holds, so it is reached by name alone.
  - `Grasp.Index.fetch_module/2` answers a module record by name, removed ones included.
  - `Grasp.Index.module_id?/1` tells a module id from a function id: a function id ends in
    `/arity`, a module name never does, whether or not the index holds the record.
  - `Grasp.Index.fetch_record/2` answers a function by id or a module by name, choosing by
    `module_id?/1`, and is what everything that holds a card's id reads through.
  - `Grasp.Index.changed_modules/1` answers the module records whose `change` is `added`,
    `modified` or `removed`, sorted by name, computed once when the index loads.
  - `Grasp.Index.moduledoc_summary/2` answers a module's first paragraph (up to the first
    blank line) as plain text, or `nil` without text: heading, emphasis and code markers are
    dropped, a link or an image reads as its text, whitespace collapses to single spaces, and
    a paragraph past 300 characters is cut to 300, its last an ellipsis.
  - `Grasp.Index.search/4` with `modules: true` ranks modules by name beside functions, on
    the same score; at an equal score every function ranks ahead of every module.

## Module card

- **Opening one.** Clicking the module part of a function card's title opens that module's
  card as a new root placed at the nearest free spot to the card it was opened from; a card
  already open is focused instead. While module clusters are drawn the title carries no module
  part, and clicking a module frame's label without dragging it does the same, placing the
  card beside the cluster's first card. The palette lists modules by name beside functions,
  each marked with a `module` badge and its file; at an equal score functions come first, and
  a module result opens as a root beside the focused card, with Enter or Shift+Enter alike. A
  code span in a moduledoc or a chat answer that names a module opens its card.
- **The viewer's `open_module` event** takes the module's name, optionally the card it was
  opened from and optionally a view (`auto`, `doc`, `source` or `diff`) to open the card on.
  A name the index holds no module record for opens nothing.
- **The title's tooltip.** The module part of a function card's title carries the module's
  summary (`moduledoc_summary/2`) as its `title`, so a reader can see what the module is for
  without opening anything. A module with no summary carries its name. A test's `describe`
  standing where a function card prints its module is not a module and opens nothing.
- **Header.** The change badge, a `module` badge, one badge per behaviour, the module's name,
  `+n −m` when the moduledoc is modified, `file:line` (the module's line), the view toggle
  when more than one view is offered, and close. A module card has no callees, so it has no
  collapse button, and it has no callers menu, tests badge, run button or entry-point badge.
- **Body.** Up to three views, listed in the toggle in this order, and the `d` key swaps the
  focused card between its diff and its first view:
  - `doc`: the text rendered as sanitized Markdown, where a code span naming a function or
    module the index holds opens its card, as it does in the chat;
  - `source`: the attribute's lines, highlighted and numbered, taking line comments as a
    function card's source does;
  - `diff`, offered when the moduledoc is `modified`: the diff of `base_source` and `source`,
    as a function card's, without folding or a context toggle.
  A card opens on its first view, `doc`, even when the moduledoc is modified; the Changes row
  opens a modified one on its diff. A module with `@moduledoc false` reads "Hidden from the
  docs (`@moduledoc false`)"; one with no moduledoc reads "No `@moduledoc`"; one whose
  moduledoc is not a literal offers `source` (and `diff`) but no `doc`. A module the branch
  keeps but whose moduledoc it removed reads "No `@moduledoc`" with the removed base text
  rendered under it, marked removed, and offers a `diff` of the base lines, every one deleted
  and numbered from 1, taking comments on the base side. A removed module is drawn as a
  removed function is, from the base side: its `doc` and `source` read the base moduledoc and
  its `file:line` is printed rather than linked. `Grasp.ModuleCard` holds which views a record
  offers and which one a card shows, so the viewer and the MCP tools read the same answer.
- **Comments.** Threads on a module card are threads on the module's id, anchored to the
  lines of its `source` or `base_source` as a function's are, and are published to GitHub as
  a function's are, under the module's name. In the `doc` view, the card's threads are
  listed in its footer, since the rendered text has no lines to hang them on. A card with no
  moduledoc lines on a side takes no comment on that side. The sidebar's Comments group lists
  a module thread under the module as `@moduledoc`, and opening it opens the card on the view
  that draws its line: `source` for the new side, `diff` for the base side. A thread on a
  module the index lost is listed muted under its name.
- **Sessions.** A module card is saved and restored with the session, with its view. A card
  whose module the index does not hold is dropped on load, as a card whose function is gone
  is.
- **The canvas.** A module card clusters with its module's function cards and joins their
  frame. It draws no edges, and no card hangs under it.
- **The chat.** A focused module card is offered "Explain" among the chat's suggestions, but
  no plan of tests, since no test runs a moduledoc.

## Review against a base ref

- The **Changes** group lists a changed moduledoc as the first row under its module's
  heading, titled `@moduledoc`, with its change badge. The row opens the module card, in the
  diff view when the moduledoc is modified and on its first view otherwise. A module whose
  only change is its moduledoc gets a heading for that row, and the group's count includes the
  moduledoc rows.
- A changed moduledoc is not a changed function: it is never an untested change and never
  paired with tests.
- A changed moduledoc makes the index a branch's changes for the chat's suggestions, as a
  changed function does.

## MCP

- **`get_module(name)`** answers `{"name", "file", "line", "behaviours", "doc", "hidden",
  "change", "base_doc"}`: `doc` is the moduledoc's text (`null` without one), `hidden` whether
  it is `@moduledoc false`, `change` its change against the base (`null` without one), and
  `base_doc` the base side's text when the moduledoc is modified or removed. A removed module
  is answered from its record. An unknown module is answered `unknown module: <name>`.
- **`list_changes`** gains `"moduledocs": [{"module", "change"}]`, the changed moduledocs
  sorted by module. `total` counts the changed functions only.
- **`search_functions`** and **`list_modules`** are unchanged: the first answers functions
  only, the second the live modules.
- **The function-only read tools** (`get_function`, `get_callers`, `get_callees`,
  `tests_for`, `coverage`, `find_paths`) answer a module name with an error saying it is a
  module and pointing to `get_module`.
- **An unknown id without an arity** is answered naming both forms: a function id ends in
  `/arity`, and a module id is the module's name. An unknown id ending in `/arity` is an
  unknown function.
- **`open_card`** and **`set_cards`** open a module card when given a module name as the
  function id, as a root only: a module card takes no `parent_card_id` or `parent_key`, and no
  card hangs under one. A highlight on a module card shades lines of its moduledoc and never
  names a call; a module with no moduledoc lines has none to shade.
- **`set_view`** takes `doc`, `source` or `diff`. A module card takes any view
  `Grasp.ModuleCard` offers for it, and any other is an error; a function card takes `source`
  or `diff` as before, and `doc` is an error.
- **Comments.** `list_comments` filters by a module's name as by a function id, and
  `add_comment` writes on a line of a module's moduledoc: the `new` side numbered as the file
  is, the `old` side from 1 over the base moduledoc of one the branch modified or removed. A
  `new` line on a module with no moduledoc lines on the branch is an error, pointing to side
  `old` when the base has them.
  `publish_comments` posts a module thread as it posts a function's.
- The agent's system prompt names `get_module`: read a module's moduledoc before explaining
  its functions, and flag a moduledoc the branch made untrue; and it says `list_changes`'
  `moduledocs` lists the changed ones.

## Known gaps

- A moduledoc set outside the module body (by `Module.put_attribute/3` or a macro) is not
  seen.
- Only `@moduledoc` is read; a function's `@doc` stays part of the function's own source.
- ExDoc's own reference forms (`` `c:callback/1` ``, `` `t:type/0` ``, `[text](`Mod.fun/1`)`)
  are not resolved; only a code span that is exactly an id the index holds opens a card.
- A module removed by the branch whose base had no moduledoc has no record, so no card and
  no Changes row: its removed functions carry the review.
- An incremental update that cannot read the base drops the removed module records of the
  files it rebuilds, as it drops their removed functions; the next full build restores them.
- On an incremental update, a documented module that moved into a rebuilt file from a file
  the update did not rebuild reads `added` until the next full build.
- `search_functions` over MCP does not find modules; an agent names a module through
  `list_modules`, `list_changes`' `moduledocs` or `get_module`.
