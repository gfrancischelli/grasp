defmodule Grasp.ResultsStoreTest do
  # The document lives in :persistent_term, so swapping it out would be seen by every other
  # test running at the same time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Grasp.ResultsStore

  @test_id ~S|SampleApp.TallyTest."test init keeps the start count"/1|

  setup do
    on_exit(fn -> :ok = ResultsStore.load(Application.fetch_env!(:grasp, :results_path)) end)

    path =
      Path.join(System.tmp_dir!(), "grasp-results-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "the suite's results path holds no document, and that is no error" do
    assert ResultsStore.path() == Path.expand(Application.fetch_env!(:grasp, :results_path))
    assert ResultsStore.get() == nil
    assert ResultsStore.snapshot() == nil
  end

  test "a missing file is no results and no error", %{path: path} do
    assert :ok = ResultsStore.load(path)
    assert ResultsStore.path() == path
    assert ResultsStore.get() == nil
  end

  test "the poll picks up a file written where the store watches, and broadcasts", %{path: path} do
    :ok = ResultsStore.load(path)
    ResultsStore.subscribe()

    :ok = Grasp.TestResults.write(document("passed"), path)
    send(ResultsStore, :poll)

    assert_receive :results_reloaded, 1_000
    assert %{"tests" => %{@test_id => %{"status" => "passed"}}} = ResultsStore.get()
    assert {generation, document} = ResultsStore.snapshot()
    assert is_integer(generation)
    assert document == ResultsStore.get()
  end

  test "a rewrite is picked up by the next poll", %{path: path} do
    :ok = Grasp.TestResults.write(document("passed"), path)
    :ok = ResultsStore.load(path)
    {first, _document} = ResultsStore.snapshot()
    ResultsStore.subscribe()

    :ok = Grasp.TestResults.write(document("failed"), path)
    future = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> Kernel.+(5)
    File.touch!(path, future)
    send(ResultsStore, :poll)

    assert_receive :results_reloaded, 1_000
    assert %{"tests" => %{@test_id => %{"status" => "failed"}}} = ResultsStore.get()
    assert {second, _document} = ResultsStore.snapshot()
    assert second > first
  end

  test "a file that cannot be read keeps the previous document, logged once", %{path: path} do
    :ok = Grasp.TestResults.write(document("passed"), path)
    :ok = ResultsStore.load(path)
    before = ResultsStore.get()
    ResultsStore.subscribe()

    File.write!(path, "{not json")
    future = path |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> Kernel.+(5)
    File.touch!(path, future)

    log =
      capture_log(fn ->
        send(ResultsStore, :poll)
        assert {:error, _reason} = ResultsStore.reload()
        send(ResultsStore, :poll)
        _ = ResultsStore.path()
      end)

    assert length(String.split(log, "could not load test results")) == 2
    refute_receive :results_reloaded
    assert ResultsStore.get() == before
  end

  test "a file that goes away takes its results with it", %{path: path} do
    :ok = Grasp.TestResults.write(document("passed"), path)
    :ok = ResultsStore.load(path)
    ResultsStore.subscribe()

    File.rm!(path)
    send(ResultsStore, :poll)

    assert_receive :results_reloaded, 1_000
    assert ResultsStore.get() == nil
  end

  test "the store starts after the coverage store" do
    children = Grasp.Application.children(true, false)
    at = &Enum.find_index(children, fn child -> child == {&1, []} end)

    assert at.(Grasp.ResultsStore) == at.(Grasp.CoverageStore) + 1
  end

  test "the watched path defaults to results.json beside the index" do
    previous = Application.get_env(:grasp, :results_path)
    Application.put_env(:grasp, :results_path, nil)
    on_exit(fn -> Application.put_env(:grasp, :results_path, previous) end)

    {:ok, state} = ResultsStore.init([])

    assert state.path ==
             Path.expand(
               Path.join(Path.dirname(Grasp.IndexStore.configured_path()), "results.json")
             )
  end

  defp document(status) do
    %{
      "version" => 1,
      "tests" => %{
        @test_id => %{
          "status" => status,
          "time" => 12,
          "run_id" => "0",
          "finished_at" => "2026-09-28T12:00:00Z",
          "source_hash" => nil
        }
      }
    }
  end
end
