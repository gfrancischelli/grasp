# Pull requests

Indexed against a base ref, the same canvas reviews a change: the sidebar leads with what
the branch did, and a modified card swaps between its source and its diff.

## Your own branch

```
mix grasp.index --base main
```

The index then records, for every function, whether the branch left it alone, modified it,
added it or removed it, along with the base version of each modified function's source.
Comparison is against the merge base of `HEAD` and the ref, so a base branch that has moved
on since the branch started does not make every file look touched. Uncommitted and untracked
work counts as part of the branch, so the review reads the code as it is on disk rather than
as it was last committed.

## Someone else's pull request

```
mix grasp.pr 1212
```

Run it from the project you started Grasp in. The task:

- reads the pull request with `gh` — base branch, head branch, title, URL;
- fetches both branches;
- checks the head out under `.grasp/worktrees/pr-1212`, detached, or moves a worktree
  already there to the head just fetched, so a pull request pushed to since the last review
  is re-read rather than left where it was;
- works in the worktree's copy of your project — the worktree itself, or the same directory
  inside it when your project is one directory of a larger repository, such as `apps/web`;
- symlinks the project's `deps/` into that copy and seeds its build path from a copy of
  `_build/dev`;
- builds the index there against the pull request's base, writing it to the file the viewer
  watches — `.grasp/index.json`, or whatever `:grasp, :index_path` names.

Your own checkout stays on the branch you were on and your dev server keeps running the code
it started with; the cards are the pull request's code, read from the worktree. The viewer
picks the new index up within a second or two.

Options:

- `--close` — remove the worktree again and prune the list. The removal is forced, so
  anything left uncommitted in it goes with it.
- `--base REF` — review against a ref other than the one the pull request targets.
- `--root PATH` — the project to work on, default the working directory. The agent's shell
  runs inside the tree under review and cannot change directory, so it names the reader's
  checkout here.

A worktree with uncommitted edits in it is not checked out over: the task stops with git's
own message. Commit the edits, or run `--close` to throw them away, and ask again.

Comments and sessions are not kept in the worktree — they live under the checkout you started
Grasp in — so a review outlives the tree it was written against.

## In the viewer

- **Changes** is the first group in the sidebar, open on arrival, listing every changed
  function under its module with an `added` / `modified` / `removed` badge. Clicking one
  opens it as a card, from which the call chain opens as usual. The line under the project
  name says what the review is against, `main…feature`.
- **A card wears its badge too**, and a modified one counts its lines (`+3 −1`) beside the
  title. The palette carries the same badge, so a search says which hits are part of the
  change.
- **`diff` in a modified card's header** swaps its body for the diff against the base, and
  `source` swaps it back. The `d` key does the same to the focused card.
- **`changes only` folds the unchanged lines away**, with `⋯ n unchanged lines` rows that
  draw their lines when clicked. The `z` key toggles it.
- **A removed function opens as a card of its own**, tinted and showing the source the base
  had. Its `file:line` is the base commit's, so it is printed rather than linked into your
  editor.
- **A deleted line takes a comment too.** In the diff body the base side's line numbers are
  clickable, so a thread can sit on the code the branch removed.

## Opening a PR from the chat

In edit mode the chat panel takes "Open PR 1212". The agent runs `mix grasp.pr 1212`, reloads
the index it wrote, and lays the change out one group per flow. See [The agent](agent.md).

## Publishing comments to GitHub

"Publish the comments to PR 1212" sends the review to GitHub. The agent calls
`publish_comments`, which posts each thread as a review comment with its replies under it:

- A thread whose line the pull request's diff covers goes **on that line**.
- One the diff does not show — a line outside every hunk, or a comment on the base side of a
  modified function — goes **on the file**, with the function and line it was written on at
  the top of it. GitHub takes a line comment only inside the diff.
- Comments and replies the agent wrote are posted with a `claude:` prefix, so it is clear
  who wrote which.
- Threads already published are skipped, so you can publish, write three more comments and
  publish again.

It reports back what went where and what failed. This works in either chat mode, since the
posting goes through `gh` rather than through the agent's own tools. Drop the number to
publish to the pull request the checked-out branch is already open on.

## Requirements

`gh` has to be installed and signed in, and `origin` has to be the remote the pull request
is on.

## Limitations

- **Worktrees accumulate.** `.grasp/worktrees/` grows one checkout and one seeded build per
  pull request until `mix grasp.pr N --close`, which discards uncommitted edits in it.
- **The seeded build goes stale.** A worktree's build directory is copied from `_build/dev`
  once. A dependency rebuilt afterwards is not copied again; delete the directory to take a
  fresh seed.
- **The worktree's dependencies are the host's.** A pull request that changes `mix.lock`
  compiles against your `deps/`; its index may miss or mis-resolve calls into the changed
  dependency until you run `mix deps.get` in the worktree.
- **`origin` is assumed.** The pull request has to be on that remote.
- **Live reindexing pauses** while a worktree's index is loaded: the index is rooted in the
  worktree, your dev server compiles a different tree, so Grasp says so once and waits for an
  index of your own tree again.
