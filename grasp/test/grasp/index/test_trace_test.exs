defmodule Grasp.Index.TestTraceTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.TestTrace

  @event %{
    file: "test/sample_test.exs",
    module: SampleApp.SampleTest,
    function: {:"test adds", 1},
    line: 4,
    column: 5,
    target: {SampleApp.Math, :add, 2},
    kind: :remote,
    at: 0
  }

  setup do
    root = Path.join(System.tmp_dir!(), "grasp-test-trace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "runs the script in the test environment, in a build directory of its own", %{root: root} do
    parent = self()
    trace = %{events: [@event], files: ["test/sample_test.exs"]}

    runner = fn command, args, opts ->
      send(parent, {:ran, command, args, opts})
      File.write!(Enum.at(args, 4), :erlang.term_to_binary(trace))
      {"", 0}
    end

    assert TestTrace.run(root, ["lib", "web"], runner: runner) == {:ok, trace}

    assert_received {:ran, "mix", args, opts}
    build = Path.join(root, "_build/grasp_test")

    assert [
             "run",
             "--no-start",
             "--no-compile",
             script,
             events_file,
             grasp_ebin,
             sourceror_ebin,
             "lib,web"
           ] = args

    assert script == TestTrace.script()
    assert File.regular?(script)
    assert Path.dirname(events_file) == build
    assert grasp_ebin == Path.join(to_string(:code.lib_dir(:grasp)), "ebin")
    assert sourceror_ebin == Path.join(to_string(:code.lib_dir(:sourceror)), "ebin")

    assert opts[:cd] == root
    assert opts[:env] == [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build}]
    assert opts[:stderr_to_stdout] == true

    refute File.exists?(events_file)
  end

  test "seeds its build directory from the project's test build once", %{root: root} do
    File.mkdir_p!(Path.join(root, "_build/test/lib/sample_app/ebin"))
    File.write!(Path.join(root, "_build/test/lib/sample_app/ebin/marker"), "compiled")

    assert {:ok, _trace} = TestTrace.run(root, ["lib"], runner: writing_runner())

    seeded = Path.join(root, "_build/grasp_test/lib/sample_app/ebin/marker")
    assert File.read!(seeded) == "compiled"
    refute File.exists?(Path.join(root, "_build/grasp_test.seeding"))

    File.write!(Path.join(root, "_build/test/lib/sample_app/ebin/marker"), "recompiled")
    assert {:ok, _trace} = TestTrace.run(root, ["lib"], runner: writing_runner())
    assert File.read!(seeded) == "compiled"
  end

  test "starts from an empty build directory when the project has no test build", %{root: root} do
    assert {:ok, _trace} = TestTrace.run(root, ["lib"], runner: writing_runner())
    assert File.dir?(Path.join(root, "_build/grasp_test"))
  end

  test "a failing trace returns the subprocess's output and leaves no events file",
       %{root: root} do
    parent = self()

    runner = fn _command, args, _opts ->
      events_file = Enum.at(args, 4)
      send(parent, {:events_file, events_file})
      File.write!(events_file, :erlang.term_to_binary(%{events: [], files: []}))
      {"== Compilation error in file test/broken_test.exs ==\n", 1}
    end

    assert TestTrace.run(root, ["lib"], runner: runner) ==
             {:error, "== Compilation error in file test/broken_test.exs ==\n"}

    assert_received {:events_file, events_file}
    refute File.exists?(events_file)
  end

  test "a trace that exits cleanly without writing its events is an error", %{root: root} do
    runner = fn _command, _args, _opts -> {"nothing written", 0} end
    assert TestTrace.run(root, ["lib"], runner: runner) == {:error, "nothing written"}
  end

  defp writing_runner do
    fn _command, args, _opts ->
      File.write!(Enum.at(args, 4), :erlang.term_to_binary(%{events: [], files: []}))
      {"", 0}
    end
  end
end
