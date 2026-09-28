# Traces a project's tests without running them. `Grasp.Index.TestTrace` runs this file in
# the project's test environment:
#
#     MIX_ENV=test mix run --no-start test_trace.exs \
#       EVENTS_FILE GRASP_EBIN DEV_PATHS CANDIDATES
#
# DEV_PATHS is the dev environment's `elixirc_paths`, joined by commas, and CANDIDATES a file
# holding, in the external term format, project-relative paths the caller wants judged.
# `mix run` compiles the dependencies and the project before this script starts, with no
# tracer installed and with Grasp absent from the code path, so an unchanged tree compiles
# nothing and a host guard such as `Code.ensure_loaded?(Grasp.Router)` reads false in the
# test build, as it does in `mix test`. Grasp's ebin goes on the path only after that
# compile. The tracer is then installed and the test-only support files — the `.ex` files
# the test environment compiles and the dev environment does not — are required, followed
# by the test files `mix test` loads, chosen from this environment's project config by
# `Grasp.Index.TestTrace.test_files/2`.
# Requiring a test file defines its module and registers its tests with an ExUnit that is
# never told to run them. `test_helper.exs` is not required: it starts repositories and
# sandboxes the trace has no use for.
#
# The events recorded in the required files, with each file relative to the project root,
# are written to EVENTS_FILE as `%{events: events, files: files, test_paths: test_paths,
# selected: selected}` in the external term format, `selected` being the CANDIDATES that
# `mix test` would load were they on disk. A file that does not compile stops the script with
# a non-zero status, after the compiler has printed its errors.

[events_file, grasp_ebin, dev_paths, candidates_file] = System.argv()

# Grasp's ebin alone: the tracer and the test file selection call nothing outside Elixir and
# Grasp, and every module the host's dependencies provide keeps the version the test
# environment compiled.
Code.prepend_path(grasp_ebin)
{:module, _} = Code.ensure_loaded(Grasp.Index.Tracer)

root = File.cwd!()
config = Mix.Project.config()
dev_roots = dev_paths |> String.split(",", trim: true) |> Enum.map(&(Path.expand(&1, root) <> "/"))

support =
  config
  |> Keyword.get(:elixirc_paths, ["lib"])
  |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.ex"])))
  |> Enum.map(&Path.expand/1)
  |> Enum.reject(fn file -> Enum.any?(dev_roots, &String.starts_with?(file, &1)) end)
  |> Enum.uniq()
  |> Enum.sort()

selection = Grasp.Index.TestTrace.test_files(config, root)
tests = selection.files |> Enum.map(&Path.expand(&1, root)) |> Enum.reject(&(&1 in support))
candidates = candidates_file |> File.read!() |> :erlang.binary_to_term()
selected = Grasp.Index.TestTrace.would_load(config, selection.test_paths, candidates)

Grasp.Index.Tracer.start()
Grasp.Index.Tracer.install()
Code.put_compiler_option(:parser_options, columns: true)
Code.compiler_options(ignore_module_conflict: true)
ExUnit.start(autorun: false)

for files <- [support, tests], files != [] do
  case Kernel.ParallelCompiler.require(files, return_diagnostics: true) do
    {:ok, _modules, _diagnostics} -> :ok
    {:error, _errors, _diagnostics} -> exit({:shutdown, 1})
  end
end

required = MapSet.new(support ++ tests)

events =
  Grasp.Index.Tracer.take_events()
  |> Enum.map(&%{&1 | file: Path.expand(&1.file, root)})
  |> Enum.filter(&MapSet.member?(required, &1.file))
  |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, root)})

files = Enum.map(support ++ tests, &Path.relative_to(&1, root))

File.write!(
  events_file,
  :erlang.term_to_binary(%{
    events: events,
    files: files,
    test_paths: selection.test_paths,
    selected: selected
  })
)
