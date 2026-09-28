defmodule Mix.Tasks.Grasp.CoverTest do
  # Each test works in a Mix project of its own, entered with `Mix.Project.in_project/3`,
  # which changes the working directory; and `:cover` is one server per VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @compile {:no_warn_undefined, :cover}

  @kept """
  defmodule Acme.CoverKept do
    defmacro __using__(_opts) do
      quote location: :keep do
        def kept(value) do
          value * 10
        end
      end
    end
  end
  """

  # `badge/1` is compiled from a string whose first line is numbered 6, so its `if` shares
  # line 6 with `next/1`'s body; `kept/1` is written in the other file, and its body's line 5
  # is a blank line inside `next/1`'s span here.
  @tally """
  defmodule Acme.CoverTally do
    require EEx
    use Acme.CoverKept

    def next(count) when count >= 0 do
      count + 1
    end

    def next(_count) do
      :negative
    end

    EEx.function_from_string(:def, :badge, "<%= if on do %>\\non\\n<% end %>", [:on], line: 6)
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

    on_exit(fn ->
      restore(:test_command, previous_command)
      restore(:index_path, previous_index)
      unload()
    end)

    write!(Path.join(tmp_dir, "lib/acme/cover_kept.ex"), @kept)
    write!(Path.join(tmp_dir, "lib/acme/cover_tally.ex"), @tally)
    write!(Path.join(tmp_dir, "lib/acme/cover_greeter.ex"), @greeter)
    write_index!(Path.join(tmp_dir, ".grasp/index.json"))
    Application.put_env(:grasp, :index_path, ".grasp/index.json")
    :ok
  end

  test "runs the suite with cover in the test environment and writes what each function ran",
       %{tmp_dir: tmp_dir} do
    output =
      in_acme(tmp_dir, [], fn root ->
        Application.put_env(:grasp, :test_command, fake_suite(0))
        output = capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)
        assert output =~ "Grasp coverage written to #{root}/.grasp/coverage.json (2 functions)"
        output
      end)

    assert output =~ "the suite ran"
    refute output =~ "imported files"

    assert File.read!(Path.join(tmp_dir, "args.txt")) ==
             "test\n--seed\n0\n--cover\n--export-coverage\ngrasp\n"

    {:ok, coverage} =
      Grasp.Coverage.decode(File.read!(Path.join(tmp_dir, ".grasp/coverage.json")))

    # Line 6 is carried by both `next/1` and the template, so its count belongs to neither;
    # `kept/1`'s line 5 is its own file's and never reaches `next/1`. What is left is the
    # second clause, never entered, counted on its head: line 9, offset 4 of the span that
    # starts on line 5.
    assert coverage["functions"]["Acme.CoverTally.next/1"]["lines"] == %{"4" => 0}
    assert coverage["functions"]["Acme.CoverGreeter.hello/1"]["lines"] == %{"1" => 2}
    assert coverage["index_generated_at"] == "2026-09-28T11:58:00Z"
    assert File.regular?(Path.join(tmp_dir, "cover/grasp.coverdata"))
  end

  test "a function whose indexed source differs from its file gets no entry, and is counted",
       %{tmp_dir: tmp_dir} do
    write!(
      Path.join(tmp_dir, "lib/acme/cover_greeter.ex"),
      String.replace(@greeter, ~s("hello "), ~s("hi "))
    )

    output =
      in_acme(tmp_dir, [], fn _root ->
        Application.put_env(:grasp, :test_command, fake_suite(0))
        capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)
      end)

    assert output =~ "grasp: skipped 1 function whose indexed source differs from the checkout"

    {:ok, coverage} =
      Grasp.Coverage.decode(File.read!(Path.join(tmp_dir, ".grasp/coverage.json")))

    assert Map.keys(coverage["functions"]) == ["Acme.CoverTally.next/1"]
  end

  test "a module whose test beam cannot be read contributes nothing", %{tmp_dir: tmp_dir} do
    in_acme(tmp_dir, [], fn _root ->
      Application.put_env(:grasp, :test_command, fake_suite(0))
      File.rm!(Path.join(Mix.Project.compile_path(), "Elixir.Acme.CoverGreeter.beam"))
      capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)
    end)

    {:ok, coverage} =
      Grasp.Coverage.decode(File.read!(Path.join(tmp_dir, ".grasp/coverage.json")))

    assert Map.keys(coverage["functions"]) == ["Acme.CoverTally.next/1"]
  end

  test "reports a failing run and writes the coverage it exported", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "elsewhere/coverage.json")

    output =
      in_acme(tmp_dir, [], fn _root ->
        Application.put_env(:grasp, :test_command, fake_suite(2))

        capture_io(fn ->
          Mix.Tasks.Grasp.Cover.run(["--out", out, "--index", ".grasp/index.json"])
        end)
      end)

    assert output =~ "grasp: the test run exited with status 2; coverage covers what ran"

    assert {:ok, %{"functions" => %{"Acme.CoverTally.next/1" => _}}} =
             Grasp.Coverage.decode(File.read!(out))
  end

  test "the export is read from the project's coverage output directory", %{tmp_dir: tmp_dir} do
    in_acme(tmp_dir, [output: "out/cov"], fn _root ->
      Application.put_env(
        :grasp,
        :test_command,
        fake_suite(0, "out/cov/grasp.coverdata")
      )

      capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)
    end)

    assert File.read!(Path.join(tmp_dir, "args.txt")) ==
             "test\n--seed\n0\n--cover\n--export-coverage\ngrasp\n"

    assert File.regular?(Path.join(tmp_dir, ".grasp/coverage.json"))
  end

  test "an export name the project sets is the one read, and none is asked for",
       %{tmp_dir: tmp_dir} do
    in_acme(tmp_dir, [output: "out/cov", export: "mine"], fn _root ->
      Application.put_env(
        :grasp,
        :test_command,
        fake_suite(0, "out/cov/mine.coverdata")
      )

      capture_io(fn -> Mix.Tasks.Grasp.Cover.run([]) end)
    end)

    assert File.read!(Path.join(tmp_dir, "args.txt")) == "test\n--seed\n0\n--cover\n"
    assert File.regular?(Path.join(tmp_dir, ".grasp/coverage.json"))
  end

  test "a run that exports nothing aborts with the command's status, whatever an earlier run left",
       %{tmp_dir: tmp_dir} do
    in_acme(tmp_dir, [], fn _root ->
      canned = canned_coverdata()
      File.mkdir_p!("cover")
      File.cp!(canned, "cover/grasp.coverdata")
      Application.put_env(:grasp, :test_command, ["sh", "-c", "exit 3", "fake"])

      capture_io(fn ->
        assert_raise Mix.Error,
                     ~r/exited with status 3 and exported no coverage to cover\/grasp.coverdata/,
                     fn -> Mix.Tasks.Grasp.Cover.run([]) end
      end)
    end)

    refute File.exists?(Path.join(tmp_dir, ".grasp/coverage.json"))
  end

  test "an index that cannot be read aborts before the suite runs", %{tmp_dir: tmp_dir} do
    in_acme(tmp_dir, [], fn _root ->
      Application.put_env(:grasp, :test_command, fake_suite(0))

      assert_raise Mix.Error, ~r/cannot read the index at .*missing.json/, fn ->
        Mix.Tasks.Grasp.Cover.run(["--index", "missing.json"])
      end
    end)

    refute File.exists?(Path.join(tmp_dir, "args.txt"))
  end

  test "an umbrella root is refused", %{tmp_dir: tmp_dir} do
    name = "Acme.CoverUmbrella#{System.unique_integer([:positive])}.MixProject"

    write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule #{name} do
      use Mix.Project
      def project, do: [apps_path: "apps"]
    end
    """)

    File.mkdir_p!(Path.join(tmp_dir, "apps"))

    Mix.Project.in_project(
      :"acme_umbrella_#{System.unique_integer([:positive])}",
      tmp_dir,
      fn _module ->
        assert_raise Mix.Error, ~r/run mix grasp.cover inside the app/, fn ->
          Mix.Tasks.Grasp.Cover.run([])
        end
      end
    )
  end

  # Mix keeps a loaded project's config by app name, so each project is an app of its own.
  defp in_acme(tmp_dir, test_coverage, fun) do
    n = System.unique_integer([:positive])
    name = "Acme.Cover#{n}.MixProject"
    app = :"acme_cover_#{n}"

    write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule #{name} do
      use Mix.Project
      def project, do: [app: #{inspect(app)}, version: "0.1.0", test_coverage: #{inspect(test_coverage)}]
    end
    """)

    Mix.Project.in_project(app, tmp_dir, fn _module -> fun.(File.cwd!()) end)
  end

  # A shell standing in for `mix test`, started in the project root: it records the
  # environment and arguments it starts with, leaves the canned export at `target`, and
  # exits with `status`.
  defp fake_suite(status, target \\ "cover/grasp.coverdata") do
    canned_coverdata()

    script = """
    printf '%s\\n' "$MIX_ENV" "$@" > args.txt
    mkdir -p '#{Path.dirname(target)}'
    cp canned.coverdata '#{target}'
    echo 'the suite ran'
    exit #{status}
    """

    ["sh", "-c", script, "fake", "--seed", "0"]
  end

  # The project's modules compiled into its test build, run under `:cover` and exported as
  # `mix test --cover` exports them.
  defp canned_coverdata do
    unload()
    ebin = Mix.Project.compile_path()
    sources = Enum.map(~w(cover_kept cover_tally cover_greeter), &"lib/acme/#{&1}.ex")

    # `:cover` instruments a module from the abstract code its beam carries.
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      {:ok, _modules, _warnings} =
        Kernel.ParallelCompiler.compile_to_path(sources, ebin, return_diagnostics: true)
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end

    # Compiling to a directory puts it on the code path; the task reads the beams by path.
    Code.delete_path(ebin)
    canned = Path.expand("canned.coverdata")
    Mix.ensure_application!(:tools)
    {:ok, _pid} = :cover.start()

    for module <- [Acme.CoverTally, Acme.CoverGreeter] do
      beam = Path.join(ebin, Atom.to_string(module) <> ".beam")
      {:ok, _module} = :cover.compile_beam(String.to_charlist(beam))
    end

    apply(Acme.CoverTally, :next, [1])
    apply(Acme.CoverTally, :badge, [true])
    apply(Acme.CoverTally, :kept, [1])
    apply(Acme.CoverGreeter, :hello, ["Ada"])
    apply(Acme.CoverGreeter, :hello, ["Grace"])
    :ok = :cover.export(String.to_charlist(canned))
    :cover.stop()
    unload()
    canned
  end

  defp unload do
    for module <- [Acme.CoverKept, Acme.CoverTally, Acme.CoverGreeter] do
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
        "arities" => [1],
        "kind" => "def",
        "file" => "lib/acme/cover_tally.ex",
        "span" => %{"start_line" => 5, "end_line" => 11},
        "source" => span_text(@tally, 5, 11),
        "clauses" => [[5, 7], [9, 11]],
        "arms" => [],
        "calls" => []
      },
      %{
        "id" => "Acme.CoverGreeter.hello/1",
        "module" => "Acme.CoverGreeter",
        "name" => "hello",
        "arity" => 1,
        "arities" => [1],
        "kind" => "def",
        "file" => "lib/acme/cover_greeter.ex",
        "span" => %{"start_line" => 2, "end_line" => 4},
        "source" => span_text(@greeter, 2, 4),
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
        "functions" => records
      })
    )
  end

  defp span_text(text, first, last) do
    text |> String.split("\n") |> Enum.slice(first - 1, last - first + 1) |> Enum.join("\n")
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:grasp, key, value)
  defp restore(key, :error), do: Application.delete_env(:grasp, key)
end
