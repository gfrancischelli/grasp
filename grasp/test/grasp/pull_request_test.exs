defmodule Grasp.PullRequestTest do
  # The index path the task writes to is application-wide, and these tests decide what it
  # is, so this module runs alone.
  use ExUnit.Case, async: false

  alias Grasp.PullRequest

  @moduletag :tmp_dir

  # Identity and signing are given on every git call, so a commit works on a machine that
  # configures neither, and on one that signs every commit by default.
  @git_config [
    "-c",
    "user.name=Grasp Test",
    "-c",
    "user.email=grasp@example.com",
    "-c",
    "commit.gpgsign=false"
  ]

  setup %{tmp_dir: tmp_dir} do
    index_path = Application.get_env(:grasp, :index_path)
    Application.put_env(:grasp, :index_path, nil)
    on_exit(fn -> Application.put_env(:grasp, :index_path, index_path) end)

    tmp_dir = Path.expand(tmp_dir)
    origin = Path.join(tmp_dir, "origin.git")
    root = Path.join(tmp_dir, "app")

    git!(["init", "--bare", "--initial-branch=main", origin], tmp_dir)
    git!(["clone", origin, root], tmp_dir)

    write(root, "lib/greeter.ex", """
    defmodule Greeter do
      def greet(name), do: "Hello, " <> name
    end
    """)

    commit!(root, "the base")
    git!(["push", "origin", "main"], root)

    git!(["checkout", "-b", "feature"], root)

    write(root, "lib/greeter.ex", """
    defmodule Greeter do
      def greet(name), do: "Hello, " <> name
      def shout(name), do: String.upcase(name)
    end
    """)

    commit!(root, "the change")
    git!(["push", "origin", "feature"], root)
    git!(["checkout", "main"], root)

    %{root: root, worktree: PullRequest.worktree(root, 7)}
  end

  test "open/2 checks the head out in a worktree and indexes it against the base", context do
    %{root: root, worktree: worktree} = context
    File.mkdir_p!(Path.join(root, "deps/phoenix"))
    write(root, "_build/dev/lib/app/ebin/marker", "a beam would be here")

    assert {:ok, pull_request} = PullRequest.open(7, opts(root))

    assert pull_request.base == "main"
    assert pull_request.head == "feature"
    assert pull_request.title == "Add greeting"
    assert pull_request.url == "https://github.com/acme/sample_app/pull/7"
    assert pull_request.worktree == worktree
    assert pull_request.project == worktree
    assert pull_request.index == Path.join(root, ".grasp/index.json")

    assert File.read!(Path.join(worktree, "lib/greeter.ex")) =~ "def shout"
    assert head(worktree) == rev(root, "origin/feature")
    assert detached?(worktree)

    assert File.read_link(Path.join(worktree, "deps")) == {:ok, Path.join(root, "deps")}
    assert File.read!(Path.join(worktree, "_build/grasp/lib/app/ebin/marker")) =~ "a beam"
  end

  test "open/2 builds the index inside the worktree, into the reader's index file", context do
    %{root: root, worktree: worktree} = context

    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))

    assert_received {:ran, argv, cwd, run_opts}

    assert argv == [
             "mix",
             "grasp.index",
             "--base",
             "origin/main",
             "--out",
             Path.join(root, ".grasp/index.json"),
             "--build-path",
             Path.join(worktree, "_build/grasp")
           ]

    assert cwd == worktree
    assert run_opts[:env] == [{"MIX_ENV", "dev"}]
  end

  test "open/2 leaves the reader's own checkout on the branch it was on", %{root: root} do
    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))

    assert branch(root) == "main"
    assert File.read!(Path.join(root, "lib/greeter.ex")) =~ "def greet"
    refute File.read!(Path.join(root, "lib/greeter.ex")) =~ "def shout"
  end

  test "open/2 names each step it takes", %{root: root} do
    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))

    steps = Enum.join(collect_steps(), "\n")

    assert steps =~ "Add greeting"
    assert steps =~ "Fetched origin/main and origin/feature"
    assert steps =~ "pr-7 is at origin/feature"
  end

  test "open/2 a second time moves the worktree it already has to the new head", context do
    %{root: root, worktree: worktree} = context
    assert {:ok, _first} = PullRequest.open(7, opts(root))
    first = head(worktree)

    git!(["checkout", "feature"], root)
    write(root, "lib/greeter.ex", "defmodule Greeter do\n  def greet(name), do: name\nend\n")
    commit!(root, "the second push")
    git!(["push", "origin", "feature"], root)
    git!(["checkout", "main"], root)

    assert {:ok, _second} = PullRequest.open(7, opts(root))

    assert head(worktree) == rev(root, "origin/feature")
    assert head(worktree) != first
    assert detached?(worktree)
  end

  test "open/2 reviews against the ref an override names", %{root: root} do
    git!(["push", "origin", "main:develop"], root)

    assert {:ok, pull_request} = PullRequest.open(7, [base_override: "develop"] ++ opts(root))

    assert pull_request.base == "develop"
    assert_received {:ran, argv, _cwd, _opts}
    assert Enum.take(argv, 4) == ["mix", "grasp.index", "--base", "origin/develop"]
  end

  test "open/2 stops with gh's own message when the pull request cannot be read", context do
    %{root: root, worktree: worktree} = context

    assert {:error, message} = PullRequest.open(404, opts(root))

    assert message =~ "no pull requests found"
    refute File.exists?(worktree)
    refute_received {:ran, _argv, _cwd, _opts}
  end

  test "close/2 removes the worktree the pull request was opened in", context do
    %{root: root, worktree: worktree} = context
    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))
    assert File.dir?(worktree)

    assert PullRequest.close(7, opts(root)) == :ok

    refute File.exists?(worktree)
    refute worktrees(root) =~ "pr-7"
  end

  test "open/2 writes the index file the store is configured to watch", context do
    %{root: root, worktree: worktree} = context
    Application.put_env(:grasp, :index_path, "tmp/watched.json")

    assert {:ok, pull_request} = PullRequest.open(7, opts(root))

    assert pull_request.index == Path.join(root, "tmp/watched.json")
    assert_received {:ran, argv, _cwd, _run_opts}

    assert Enum.drop(argv, 4) == [
             "--out",
             Path.join(root, "tmp/watched.json"),
             "--build-path",
             Path.join(worktree, "_build/grasp")
           ]
  end

  test "open/2 refuses to run from a worktree it opened earlier", context do
    %{root: root} = context
    assert {:ok, pull_request} = PullRequest.open(7, opts(root))

    assert {:error, message} = PullRequest.open(8, opts(pull_request.worktree))

    assert message =~ "is a worktree Grasp opened a pull request in"
    assert message =~ "Run mix grasp.pr from the project you started Grasp in"
  end

  test "open/2 finds the JSON in gh's answer when gh has a notice to make first", context do
    %{root: root} = context
    System.put_env("FAKE_GH_NOTICE", "A new release of gh is available: 2.40.0 → 2.41.0")
    on_exit(fn -> System.delete_env("FAKE_GH_NOTICE") end)

    assert {:ok, pull_request} = PullRequest.open(7, opts(root))

    assert pull_request.title == "Add greeting"
    assert pull_request.head == "feature"
  end

  test "open/2 adds the worktree again when its directory was deleted by hand", context do
    %{root: root, worktree: worktree} = context
    assert {:ok, _first} = PullRequest.open(7, opts(root))
    File.rm_rf!(worktree)

    assert {:ok, _second} = PullRequest.open(7, opts(root))

    assert File.dir?(worktree)
    assert head(worktree) == rev(root, "origin/feature")
    assert detached?(worktree)
  end

  test "open/2 replaces a directory git no longer holds as a worktree", context do
    %{root: root, worktree: worktree} = context
    assert {:ok, _first} = PullRequest.open(7, opts(root))
    File.rm_rf!(Path.join(root, ".git/worktrees/pr-7"))

    assert {:ok, _second} = PullRequest.open(7, opts(root))

    assert head(worktree) == rev(root, "origin/feature")
    assert detached?(worktree)
    assert Enum.join(collect_steps(), "\n") =~ "is not a worktree git knows; replacing it"
  end

  test "close/2 removes a directory git no longer holds as a worktree", context do
    %{root: root, worktree: worktree} = context
    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))
    File.rm_rf!(Path.join(root, ".git/worktrees/pr-7"))

    assert PullRequest.close(7, opts(root)) == :ok

    refute File.exists?(worktree)
  end

  test "close/2 says an uncommitted edit in the worktree goes with it", context do
    %{root: root} = context
    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))
    collect_steps()

    assert PullRequest.close(7, opts(root)) == :ok

    assert Enum.join(collect_steps(), "\n") =~ "any edit left uncommitted in it"
  end

  test "open/2 replaces a plain directory sitting at the worktree's path", context do
    %{root: root, worktree: worktree} = context
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, "left-behind.txt"), "not a checkout")
    main = head(root)

    assert {:ok, _pull_request} = PullRequest.open(7, opts(root))

    # The directory is inside the reader's own repository, so git answers every question
    # about it with that repository: taking it for a worktree would detach the reader's HEAD.
    assert branch(root) == "main"
    assert head(root) == main
    refute File.read!(Path.join(root, "lib/greeter.ex")) =~ "def shout"

    assert head(worktree) == rev(root, "origin/feature")
    assert detached?(worktree)
    refute File.exists?(Path.join(worktree, "left-behind.txt"))
  end

  test "open/2 works in the project's own directory when it is not the repository's top", %{
    tmp_dir: tmp_dir
  } do
    origin = Path.join(tmp_dir, "monorepo.git")
    repository = Path.join(tmp_dir, "monorepo")
    git!(["init", "--bare", "--initial-branch=main", origin], tmp_dir)
    git!(["clone", origin, repository], tmp_dir)
    write(repository, "mix.exs", "# the workspace project at the top\n")
    write(repository, "apps/app/lib/greeter.ex", "defmodule Greeter do\nend\n")
    commit!(repository, "the base")
    git!(["push", "origin", "main"], repository)
    git!(["checkout", "-b", "feature"], repository)

    write(
      repository,
      "apps/app/lib/greeter.ex",
      "defmodule Greeter do\n  def shout, do: 1\nend\n"
    )

    commit!(repository, "the change")
    git!(["push", "origin", "feature"], repository)
    git!(["checkout", "main"], repository)

    root = Path.join(repository, "apps/app")
    File.mkdir_p!(Path.join(root, "deps/phoenix"))
    write(root, "_build/dev/lib/app/ebin/marker", "a beam would be here")
    worktree = PullRequest.worktree(root, 7)
    project = Path.join(worktree, "apps/app")

    assert {:ok, pull_request} = PullRequest.open(7, opts(root))

    assert pull_request.worktree == worktree
    assert pull_request.project == project
    assert File.read!(Path.join(project, "lib/greeter.ex")) =~ "def shout"
    assert File.read_link(Path.join(project, "deps")) == {:ok, Path.join(root, "deps")}
    assert File.read!(Path.join(project, "_build/grasp/lib/app/ebin/marker")) =~ "a beam"
    refute File.exists?(Path.join(worktree, "deps"))

    assert_received {:ran, ["mix", "grasp.index" | args], ^project, _run_opts}

    assert args == [
             "--base",
             "origin/main",
             "--out",
             Path.join(root, ".grasp/index.json"),
             "--build-path",
             Path.join(project, "_build/grasp")
           ]
  end

  test "close/2 on a pull request that was never opened is a prune", %{root: root} do
    assert PullRequest.close(7, opts(root)) == :ok
  end

  # The git steps run the real git against the repositories the setup built; the index
  # build is recorded instead, since compiling a project is not what these tests are about.
  defp opts(root) do
    test = self()

    runner = fn
      ["mix" | _rest] = argv, cwd, opts ->
        send(test, {:ran, argv, cwd, opts})
        {"Grasp index written to .grasp/index.json\n", 0}

      [command | args], cwd, opts ->
        System.cmd(command, args,
          cd: cwd,
          stderr_to_stdout: true,
          env: Keyword.get(opts, :env, [])
        )
    end

    [root: root, runner: runner, log: &send(test, {:step, &1})]
  end

  defp collect_steps(steps \\ []) do
    receive do
      {:step, step} -> collect_steps([step | steps])
    after
      0 -> Enum.reverse(steps)
    end
  end

  defp write(root, path, contents) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp commit!(root, message) do
    git!(["add", "."], root)
    git!(["commit", "-m", message], root)
  end

  defp git!(args, cwd) do
    {output, status} =
      System.cmd("git", @git_config ++ args, cd: cwd, stderr_to_stdout: true)

    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    output
  end

  defp head(repository), do: rev(repository, "HEAD")

  defp rev(repository, ref), do: ["rev-parse", ref] |> git!(repository) |> String.trim()

  defp branch(repository),
    do: ["rev-parse", "--abbrev-ref", "HEAD"] |> git!(repository) |> String.trim()

  defp worktrees(root), do: git!(["worktree", "list"], root)

  defp detached?(worktree) do
    {_output, status} =
      System.cmd("git", ["symbolic-ref", "--quiet", "HEAD"],
        cd: worktree,
        stderr_to_stdout: true
      )

    status != 0
  end
end
