defmodule Grasp.CoverageStoreTest do
  # The document lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Grasp.CoverageStore

  setup do
    on_exit(fn -> :ok = CoverageStore.load(Application.fetch_env!(:grasp, :coverage_path)) end)

    path =
      Path.join(System.tmp_dir!(), "grasp-coverage-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "the suite's coverage path holds no document, and that is no error" do
    assert CoverageStore.path() == Path.expand(Application.fetch_env!(:grasp, :coverage_path))
    assert CoverageStore.get() == nil
    assert CoverageStore.snapshot() == nil
  end

  test "a missing file is no coverage and no error", %{path: path} do
    assert :ok = CoverageStore.load(path)
    assert CoverageStore.path() == path
    assert CoverageStore.get() == nil
  end

  test "the poll picks up a file written where the store watches, and broadcasts", %{path: path} do
    :ok = CoverageStore.load(path)
    CoverageStore.subscribe()

    File.write!(path, Jason.encode!(document("SampleApp.Greeter.greet/2")))
    send(CoverageStore, :poll)

    assert_receive :coverage_reloaded, 1_000
    assert %{"functions" => %{"SampleApp.Greeter.greet/2" => _}} = CoverageStore.get()
    assert {generation, document} = CoverageStore.snapshot()
    assert is_integer(generation)
    assert document == CoverageStore.get()
  end

  test "every load is a generation of its own", %{path: path} do
    File.write!(path, Jason.encode!(document("SampleApp.Greeter.greet/2")))
    :ok = CoverageStore.load(path)
    {first, _document} = CoverageStore.snapshot()

    :ok = CoverageStore.reload()
    {second, _document} = CoverageStore.snapshot()

    assert second > first
  end

  test "a file that cannot be read keeps the previous document, logged once", %{path: path} do
    File.write!(path, Jason.encode!(document("SampleApp.Greeter.greet/2")))
    :ok = CoverageStore.load(path)
    before = CoverageStore.get()
    CoverageStore.subscribe()

    File.write!(path, "{not json")
    future = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> Kernel.+(5)
    File.touch!(path, future)

    log =
      capture_log(fn ->
        send(CoverageStore, :poll)
        assert {:error, _reason} = CoverageStore.reload()
        send(CoverageStore, :poll)
        _ = CoverageStore.path()
      end)

    assert length(String.split(log, "could not load coverage")) == 2
    refute_receive :coverage_reloaded
    assert CoverageStore.get() == before
  end

  test "a document of another version is refused", %{path: path} do
    File.write!(path, Jason.encode!(%{"version" => 2, "functions" => %{}}))

    log =
      capture_log(fn ->
        assert {:error, {:unsupported_document, 2}} = CoverageStore.load(path)
      end)

    assert log =~ "could not load coverage"
    assert CoverageStore.get() == nil
  end

  test "a file that goes away takes its coverage with it", %{path: path} do
    File.write!(path, Jason.encode!(document("SampleApp.Greeter.greet/2")))
    :ok = CoverageStore.load(path)
    CoverageStore.subscribe()

    File.rm!(path)
    send(CoverageStore, :poll)

    assert_receive :coverage_reloaded, 1_000
    assert CoverageStore.get() == nil
  end

  test "the store starts after the index store" do
    children = Grasp.Application.children(true, false)
    at = &Enum.find_index(children, fn child -> child == {&1, []} end)

    assert at.(Grasp.CoverageStore) == at.(Grasp.IndexStore) + 1
  end

  test "the watched path defaults to coverage.json beside the index" do
    previous = Application.get_env(:grasp, :coverage_path)
    Application.put_env(:grasp, :coverage_path, nil)
    on_exit(fn -> Application.put_env(:grasp, :coverage_path, previous) end)

    {:ok, state} = CoverageStore.init([])

    assert state.path ==
             Path.expand(
               Path.join(Path.dirname(Grasp.IndexStore.configured_path()), "coverage.json")
             )
  end

  defp document(id) do
    %{
      "version" => 1,
      "generated_at" => "2026-09-28T12:00:00Z",
      "git_head" => nil,
      "index_generated_at" => nil,
      "functions" => %{id => %{"source_hash" => "0", "lines" => %{"3" => 1}}}
    }
  end
end
