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
  module's `change` compares the moduledoc `source` of both sides:
  - `added` when the head has a moduledoc and the base has none (the module is new, or the
    attribute is);
  - `removed` when the base has one and the head has none; a module the head no longer
    defines becomes a module record with `removed: true`, its base `file`, `line`, `span` and
    `source`, as a removed function does;
  - `modified` when both have one and the sources differ, with `base_source` and `base_doc`
    (the base side's `doc`); a removed moduledoc carries both too;
  - `unchanged` otherwise. A module that moved between files with the same moduledoc is
    unchanged.
- **Incremental updates** rebuild the modules of the files they rebuild, moduledoc included,
  and classify them against the base the way they classify the functions of those files;
  without a base they carry each module's previous `change` and `base_source`.
- **Reading it.** `Grasp.Index.fetch_module/2` answers a module record by name;
  `Grasp.Index.fetch_record/2` answers a function by id or a module by name, and is what
  everything that holds a card's id reads through; `Grasp.Index.changed_modules/1` answers
  the module records whose `change` is `added`, `modified` or `removed`, sorted by name;
  `Grasp.Index.moduledoc_summary/2` answers a module's first paragraph as plain text, at most
  300 characters, or `nil`.

## Module card

- **Opening one.** Clicking the module part of a function card's title opens that module's
  card as a new root placed at the nearest free spot to the card it was opened from; a card
  already open is focused instead. Clicking a module frame's label without dragging it does
  the same. The palette lists modules by name beside functions, marked `module`.
- **The title's tooltip.** The module part of a function card's title carries the module's
  summary (`moduledoc_summary/2`) as its `title`, so a reader can see what the module is for
  without opening anything. A module with no summary carries its name.
- **Header.** The module's name, a `module` badge, one badge per behaviour, the change badge,
  `file:line` (the module's line), collapse and close. It has no callers menu, tests badge,
  run button or entry-point badge.
- **Body.** Three views, chosen as a function card's are:
  - `doc`, the default: the text rendered as sanitized Markdown, where a code span naming a
    function or module the index holds opens its card, as it does in the chat;
  - `source`: the attribute's lines, highlighted and numbered, taking line comments as a
    function card's source does;
  - `diff`, offered when the moduledoc is `modified`: the diff of `base_source` and `source`,
    as a function card's.
  A module with `@moduledoc false` reads "Hidden from the docs (`@moduledoc false`)"; one with
  no moduledoc reads "No `@moduledoc`"; one whose moduledoc is not a literal shows only the
  `source` view. A removed module is drawn as a removed function is, from its base source.
- **Comments.** Threads on a module card are threads on the module's id, anchored to the
  lines of its `source` or `base_source` as a function's are, and are published to GitHub as
  a function's are. In the `doc` view, the card's threads are listed in its footer, since the
  rendered text has no lines to hang them on.
- **Sessions.** A module card is saved and restored with the session. A card whose module the
  index no longer holds is dropped on load, as a card whose function is gone is.
- **The canvas.** A module card clusters with its module's function cards and joins their
  frame. It draws no edges.

## Review against a base ref

- The **Changes** group lists a changed moduledoc as the first row under its module's
  heading, titled `@moduledoc`, with its change badge. The row opens the module card, in the
  diff view when the moduledoc is modified. A module whose only change is its moduledoc gets a
  heading for that row.
- A changed moduledoc is not a changed function: it is never an untested change and never
  paired with tests.

## MCP

- **`get_module(name)`** answers `{"name", "file", "line", "behaviours", "doc", "hidden",
  "change", "base_doc"}`: `doc` is the moduledoc's text (`null` without one), `hidden` whether
  it is `@moduledoc false`, `change` its change against the base (`null` without one), and
  `base_doc` the base side's text when the moduledoc is modified or removed. An unknown
  module is the tools' usual not-found error.
- **`list_changes`** gains `"moduledocs": [{"module", "change"}]`, the changed moduledocs
  sorted by module.
- **`open_card`** opens a module card when given a module name as its function id.
- The agent's system prompt names `get_module`: read a module's moduledoc before explaining
  its functions, and flag a moduledoc the branch made untrue.

## Known gaps

- A moduledoc set outside the module body (by `Module.put_attribute/3` or a macro) is not
  seen.
- Only `@moduledoc` is read; a function's `@doc` stays part of the function's own source.
- ExDoc's own reference forms (`` `c:callback/1` ``, `` `t:type/0` ``, `[text](`Mod.fun/1`)`)
  are not resolved; only a code span that is exactly an id the index holds opens a card.
