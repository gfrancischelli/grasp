# Traces a project's tests without running them. `Grasp.Index.TestTrace` runs this file in
# the project's test environment:
#
#     MIX_ENV=test mix run --no-start --no-compile test_trace.exs \
#       EVENTS_FILE GRASP_EBIN SOURCEROR_EBIN DEV_PATHS
#
# DEV_PATHS is the dev environment's `elixirc_paths`, joined by commas. The project is
# compiled first with no tracer, so an unchanged tree compiles nothing. The tracer is then
# installed and the test-only support files — the `.ex` files the test environment compiles
# and the dev environment does not — are required, followed by every `test/**/*_test.exs`.
# Requiring a test file defines its module and registers its tests with an ExUnit that is
# never told to run them. `test_helper.exs` is not required: it starts repositories and
# sandboxes the trace has no use for.
#
# The events recorded in the required files, with each file relative to the project root,
# are written to EVENTS_FILE as `%{events: events, files: files}` in the external term
# format. A file that does not compile stops the script with a non-zero status, after the
# compiler has printed its errors.

[events_file, grasp_ebin, sourceror_ebin, dev_paths] = System.argv()

# Only these two directories: the host's own dependencies — its `jason`, its `phoenix` — keep
# the versions the test environment compiled.
Code.prepend_path(sourceror_ebin)
Code.prepend_path(grasp_ebin)
{:module, _} = Code.ensure_loaded(Grasp.Index.Tracer)

# `--no-compile` reached the dependencies' load paths too, so they are loaded again with
# compilation allowed: a build directory seeded from nothing holds no compiled dependency.
Mix.Task.reenable("deps.loadpaths")
Mix.Task.reenable("loadpaths")
Mix.Task.run("compile")

root = File.cwd!()
dev_roots = dev_paths |> String.split(",", trim: true) |> Enum.map(&(Path.expand(&1, root) <> "/"))

support =
  Mix.Project.config()
  |> Keyword.get(:elixirc_paths, ["lib"])
  |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.ex"])))
  |> Enum.map(&Path.expand/1)
  |> Enum.reject(fn file -> Enum.any?(dev_roots, &String.starts_with?(file, &1)) end)
  |> Enum.uniq()
  |> Enum.sort()

tests = root |> Path.join("test/**/*_test.exs") |> Path.wildcard() |> Enum.sort()

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

File.write!(events_file, :erlang.term_to_binary(%{events: events, files: files}))
