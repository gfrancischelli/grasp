# Coverage

What the test suite ran, line by line, read on the cards of the code it ran.

## Writing the coverage

```
mix grasp.cover [--out PATH] [--index PATH]
```

The task runs your suite under Mix's own cover tool and writes what it counted as a coverage
document the viewer and the MCP server read. Build the index first: the coverage is written
for the functions the index holds.

The suite runs as you run it. The command is `:grasp, :test_command`, `["mix", "test"]`
unless configured, started in the project root with `MIX_ENV=test` over the environment the
task was started with, and `--cover` added; its output streams to the terminal. A command
of your own takes the same place:

```elixir
config :grasp, test_command: ["mix", "test", "--exclude", "slow"]
```

Mix writes a cover export, and the task reads it back:

- **Where the export lands** is the project's `test_coverage` config: its `:output`
  directory, `cover` unless set, and its `:export` name when it sets one. Without an
  `:export` the task asks for `--export-coverage grasp`, so the file is
  `cover/grasp.coverdata`. An export left by an earlier run is removed before the suite
  starts, and the one the run writes is left where Mix wrote it.
- **Failing tests** still export what ran. The task says the run exited with a non-zero
  status and writes the coverage all the same; a run that leaves no export aborts the task.
- **Grasp stays a dev dependency.** The export is imported into `:cover` in the task's own
  process, which needs no cover-compiled module, so nothing of Grasp runs inside the suite.
- **An umbrella** exports coverage per app, so the task refuses at the umbrella root: run it
  inside the app. It also refuses when `:cover` is already running in its VM, and when the
  index cannot be read.

`--out` names where the document is written, by default `coverage.json` beside the index.
`--index` names the index, by default `:grasp, :index_path`, and `.grasp/index.json` when
that is unset. The document is written beside its path and renamed over it, so the viewer
never reads one half written. It is derived from a run, so it belongs in `.gitignore` with
the index.

## What the document holds

Per application function of the index, the counts `:cover` took on the lines of its span
and a sha256 of the function's source as the index held it, beside the time the coverage
was written, the git head and the index's `generated_at`:

```json
{
  "version": 1,
  "generated_at": "2026-09-28T12:00:00Z",
  "git_head": "0f3c…",
  "index_generated_at": "2026-09-28T11:58:00Z",
  "functions": {
    "SampleApp.Counter.init/1": { "source_hash": "9a1e…", "lines": { "1": 3, "2": 0 } }
  }
}
```

- **Lines are offsets** from the first line of the function's span, so a function that moves
  in its file with its source unchanged keeps its counts. A line `:cover` does not count is
  absent: it is neither run nor never run.
- **A changed function is stale.** When a function's source hashes other than its entry does,
  its counts describe another body, and the card says so rather than tinting the wrong lines.
- **Tests, setups, removed functions and files under the test paths** get no entry, and
  neither does a function with no counted line.
- **Each count goes to one function.** `:cover` counts by module and line; the task reads
  the debug info of the test build's beams and credits each line to the one compiled
  function whose code carries it. A line two functions carry is credited to neither, so a
  line is untinted rather than tinted for the wrong function.

## Where the viewer reads it

`config :grasp, coverage_path:` names the file, by default `coverage.json` beside the index
the viewer reads — where `mix grasp.cover` writes it. The viewer polls the file every two
seconds and reloads it when it changes, so the cards follow a run as soon as it finishes. A
missing file is no coverage, not an error; a file that cannot be read keeps the coverage
already loaded. How the cards show it is in [Reviewing](reviewing.md).

## What has no coverage

- **Dependencies.** Only the modules Mix's cover compiles are counted — the project's
  `elixirc_paths` in the test environment — so a function in a dependency has none.
- **Lines `:cover` does not count** stay untinted: a bodiless head, a `do` line, a blank
  line.
- **A line two compiled functions carry.** A one-line function with default arguments, whose
  only line every arity carries, has no coverage.
- **Code compiled from another file.** Templates embedded with `embed_templates` and code a
  `location: :keep` macro injects are left out by `:cover`, so a template record and code a
  `use` injects carry no coverage.
- **Macros and guards.** They run when their callers compile, before `:cover` starts.
- **A module whose test-build beam has no debug info.**
- **A `case` inside a `~H` sigil** is template text and adds no arm, so it is never marked
  as a branch never entered.

`mix grasp.cover` runs the whole suite each time.
