defmodule Mix.Tasks.Grasp.CoverTest do
  # The task works on the directory it is started in, so each test changes into a project of
  # its own, and `:cover` is one server per VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @compile {:no_warn_undefined, :cover}

  @tally """
  defmodule Acme.CoverTally do
    def next(count) when count >= 0 do
      count + 1
    end

    def next(_count) do
      :negative
    end
  end
  """

  @greeter """
  defmodule Acme.CoverGreeter do
    def hello(name) do
      "hello " <> name
    end
  end
  """

  setup %{tmp_dir: tmp_dir} do
    previous_command = Application.fetch_env(:grasp, :test_command)
    previous_index = Application.fetch_env(:grasp, :index_path)
    previous_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(previous_cwd)
      restore(:test_command, previous_command)
      restore(:index_path, previous_index)
    end)

    File.cd!(tmp_dir)
    root = File.cwd!()
    canned = canned_coverdata(root)
    write_index!(Path.join(root, ".grasp/index.json"))
    Application.put_env(:grasp, :index_path, ".grasp/index.json")

    %{root: root, canned: canned}
  end

  test "runs the suite with cover in the test environment and writes what it ran",
       %{root: root, canned: canned} do
    Application.put_env(:grasp, :test_command, fake_suite(canned, 0))

    output = capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)

    assert output =~ "the suite ran"
    assert output =~ "Grasp coverage written to #{root}/.grasp/coverage.json (2 functions)"

    assert File.read!("args.txt") ==
             "test\n--seed\n0\n--cover\n--export-coverage\ngrasp\n"

    {:ok, coverage} = Grasp.Coverage.decode(File.read!(".grasp/coverage.json"))

    assert coverage["functions"]["Acme.CoverTally.next/1"]["lines"] == %{
             "3" => 1,
             "6" => 0
           }

    assert coverage["functions"]["Acme.CoverGreeter.hello/1"]["lines"] == %{"3" => 2}
    assert coverage["index_generated_at"] == "2026-09-28T11:58:00Z"
    assert File.regular?("cover/grasp.coverdata")
  end

  test "reports a failing run and writes the coverage it exported",
       %{canned: canned, tmp_dir: tmp_dir} do
    Application.put_env(:grasp, :test_command, fake_suite(canned, 2))
    out = Path.join(tmp_dir, "elsewhere/coverage.json")

    output =
      capture_io(fn ->
        Mix.Tasks.Grasp.Cover.run(["--out", out, "--index", ".grasp/index.json"])
      end)

    assert output =~ "grasp: the test run exited with status 2; coverage covers what ran"

    assert {:ok, %{"functions" => %{"Acme.CoverTally.next/1" => _}}} =
             Grasp.Coverage.decode(File.read!(out))
  end

  test "a run that exports nothing aborts with the command's status, whatever an earlier run left",
       %{canned: canned} do
    File.mkdir_p!("cover")
    File.cp!(canned, "cover/grasp.coverdata")
    Application.put_env(:grasp, :test_command, ["sh", "-c", "exit 3", "fake"])

    capture_io(fn ->
      assert_raise Mix.Error, ~r/exited with status 3 and exported no coverage/, fn ->
        Mix.Tasks.Grasp.Cover.run([])
      end
    end)

    refute File.exists?(".grasp/coverage.json")
  end

  test "an index that cannot be read aborts before the suite runs", %{canned: canned} do
    Application.put_env(:grasp, :test_command, fake_suite(canned, 0))

    assert_raise Mix.Error, ~r/cannot read the index at .*missing.json/, fn ->
      Mix.Tasks.Grasp.Cover.run(["--index", "missing.json"])
    end

    refute File.exists?("args.txt")
  end

  # A shell standing in for `mix test`: it records the environment and arguments it
  # starts with, leaves the canned export where Mix would, and exits with `status`.
  defp fake_suite(canned, status) do
    script = """
    printf '%s\\n' "$MIX_ENV" "$@" > args.txt
    mkdir -p cover
    cp '#{canned}' cover/grasp.coverdata
    echo 'the suite ran'
    exit #{status}
    """

    ["sh", "-c", script, "fake", "--seed", "0"]
  end

  # Two modules compiled into directories of their own and run under `:cover`, then exported
  # as `mix test --cover` exports them. The tally's directory stays on the code path, so the
  # task finds its source in its compile info; the greeter's does not, so the task finds its
  # file through the index.
  defp canned_coverdata(root) do
    unload()
    tally = write!(Path.join(root, "lib/acme/cover_tally.ex"), @tally)
    greeter = write!(Path.join(root, "lib/acme/cover_greeter.ex"), @greeter)
    tally_ebin = Path.join(root, "ebin/tally")
    greeter_ebin = Path.join(root, "ebin/greeter")

    # `:cover` instruments a module from the abstract code its beam carries.
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      for {file, ebin} <- [{tally, tally_ebin}, {greeter, greeter_ebin}] do
        {:ok, _modules, _warnings} =
          Kernel.ParallelCompiler.compile_to_path([file], ebin, return_diagnostics: true)
      end
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end

    # Compiling to a directory puts it on the code path.
    Code.delete_path(greeter_ebin)
    Code.prepend_path(tally_ebin)

    on_exit(fn ->
      Code.delete_path(tally_ebin)
      unload()
    end)

    canned = Path.join(root, "canned.coverdata")
    Mix.ensure_application!(:tools)

    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    for beam <- Path.wildcard(Path.join(root, "ebin/*/*.beam")) do
      {:ok, _module} = :cover.compile_beam(String.to_charlist(beam))
    end

    apply(Acme.CoverTally, :next, [1])
    apply(Acme.CoverGreeter, :hello, ["Ada"])
    apply(Acme.CoverGreeter, :hello, ["Grace"])
    :ok = :cover.export(String.to_charlist(canned))
    :cover.stop()
    unload()
    canned
  end

  defp unload do
    for module <- [Acme.CoverTally, Acme.CoverGreeter] do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end
  end

  defp write_index!(path) do
    records = [
      %{
        "id" => "Acme.CoverTally.next/1",
        "module" => "Acme.CoverTally",
        "name" => "next",
        "arity" => 1,
        "kind" => "def",
        "file" => "lib/acme/cover_tally.ex",
        "span" => %{"start_line" => 2, "end_line" => 8},
        "source" => "def next",
        "clauses" => [[2, 4], [6, 8]],
        "arms" => [],
        "calls" => []
      },
      %{
        "id" => "Acme.CoverGreeter.hello/1",
        "module" => "Acme.CoverGreeter",
        "name" => "hello",
        "arity" => 1,
        "kind" => "def",
        "file" => "lib/acme/cover_greeter.ex",
        "span" => %{"start_line" => 2, "end_line" => 4},
        "source" => "def hello",
        "clauses" => [[2, 4]],
        "arms" => [],
        "calls" => []
      }
    ]

    write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "generated_at" => "2026-09-28T11:58:00Z",
        "project" => %{"test_paths" => ["test"]},
        "modules" => [
          %{"name" => "Acme.CoverTally", "file" => "lib/acme/cover_tally.ex", "line" => 1},
          %{"name" => "Acme.CoverGreeter", "file" => "lib/acme/cover_greeter.ex", "line" => 1}
        ],
        "functions" => records
      })
    )
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:grasp, key, value)
  defp restore(key, :error), do: Application.delete_env(:grasp, key)
end
