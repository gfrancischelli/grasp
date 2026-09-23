defmodule Grasp.PullRequest do
  @moduledoc """
  Puts a pull request under review without touching the reader's working tree.

  A review needs the pull request's code on disk and an index of it built against the base
  branch. Checking the branch out where the reader works would take their dev server with
  it — the code reloader would recompile the pull request's code into the server they are
  running, and whatever they had in progress would have to be put aside first. A worktree
  is the same checkout seen twice: `open/2` adds one per pull request under
  `.grasp/worktrees/pr-N`, detached at the fetched head, and everything the review touches
  happens inside it. The reader's own tree is never read from and never written to.

  A worktree checks out the whole repository, and the Mix project need not be at its top: in
  a repository holding several projects the reader's checkout is one directory of it. The
  review works in the same directory of the worktree — the one git names as the reader's
  path below the top — so the lending and the index build below happen in the pull
  request's copy of the reader's project rather than in whatever project the top holds.

  The worktree is a bare checkout of the source, so two things are lent to it rather than
  rebuilt: `deps/` is symlinked to the host's, and the build directory the index compiles
  in starts as a copy of the host's `_build/dev`. That is what makes the second pull
  request of an afternoon a compile of the project rather than of every dependency it
  carries. The lending is also the limit — a pull request that changes `mix.lock` is
  indexed against the host's dependencies. Mix refuses a build whose lock pins versions its
  `deps/` does not hold, so the build runs with the host's `mix.lock` in place of the pull
  request's, and the pull request's is put back as it was once the build ends, whether it
  succeeded or not: the worktree is left holding the pull request's own files, and a later
  re-open finds nothing uncommitted in it to stop at.

  The index is written to the file the reader's viewer watches — `:grasp, :index_path` when
  that names one, `.grasp/index.json` under the root otherwise — and names the worktree as
  its project root: the cards are the pull request's
  code, read from where that code actually is. Comments and sessions are unaffected — they
  live under `Grasp.Application.home/0`, so a review survives `close/2` removing the tree
  it was written against.

  Every external command goes through a `runner`, so a test can run the real `git` against
  a temporary repository while recording the index build instead of compiling one. A
  command that fails stops the recipe with its output, on the grounds that what `git` or
  `gh` printed is what the reader needs to read.
  """

  @typedoc """
  Runs `argv` in `cwd` and answers its output and exit status.

  `opts` carries `:env`, the environment variables the command is given on top of the ones
  it inherits. Output is the command's stdout and stderr together.
  """
  @type runner :: ([String.t()], Path.t(), keyword() -> {String.t(), non_neg_integer()})

  @typedoc """
  An opened pull request: where its code is, what it is, and the index built of it.

  `worktree` is the checkout of the whole repository and `project` the Mix project inside
  it, the directory the index is built in. The two are one directory when the project is
  the repository's top, and `project` is the same path below `worktree` that the reader's
  project is below its repository's top otherwise.
  """
  @type t :: %{
          worktree: Path.t(),
          project: Path.t(),
          base: String.t(),
          head: String.t(),
          title: String.t(),
          url: String.t(),
          index: Path.t()
        }

  @type option ::
          {:root, Path.t()}
          | {:runner, runner()}
          | {:gh, String.t()}
          | {:base_override, String.t()}
          | {:log, (String.t() -> any())}

  @fields "baseRefName,headRefName,title,url"

  @doc """
  Opens pull request `number` for review: a worktree of its head and an index of it.

  The steps, each stopping the recipe with the command's output when it fails: read the
  pull request with `gh pr view`; fetch its base and head branches; add the worktree, or
  detach an existing one at the newly fetched head; lend it `deps/` and a build directory;
  and build the index inside it against `origin/<base>`, writing it to the index file the
  viewer watches.

  `root` is the reader's own checkout, so a root that is itself one of these worktrees is
  refused: a review of a review would index a tree nobody is reading and overwrite the
  index of the one they are. A caller running elsewhere — the agent, whose working directory
  is the tree under review — passes `:root` rather than relying on the working directory.

  Re-opening a pull request moves the worktree it already has to the newly fetched head, and
  the checkout that does so is not forced: an edit left uncommitted in that worktree which
  the move would overwrite stops the recipe with git's own message. Committing the edit, or
  `close/2` to discard it, is what unblocks it.

  `:root` is the reader's checkout, the working directory by default; `:runner` runs the
  commands, `System.cmd/3` by default; `:gh` is the GitHub CLI; `:base_override` reviews
  against a ref other than the branch the pull request targets; and `:log` is called with a
  sentence for each step, so a task can print the recipe as it runs.
  """
  @spec open(pos_integer(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def open(number, opts \\ []) when is_integer(number) and number > 0 do
    root = Path.expand(Keyword.get(opts, :root) || File.cwd!())
    runner = Keyword.get(opts, :runner, &run/3)
    log = logger(opts)
    worktree = worktree(root, number)
    index = index_path(root)

    with :ok <- reader_checkout(root),
         {:ok, pull_request} <- view(number, root, runner, opts),
         base = Keyword.get(opts, :base_override) || pull_request.base,
         head = pull_request.head,
         :ok <- log.("Reading pull request #{number}: #{pull_request.title}"),
         :ok <- fetch(root, base, head, runner),
         :ok <- log.("Fetched origin/#{base} and origin/#{head}"),
         {:ok, prefix} <- prefix(root, runner),
         project = Path.join(worktree, prefix),
         :ok <- place(root, worktree, head, runner, log),
         :ok <- lend_deps(root, project, log),
         {:ok, build} <- lend_build(root, project, log),
         :ok <- log.("Indexing #{Path.relative_to(project, root)} against origin/#{base}"),
         :ok <-
           with_host_lock(root, project, fn -> index(project, base, index, build, runner) end) do
      {:ok,
       %{
         worktree: worktree,
         project: project,
         base: base,
         head: head,
         title: pull_request.title,
         url: pull_request.url,
         index: index
       }}
    end
  end

  @doc """
  Removes the worktree pull request `number` was opened in.

  The removal is forced, because a worktree is Grasp's to throw away: the agent edits the
  pull request's code there, and a reader who wants to keep an edit commits or copies it
  before closing. It is also how a worktree whose uncommitted edits block a re-open is made
  ready for one. A pull request that was never opened, or whose directory is already
  gone, is closed by pruning alone. Takes `:root`, `:runner` and `:log` as `open/2` does.
  """
  @spec close(pos_integer(), [option()]) :: :ok | {:error, String.t()}
  def close(number, opts \\ []) when is_integer(number) and number > 0 do
    root = Path.expand(Keyword.get(opts, :root) || File.cwd!())
    runner = Keyword.get(opts, :runner, &run/3)
    log = logger(opts)
    worktree = worktree(root, number)

    with :ok <- remove(root, worktree, runner, log),
         {_output, 0} <- runner.(["git", "worktree", "prune"], root, []) do
      log.("Closed pull request #{number}")
      :ok
    else
      {:error, message} -> {:error, message}
      {output, status} -> {:error, failure(["git", "worktree", "prune"], output, status)}
    end
  end

  @doc """
  The directory pull request `number` is reviewed in, under `root`.

  One per pull request, named after its number, so a second review of the same one reuses
  the checkout rather than adding another.
  """
  @spec worktree(Path.t(), pos_integer()) :: Path.t()
  def worktree(root, number) when is_integer(number) and number > 0,
    do: Path.join([Path.expand(root), ".grasp", "worktrees", "pr-#{number}"])

  # The viewer watches one file, and a rebuild that wrote anywhere else would leave it
  # showing the branch the reader opened rather than the pull request they asked for.
  defp index_path(root) do
    case Application.get_env(:grasp, :index_path) do
      path when is_binary(path) and path != "" -> Path.expand(path, root)
      _unset -> Path.join(root, ".grasp/index.json")
    end
  end

  defp reader_checkout(root) do
    worktree_of_ours? =
      root
      |> Path.split()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(&(&1 == [".grasp", "worktrees"]))

    if worktree_of_ours? do
      {:error,
       "#{root} is a worktree Grasp opened a pull request in. Run mix grasp.pr from the " <>
         "project you started Grasp in, whose index the viewer watches, or name it with " <>
         "--root."}
    else
      :ok
    end
  end

  # Every step answers `:ok` whatever the caller's `:log` returns, so a printer that
  # answers something else cannot break the chain it is only narrating.
  defp logger(opts) do
    log = Keyword.get(opts, :log, fn _step -> :ok end)

    fn step ->
      log.(step)
      :ok
    end
  end

  defp view(number, root, runner, opts) do
    gh = Keyword.get(opts, :gh) || Application.get_env(:grasp, :gh_command, "gh")
    argv = [gh, "pr", "view", Integer.to_string(number), "--json", @fields]

    with {:ok, output} <- command(argv, root, [], runner),
         {:ok, json} <- decode(output),
         %{"baseRefName" => base, "headRefName" => head} <- json do
      {:ok,
       %{
         base: base,
         head: head,
         title: Map.get(json, "title", "pull request #{number}"),
         url: Map.get(json, "url", "")
       }}
    else
      {:error, message} -> {:error, message}
      _incomplete -> {:error, "gh pr view #{number} did not name a base and a head branch"}
    end
  end

  # `gh` writes notices — a new version, an authentication hint — to stderr, and the runner
  # folds stderr into stdout so a failure is reported in gh's own words. The answer is
  # therefore read from the first line that opens an object rather than from the whole of it.
  defp decode(output) do
    with line when is_binary(line) <- json_line(output),
         {:ok, json} when is_map(json) <- Jason.decode(line) do
      {:ok, json}
    else
      _undecodable -> {:error, "gh pr view did not answer with JSON: #{String.trim(output)}"}
    end
  end

  defp json_line(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, "{"))
  end

  defp fetch(root, base, head, runner) do
    with {:ok, _output} <- command(["git", "fetch", "origin", base, head], root, [], runner),
         do: :ok
  end

  # The reader's project below its repository's top, `""` when it is the top: git answers
  # the path with a trailing separator, which `Path.join/2` takes as it is.
  defp prefix(root, runner) do
    with {:ok, output} <- command(["git", "rev-parse", "--show-prefix"], root, [], runner),
         do: {:ok, String.trim(output)}
  end

  # An existing worktree is moved to the head that was just fetched rather than left where
  # the last review put it: a pull request pushed to since then is a different commit.
  defp place(root, worktree, head, runner, log) do
    with {:ok, _pruned} <- prune(root, runner),
         {:ok, argv} <- placement(root, worktree, head, runner, log),
         {:ok, _output} <- command(argv, root, [], runner) do
      log.("Worktree #{Path.relative_to(worktree, root)} is at origin/#{head}")
    end
  end

  # A directory git has forgotten — pruned while it was still there, or copied into place —
  # is Grasp's own to replace: it is under `.grasp/worktrees/`, which nothing else writes.
  defp placement(root, worktree, head, runner, log) do
    cond do
      not File.exists?(worktree) ->
        File.mkdir_p!(Path.dirname(worktree))
        {:ok, add(worktree, head)}

      owned?(root, worktree, runner) ->
        {:ok, ["git", "-C", worktree, "checkout", "--detach", "origin/#{head}"]}

      true ->
        log.("#{Path.relative_to(worktree, root)} is not a worktree git knows; replacing it")

        with :ok <- discard(worktree),
             {:ok, _pruned} <- prune(root, runner) do
          {:ok, add(worktree, head)}
        end
    end
  end

  defp add(worktree, head), do: ["git", "worktree", "add", "--detach", worktree, "origin/#{head}"]

  # Every directory under the checkout answers `rev-parse` — git resolves upward to the
  # repository containing it — so the questions are which tree the path *is* the top of, and
  # whether that tree has an admin directory of its own. A plain directory left at the
  # worktree's path answers with the reader's own checkout, and detaching that would rewrite
  # the files they are working on.
  defp owned?(root, worktree, runner) do
    with {toplevel, 0} <- rev_parse(root, worktree, "--show-toplevel", runner),
         {git_dir, 0} <- rev_parse(root, worktree, "--absolute-git-dir", runner),
         {common_dir, 0} <- rev_parse(root, worktree, "--git-common-dir", runner) do
      Path.expand(toplevel) == Path.expand(worktree) and
        Path.expand(git_dir) != Path.expand(common_dir, worktree)
    else
      _no_repository -> false
    end
  end

  defp rev_parse(root, worktree, question, runner) do
    {output, status} = runner.(["git", "-C", worktree, "rev-parse", question], root, [])
    {String.trim(output), status}
  end

  # Pruning before the worktree is placed clears the admin entries of directories that were
  # deleted by hand, which `git worktree add` would otherwise refuse to reuse the path of.
  defp prune(root, runner), do: command(["git", "worktree", "prune"], root, [], runner)

  defp discard(worktree) do
    case File.rm_rf(worktree) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        {:error, "could not remove #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp lend_deps(root, project, log) do
    source = Path.join(root, "deps")
    target = Path.join(project, "deps")

    cond do
      # The link itself, not what it points at: a link left dangling by a removed `deps/`
      # is still a name `File.ln_s/2` would refuse to take.
      match?({:ok, _stat}, File.lstat(target)) ->
        :ok

      not File.dir?(source) ->
        :ok

      true ->
        case File.ln_s(source, target) do
          :ok ->
            log.("Linked #{Path.relative_to(target, root)} to #{source}")
            :ok

          {:error, reason} ->
            {:error, "could not link #{target} to #{source}: #{:file.format_error(reason)}"}
        end
    end
  end

  # The build directory is seeded here rather than left to `mix grasp.index`, which seeds
  # from the build of the project it runs in: a fresh worktree has none to seed from.
  defp lend_build(root, project, log) do
    build = Path.join([project, "_build", "grasp"])
    source = Path.join([root, "_build", "dev"])

    if File.dir?(build) or not File.dir?(source) do
      {:ok, build}
    else
      log.("Seeding #{Path.relative_to(build, root)} from #{Path.relative_to(source, root)}")
      File.mkdir_p!(Path.dirname(build))

      case File.cp_r(source, build) do
        {:ok, _copied} -> {:ok, build}
        {:error, reason, path} -> {:error, "could not copy #{source} to #{path}: #{reason}"}
      end
    end
  end

  defp with_host_lock(root, project, build) do
    host = Path.join(root, "mix.lock")
    lock = Path.join(project, "mix.lock")

    case File.read(host) do
      {:ok, host_lock} ->
        original = File.read(lock)
        File.write!(lock, host_lock)

        try do
          build.()
        after
          restore(lock, original)
        end

      {:error, _no_lock} ->
        build.()
    end
  end

  defp restore(lock, {:ok, contents}), do: File.write!(lock, contents)
  defp restore(lock, {:error, _absent}), do: File.rm!(lock)

  defp index(project, base, out, build, runner) do
    argv = [
      "mix",
      "grasp.index",
      "--base",
      "origin/#{base}",
      "--out",
      out,
      "--build-path",
      build
    ]

    with {:ok, _output} <- command(argv, project, [env: [{"MIX_ENV", "dev"}]], runner), do: :ok
  end

  defp remove(root, worktree, runner, log) do
    if File.exists?(worktree) do
      log.("Removing #{Path.relative_to(worktree, root)} and any edit left uncommitted in it")

      case command(["git", "worktree", "remove", "--force", worktree], root, [], runner) do
        {:ok, _output} ->
          :ok

        # git refuses a path it does not hold as a working tree, and that path is still a
        # directory Grasp made and nothing else writes to.
        {:error, _message} ->
          discard(worktree)
      end
    else
      :ok
    end
  end

  defp command(argv, cwd, opts, runner) do
    case runner.(argv, cwd, opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, failure(argv, output, status)}
    end
  end

  # A command that failed silently is reported by what it was and how it ended, so the
  # caller is never handed an empty string to explain.
  defp failure(argv, output, status) do
    case String.trim(output) do
      "" -> "#{Enum.join(argv, " ")} exited with status #{status}"
      message -> message
    end
  end

  defp run([command | args], cwd, opts) do
    System.cmd(command, args,
      cd: cwd,
      stderr_to_stdout: true,
      env: Keyword.get(opts, :env, [])
    )
  rescue
    ErlangError -> {"#{command} is not installed or not on PATH", 127}
  end
end
