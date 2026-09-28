defmodule Grasp.Index.TestTraceTest do
  use ExUnit.Case, async: true, group: :mix_shell

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

    trace = %{
      events: [@event],
      files: ["test/sample_test.exs"],
      test_paths: ["test"],
      selected: ["test/gone_test.exs"]
    }

    runner = fn command, args, opts ->
      candidates = args |> Enum.at(6) |> File.read!() |> :erlang.binary_to_term()
      send(parent, {:ran, command, args, opts, candidates})
      File.write!(Enum.at(args, 3), :erlang.term_to_binary(trace))
      {"", 0}
    end

    candidates = ["test/gone_test.exs", "test/gone_helper.exs"]

    assert TestTrace.run(root, ["lib", "web"], runner: runner, candidates: candidates) ==
             {:ok, trace}

    assert_received {:ran, "mix", args, opts, ^candidates}
    build = Path.join(root, "_build/grasp_test")

    assert [
             "run",
             "--no-start",
             script,
             events_file,
             grasp_ebin,
             "lib,web",
             candidates_file
           ] = args

    refute "--no-compile" in args

    assert script == TestTrace.script()
    assert File.regular?(script)
    assert Path.dirname(events_file) == build
    assert grasp_ebin == Path.join(to_string(:code.lib_dir(:grasp)), "ebin")

    assert opts[:cd] == root
    assert opts[:env] == [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", build}]
    assert opts[:stderr_to_stdout] == true

    refute File.exists?(events_file)
    assert Path.dirname(candidates_file) == build
    refute File.exists?(candidates_file)
  end

  test "seeds its build directory from the project's test build once", %{root: root} do
    File.mkdir_p!(Path.join(root, "_build/test/lib/sample_app/ebin"))
    File.write!(Path.join(root, "_build/test/lib/sample_app/ebin/marker"), "compiled")

    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    assert {:ok, _trace} = TestTrace.run(root, ["lib"], runner: writing_runner())
    assert_received {:mix_shell, :info, ["grasp: seeding _build/grasp_test from _build/test"]}

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
      events_file = Enum.at(args, 3)
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

  describe "test_files/2" do
    test "selects the files mix test loads from this project's own configuration" do
      root = File.cwd!()
      selection = TestTrace.test_files(Mix.Project.config(), root)

      assert selection.test_paths == ["test"]
      assert "test/grasp/index/test_trace_test.exs" in selection.files
      refute Enum.any?(selection.files, &String.starts_with?(&1, "test/fixtures/"))
      refute "test/test_helper.exs" in selection.files
      refute Enum.any?(selection.files, &String.starts_with?(&1, "test/support/"))
    end

    test "reads the test paths, the pattern and every kind of load filter", %{root: root} do
      for file <- [
            "spec/a_spec.exs",
            "spec/b_spec.ex",
            "spec/deep/c_spec.exs",
            "spec/named.exs",
            "spec/skipped.exs",
            "checks/one_check.exs",
            "test/ignored_test.exs"
          ] do
        write!(root, file, "")
      end

      config = [
        test_paths: ["spec", "checks/one_check.exs"],
        test_pattern: "*.exs",
        test_load_filters: [~r/_spec\.exs$/, "spec/named.exs", &(&1 == "checks/one_check.exs")]
      ]

      assert TestTrace.test_files(config, root) == %{
               test_paths: ["spec", "checks/one_check.exs"],
               files: [
                 "checks/one_check.exs",
                 "spec/a_spec.exs",
                 "spec/deep/c_spec.exs",
                 "spec/named.exs"
               ]
             }
    end

    test "loads a file a load filter matches although an ignore filter matches it too",
         %{root: root} do
      write!(root, "test/a_test.exs", "")
      write!(root, "test/b_test.exs", "")

      config = [test_ignore_filters: [&String.starts_with?(&1, "test/a")]]

      assert TestTrace.test_files(config, root).files == ["test/a_test.exs", "test/b_test.exs"]
    end

    test "has no test paths when the project has no test directory", %{root: root} do
      assert TestTrace.test_files([], root) == %{test_paths: [], files: []}
    end
  end

  describe "would_load/3" do
    test "judges paths that are not on disk as mix test would judge them there" do
      config = [test_load_filters: [&(String.ends_with?(&1, "_test.exs") and not fixture?(&1))]]

      paths = [
        "test/gone_test.exs",
        "test/deep/gone_test.exs",
        "test/gone_helper.exs",
        "test/fixtures/app/test/gone_test.exs",
        "other/gone_test.exs"
      ]

      assert TestTrace.would_load(config, ["test"], paths) == [
               "test/gone_test.exs",
               "test/deep/gone_test.exs"
             ]
    end

    test "leaves out every path under grasp's own fixture app" do
      assert TestTrace.would_load(Mix.Project.config(), ["test"], [
               "test/fixtures/sample_app/test/sample_app/gone_test.exs",
               "test/grasp/gone_test.exs"
             ]) == ["test/grasp/gone_test.exs"]
    end
  end

  @tag :integration
  @tag timeout: 120_000
  test "traces the tests of a project whose filters leave a non-compiling file out",
       %{root: root} do
    write!(root, "mix.exs", """
    defmodule Acme.MixProject do
      use Mix.Project

      def project do
        [
          app: :acme,
          version: "0.1.0",
          test_load_filters: [&(String.ends_with?(&1, "_test.exs") and not fixture?(&1))],
          test_ignore_filters: [&fixture?/1]
        ]
      end

      defp fixture?(path), do: String.starts_with?(path, "test/fixtures/")
    end
    """)

    write!(root, "lib/acme.ex", "defmodule Acme do\n  def answer, do: 42\nend\n")

    write!(root, "test/acme_test.exs", """
    defmodule AcmeTest do
      use ExUnit.Case

      test "answers" do
        assert Acme.answer() == 42
      end
    end
    """)

    write!(root, "test/fixtures/other/test/broken_test.exs", """
    defmodule Acme.BrokenTest do
      use Acme.MissingCase
    end
    """)

    assert {:ok, trace} =
             TestTrace.run(root, ["lib"],
               candidates: ["test/gone_test.exs", "test/fixtures/other/test/gone_test.exs"]
             )

    assert trace.files == ["test/acme_test.exs"]
    assert trace.test_paths == ["test"]
    assert trace.selected == ["test/gone_test.exs"]

    assert Enum.any?(
             trace.events,
             &(&1.module == AcmeTest and &1.target == {Acme, :answer, 0})
           )
  end

  defp fixture?(path), do: String.starts_with?(path, "test/fixtures/")

  defp write!(root, file, contents) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp writing_runner do
    fn _command, args, _opts ->
      File.write!(Enum.at(args, 3), :erlang.term_to_binary(%{events: [], files: []}))
      {"", 0}
    end
  end
end
