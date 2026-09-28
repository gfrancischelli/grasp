defmodule Grasp.ReindexerTest do
  # The compiler options are global to the VM and the index store is a singleton, so this
  # module owns both for as long as it runs and puts them back afterwards.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Grasp.Index.Tracer

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/index.json", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    tracers = Code.get_compiler_option(:tracers)
    parser = Code.get_compiler_option(:parser_options)
    store_path = Grasp.IndexStore.path()
    home = Grasp.Application.home()

    on_exit(fn ->
      Code.put_compiler_option(:tracers, tracers)
      Code.put_compiler_option(:parser_options, parser)
      Application.put_env(:grasp, :home, home)
      Grasp.IndexStore.load(store_path)
    end)

    Application.put_env(:grasp, :home, tmp_dir)

    document =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["project", "root"], tmp_dir)
      |> put_in(["git", "base_sha"], repository(tmp_dir))

    index_path = Path.join(tmp_dir, "index.json")
    File.write!(index_path, Jason.encode!(document, pretty: true))
    :ok = Grasp.IndexStore.load(index_path)

    start_supervised!({Grasp.Reindexer, index_path: index_path})

    %{index_path: index_path, root: tmp_dir}
  end

  test "installs the tracer into the running VM's compiler options" do
    assert Tracer in Code.get_compiler_option(:tracers)
    assert Code.get_compiler_option(:parser_options)[:columns] == true
  end

  test "a compile lands in the index file and in the store", %{index_path: index_path, root: root} do
    # The file is renamed into place before the store rebuilds from it, so the store is read
    # only once it says it has reloaded.
    Grasp.IndexStore.subscribe()
    module = compile(root, "lib/sample_app/probe.ex", "Enum.map(list, &Integer.to_string/1)")
    id = "#{inspect(module)}.run/1"

    record = await(fn -> fetch(index_path, id) end)
    assert record["file"] == "lib/sample_app/probe.ex"
    assert record["kind"] == "def"
    assert "Enum.map/2" in Enum.map(record["calls"], & &1["target"])

    # The base commit holds the project without this file, so the record reads as one the
    # branch added — classified against a real repository, not against a git that failed.
    assert record["change"] == "added"

    assert_receive :index_reloaded, 2_000
    assert {:ok, ^record} = Grasp.Index.fetch_function(Grasp.IndexStore.get(), id)
  end

  test "leaves the records of every other file alone", %{index_path: index_path, root: root} do
    before = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("functions")
    module = compile(root, "lib/sample_app/probe.ex", "Enum.count(list)")

    await(fn -> fetch(index_path, "#{inspect(module)}.run/1") end)
    document = read(index_path)

    kept = Enum.reject(document["functions"], &(&1["file"] == "lib/sample_app/probe.ex"))
    assert Map.new(kept, &{&1["id"], &1}) == Map.new(before, &{&1["id"], &1})
    assert document["project"]["root"] == root
    assert document["git"]["base_ref"] == "main"
  end

  test "two compiles inside one window are one update", %{index_path: index_path, root: root} do
    Grasp.IndexStore.subscribe()
    first = compile(root, "lib/sample_app/probe_one.ex", "Enum.count(list)")
    second = compile(root, "lib/sample_app/probe_two.ex", "Enum.reverse(list)")

    assert_receive :index_reloaded, 2_000
    refute_receive :index_reloaded, 500

    assert fetch(index_path, "#{inspect(first)}.run/1")
    assert fetch(index_path, "#{inspect(second)}.run/1")
  end

  test "pauses while the loaded index describes another tree", %{
    index_path: index_path,
    root: root
  } do
    # A pause is a state rather than a fault, so it is reported at info, which this
    # environment's logger drops.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    Application.put_env(:grasp, :home, Path.join(root, "elsewhere"))
    before = File.read!(index_path)

    log =
      capture_log(fn ->
        module = compile(root, "lib/sample_app/probe.ex", "Enum.count(list)")
        Process.sleep(600)
        refute fetch(index_path, "#{inspect(module)}.run/1")
      end)

    assert log =~ "live reindexing is paused"
    assert File.read!(index_path) == before
  end

  test "an event older than the file it names is not joined to it",
       %{index_path: index_path, root: root} do
    before = File.read!(index_path)
    module = compile(root, "lib/sample_app/probe.ex", "Enum.count(list)")
    File.touch!(Path.join(root, "lib/sample_app/probe.ex"), System.os_time(:second) + 5)

    Process.sleep(600)

    refute fetch(index_path, "#{inspect(module)}.run/1")
    assert File.read!(index_path) == before
  end

  test "a flush that could not write keeps its events for the next one",
       %{index_path: index_path, root: root} do
    first = compile(root, "lib/sample_app/probe_one.ex", "Enum.count(list)")
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    capture_log(fn ->
      Process.sleep(600)
      refute fetch(index_path, "#{inspect(first)}.run/1")
    end)

    File.chmod!(root, 0o700)
    second = compile(root, "lib/sample_app/probe_two.ex", "Enum.reverse(list)")

    await(fn -> fetch(index_path, "#{inspect(second)}.run/1") end)
    assert fetch(index_path, "#{inspect(first)}.run/1")
  end

  test "a batch that never lands stops growing", %{index_path: index_path, root: root} do
    stop_supervised!(Grasp.Reindexer)
    start_supervised!({Grasp.Reindexer, index_path: index_path, max_pending: 2})
    File.write!(index_path, "{ this is not an index")

    log =
      capture_log(fn ->
        compile(root, "lib/sample_app/probe_one.ex", "Enum.count(list) + Enum.sum(list)")
        Process.sleep(600)
        compile(root, "lib/sample_app/probe_two.ex", "Enum.max(list) + Enum.min(list)")
        Process.sleep(600)
      end)

    assert length(String.split(log, "traced calls are waiting")) == 2
    assert length(:sys.get_state(Process.whereis(Grasp.Reindexer)).pending) == 2
  end

  test "a document with no project root is reported, not raised", %{
    index_path: index_path,
    root: root
  } do
    File.write!(index_path, Jason.encode!(%{"version" => 1, "functions" => [], "project" => %{}}))

    log =
      capture_log(fn ->
        compile(root, "lib/sample_app/probe.ex", "Enum.count(list)")
        Process.sleep(600)
      end)

    assert log =~ "no_project_root"
    assert Process.alive?(Process.whereis(Grasp.Reindexer))
  end

  # The module is compiled from a file that exists on disk, because the update re-extracts
  # the files the compiler reported: a name unique to the run keeps the beam this test
  # loads from colliding with another's.
  defp compile(root, relative, body) do
    module = Module.concat([SampleApp, "Probe#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(module)} do
      @moduledoc "A module compiled while the reindexer is watching."

      @doc "Runs."
      def run(list), do: #{body}
    end
    """

    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Code.compile_string(source, path)
    module
  end

  # A commit holding the project as it stands before any probe file is written, so the
  # classification a flush performs is against a repository that answers.
  defp repository(root) do
    git = fn args -> {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end
    File.mkdir_p!(Path.join(root, "lib/sample_app"))
    File.write!(Path.join(root, "lib/sample_app/.keep"), "")
    git.(["init", "--quiet"])
    git.(["config", "user.email", "grasp@example.com"])
    git.(["config", "user.name", "Grasp"])
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "base"])

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    String.trim(sha)
  end

  defp await(fun, remaining \\ 2_000) do
    case fun.() do
      nil when remaining > 0 ->
        Process.sleep(20)
        await(fun, remaining - 20)

      nil ->
        flunk("the index was not updated within two seconds")

      value ->
        value
    end
  end

  defp fetch(index_path, id) do
    index_path |> read() |> Map.fetch!("functions") |> Enum.find(&(&1["id"] == id))
  end

  defp read(index_path), do: index_path |> File.read!() |> Jason.decode!()
end
