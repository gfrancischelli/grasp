defmodule Mix.Tasks.Grasp.Index do
  @shortdoc "Writes a Grasp index of this project to .grasp/index.json"

  @moduledoc """
  Builds the Grasp index for the current Mix project.

      mix grasp.index [--out PATH] [--base REF] [--build-path PATH] [--no-tests]

  Forces a full recompile with a compiler tracer attached, so every call the compiler
  resolves is recorded with its position, then writes the JSON document the Grasp viewer
  and MCP server read.

  The index is built from what the compiler resolves, so a project that fails to compile
  aborts the task with the compiler's own error. A single file that cannot be read or
  parsed is reported and skipped; only its definitions are missing from the index.

  ## The build directory

  The forced recompile happens in a build directory of Grasp's own, `_build/grasp`, seeded
  by copying the project's current build the first time it is missing. A dev server holds
  the build lock on its own directory and reads the beams it compiled; a full rebuild
  underneath it would either block or invalidate them. Because a build path is fixed when
  a Mix session starts, the task re-executes itself as a subprocess with `MIX_BUILD_PATH`
  set, and only that subprocess compiles.

  ## Options

    * `--out` - where to write the index. Defaults to `.grasp/index.json`.
    * `--base` - a git ref to compare against. Each function is marked added, modified,
      unchanged or removed against the merge base of `REF` and `HEAD`, and the functions
      that commit defines and this one no longer does are written as removed records.
    * `--no-tests` - leaves the project's tests out. Without it, a project with test
      paths has the test files `mix test` loads traced in the test environment, in a build
      directory of their own, `_build/grasp_test` (see `Grasp.Index.TestTrace`), and written as records
      beside the application's.
    * `--build-path` - the build directory to compile in. Defaults to `_build/grasp`.
      Naming the project's own build directory runs the build in this session instead of
      a subprocess.

  `--in-build-path` is internal: it is how the subprocess is told that it is the one that
  compiles, and passing it by hand builds in whatever build directory the current session
  resolved.
  """

  use Mix.Task

  @switches [
    out: :string,
    base: :string,
    build_path: :string,
    in_build_path: :boolean,
    tests: :boolean
  ]
  @default_build_path "_build/grasp"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.index: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    build_path = Path.expand(Keyword.get(opts, :build_path, @default_build_path))

    if opts[:in_build_path] == true or build_path == Mix.Project.build_path() do
      build(opts)
    else
      seed(build_path)
      delegate(args, build_path)
    end
  end

  defp build(opts) do
    {:ok, summary} = Grasp.Index.Builder.run(Keyword.take(opts, [:out, :base, :tests]))

    Mix.shell().info(
      "Grasp index written to #{summary.path} " <>
        "(#{summary.functions} functions, #{summary.calls} calls, #{summary.hidden_calls} hidden" <>
        tests(summary) <> ")" <> changed_against(opts[:base], summary)
    )
  end

  defp tests(%{tests: 0}), do: ""
  defp tests(%{tests: tests}), do: ", #{tests} tests"

  # A build directory of its own starts as a copy of the one the project already has, so
  # the first run compiles the project rather than every dependency it carries. The copy
  # lands under a name of its own and is renamed into place, so a run interrupted halfway
  # leaves no half-copied directory for the next one to mistake for a finished seed.
  defp seed(build_path) do
    source = Mix.Project.build_path()
    staging = build_path <> ".seeding"

    if not File.dir?(build_path) and File.dir?(source) do
      Mix.shell().info(
        "Grasp: seeding #{Path.relative_to_cwd(build_path)} from #{Path.relative_to_cwd(source)}"
      )

      File.rm_rf!(staging)
      File.mkdir_p!(Path.dirname(build_path))
      File.cp_r!(source, staging)
      File.rename!(staging, build_path)
    end
  end

  # `MIX_BUILD_PATH` is read when a Mix session resolves its build path, which this one
  # already did: the compile has to happen in a session started with it set. `MIX_ENV` goes
  # with it, because the child inherits the shell's environment and not the environment the
  # parent was started in.
  defp delegate(args, build_path) do
    {_output, status} =
      System.cmd("mix", ["grasp.index", "--in-build-path" | args],
        env: [{"MIX_BUILD_PATH", build_path}, {"MIX_ENV", to_string(Mix.env())}],
        into: IO.stream()
      )

    if status != 0, do: exit({:shutdown, status})
  end

  defp changed_against(nil, _summary), do: ""
  defp changed_against(base, summary), do: ", #{summary.changed} changed against #{base}"
end
