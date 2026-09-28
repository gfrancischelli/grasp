defmodule Grasp.MCP.RunToolsTest do
  # One run at a time is the whole viewer's, and the index and the results document live in
  # :persistent_term, so these tests share them and run alone.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.{CoverageStore, IndexStore, ResultsStore, Runs, TestResults}
  alias Grasp.MCP.Tools

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @reply ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @plain ~s|SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1|
  @greet "SampleApp.Greeter.greet/2"

  setup do
    root = Path.join(System.tmp_dir!(), "grasp-run-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:grasp, :runs_root)
    previous_command = Application.get_env(:grasp, :runs_command)
    Application.put_env(:grasp, :runs_root, root)
    results = ResultsStore.path()
    :ok = Runs.subscribe()

    on_exit(fn ->
      Runs.cancel()
      Application.put_env(:grasp, :runs_root, previous_root)
      Application.put_env(:grasp, :runs_command, previous_command)
      File.rm_rf(root)
      File.rm(results)
      :ok = ResultsStore.reload()
    end)

    %{results: results}
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp call(tool, params) do
    {:reply, resp, _frame} = tool.execute(params, %Frame{})
    resp
  end

  defp ok!(tool, params \\ %{}) do
    resp = call(tool, params)
    refute resp.isError
    json!(resp)
  end

  defp error!(tool, params) do
    resp = call(tool, params)
    assert resp.isError
    [%{"text" => text}] = resp.content
    text
  end

  defp hold_the_run do
    Application.put_env(:grasp, :runs_command, ["sh", "-c", "echo up; sleep 30", "fake-mix"])
  end

  describe "run_tests" do
    test "starts mix grasp.test on the ids, and answers what it started at once" do
      assert %{"started" => run} = ok!(Tools.RunTests, %{test_ids: [@init, @reply, @init]})

      assert %{
               "kind" => "tests",
               "description" => "mix grasp.test (2 tests)",
               "line_count" => 0
             } = run

      assert run["argv"] == tests_argv([@init, @reply])
      refute Map.has_key?(run, "finished_at")
      id = run["id"]
      assert_receive {:run_finished, %{id: ^id, exit_status: 0}}, 2_000
    end

    test "answers the run already under way, which it leaves running" do
      hold_the_run()
      assert %{"started" => %{"id" => id}} = ok!(Tools.RunCoverage)
      assert_receive {:run_output, ^id, _seq, "up"}, 2_000

      assert %{"running" => %{"id" => ^id, "kind" => "coverage"}} =
               ok!(Tools.RunTests, %{test_ids: [@init]})

      assert %{current: %{id: ^id}} = Runs.status()
    end

    test "an id the index holds no test for is an error naming every such id, and starts nothing" do
      message = error!(Tools.RunTests, %{test_ids: [@init, @greet, "SampleApp.Nowhere.x/1"]})

      assert message ==
               ~s|the index holds no test for "#{@greet}", "SampleApp.Nowhere.x/1"|

      refute_receive {:run_started, _run}, 200
    end

    test "takes exactly one of test_ids and changed" do
      for params <- [%{}, %{test_ids: []}, %{changed: false}, %{test_ids: [@init], changed: true}] do
        assert error!(Tools.RunTests, params) =~ "pass either test_ids"
      end

      refute_receive {:run_started, _run}, 200
    end

    test "changed runs the tests the branch added or modified" do
      :ok = IndexStore.load(with_changes(%{@reply => "modified", @plain => "added"}))
      on_exit(fn -> :ok = IndexStore.load(@fixture) end)

      assert %{"started" => %{"argv" => argv}} = ok!(Tools.RunTests, %{changed: true})
      assert argv == tests_argv([@reply, @plain])
      assert_receive {:run_finished, _run}, 2_000
    end

    test "changed with no changed test is an error saying so" do
      assert error!(Tools.RunTests, %{changed: true}) == "the branch added or modified no test"
    end

    test "changed over an index without a base ref is the error the task gives" do
      :ok = IndexStore.load(with_changes(%{@reply => "modified"}, git: nil))
      on_exit(fn -> :ok = IndexStore.load(@fixture) end)

      assert error!(Tools.RunTests, %{changed: true}) ==
               "the index has no base ref; run mix grasp.index --base REF first"
    end
  end

  describe "run_coverage" do
    test "starts mix grasp.cover" do
      assert %{"started" => %{"kind" => "coverage", "description" => "mix grasp.cover"} = run} =
               ok!(Tools.RunCoverage)

      assert run["argv"] ==
               Runs.command() ++
                 ["grasp.cover", "--index", IndexStore.path(), "--out", CoverageStore.path()]

      assert_receive {:run_finished, %{kind: :coverage}}, 2_000
    end
  end

  describe "run_status" do
    test "answers idle before any run" do
      # The server is the whole suite's, so only a fresh one has run nothing. Restarting it
      # is safe here: this module runs alone, the stores hear runs through PubSub rather than
      # through the server's pid, and no other module reads the last run across tests.
      :ok = Supervisor.terminate_child(Grasp.Supervisor, Runs)
      {:ok, _pid} = Supervisor.restart_child(Grasp.Supervisor, Runs)

      assert ok!(Tools.RunStatus) == %{"idle" => true}
    end

    test "answers the running command with its last 50 lines" do
      Application.put_env(:grasp, :runs_command, [
        "sh",
        "-c",
        "i=1; while [ $i -le 60 ]; do echo line $i; i=$((i+1)); done; sleep 30",
        "fake-mix"
      ])

      assert %{"started" => %{"id" => id}} = ok!(Tools.RunCoverage)
      assert_receive {:run_output, ^id, 60, "line 60"}, 2_000

      assert %{"running" => %{"id" => ^id, "line_count" => 60, "output" => output}} =
               ok!(Tools.RunStatus)

      assert output == for(i <- 11..60, do: "line #{i}")
    end

    test "answers the last coverage run's exit status" do
      Application.put_env(:grasp, :runs_command, ["sh", "-c", "exit 2", "fake-mix"])
      assert %{"started" => %{"id" => id}} = ok!(Tools.RunCoverage)
      assert_receive {:run_finished, %{id: ^id}}, 2_000

      assert %{"last" => last} = ok!(Tools.RunStatus)

      assert %{"id" => ^id, "kind" => "coverage", "exit_status" => 2, "cancelled" => false} =
               last

      refute Map.has_key?(last, "tests")
    end

    test "answers the last test run with each of its tests' results", %{results: results} do
      Application.put_env(:grasp, :runs_command, ["sh", "-c", "exit 2", "fake-mix"])

      assert %{"started" => %{"id" => id}} =
               ok!(Tools.RunTests, %{test_ids: [@init, @reply, @plain]})

      assert_receive {:run_finished, %{id: id_finished}}, 2_000
      assert id_finished == id

      # The run is a stand-in, so the results it would have written are written here: @init
      # failed under Counter.init/1, @reply passed, and @plain holds a result from before
      # the run started, which is not this run's.
      failure = %{
        "kind" => "error",
        "message" => "Assertion with == failed",
        "expr" => "assert init_with(7) == {:ok, 8}",
        "left" => "{:ok, 7}",
        "right" => "{:ok, 8}",
        "stacktrace" => [
          frame("Enum", "map", 2, "lib/enum.ex", 1),
          frame("SampleApp.Counter", "init", 1, "lib/sample_app/counter.ex", 8),
          frame(
            "SampleApp.TallyTest",
            "test init keeps the start count",
            1,
            "test/sample_app/tally_test.exs",
            18
          )
        ]
      }

      recorded = DateTime.to_iso8601(DateTime.utc_now())

      document =
        nil
        |> TestResults.merge(%{@plain => %{"status" => "passed"}}, %{
          run_id: "r0",
          finished_at: "2026-01-01T00:00:00Z",
          index: IndexStore.get()
        })
        |> TestResults.merge(
          %{
            @init => %{"status" => "failed", "errors" => [failure]},
            @reply => %{"status" => "passed"}
          },
          %{run_id: "r1", finished_at: recorded, index: IndexStore.get()}
        )

      :ok = TestResults.write(document, results)
      :ok = ResultsStore.reload()

      assert %{"last" => last} = ok!(Tools.RunStatus)
      assert %{"id" => ^id, "kind" => "tests", "exit_status" => 2, "cancelled" => false} = last

      assert last["tests"] == [
               %{
                 "id" => @init,
                 "status" => "failed",
                 "error" => %{
                   "message" => "Assertion with == failed",
                   "left" => "{:ok, 7}",
                   "right" => "{:ok, 8}",
                   "frame" => %{
                     "id" => "SampleApp.Counter.init/1",
                     "file" => "lib/sample_app/counter.ex",
                     "line" => 8
                   }
                 }
               },
               %{"id" => @reply, "status" => "passed"},
               %{"id" => @plain, "status" => "none"}
             ]
    end

    test "a result recorded against another version of the test reads stale", %{results: results} do
      assert %{"started" => %{"id" => id}} = ok!(Tools.RunTests, %{test_ids: [@init]})
      assert_receive {:run_finished, %{id: ^id}}, 2_000

      document =
        TestResults.merge(nil, %{@init => %{"status" => "passed"}}, %{
          run_id: "r1",
          finished_at: DateTime.to_iso8601(DateTime.utc_now()),
          index: IndexStore.get()
        })

      document = put_in(document, ["tests", @init, "source_hash"], "0")
      :ok = TestResults.write(document, results)
      :ok = ResultsStore.reload()

      assert %{"last" => %{"tests" => [%{"id" => @init, "status" => "stale"}]}} =
               ok!(Tools.RunStatus)
    end

    test "answers a finished run's results before the store has heard it finish", %{
      results: results
    } do
      staged = results <> ".staged"
      on_exit(fn -> File.rm(staged) end)
      write_results_when_staged(staged, results)

      assert %{"started" => %{"id" => id}} = ok!(Tools.RunTests, %{test_ids: [@init]})
      :ok = :sys.suspend(ResultsStore)
      on_exit(fn -> :sys.resume(ResultsStore) end)
      stage(staged, [@init], DateTime.utc_now())
      assert_receive {:run_finished, %{id: ^id, exit_status: 0}}, 2_000

      # The store holds the document from before the run, and has not read the one the run
      # wrote: the answer waits for a read of it rather than answering from the old one.
      assert ResultsStore.get() == nil
      status = Task.async(fn -> ok!(Tools.RunStatus) end)
      assert Task.yield(status, 200) == nil

      :ok = :sys.resume(ResultsStore)

      assert {:ok, %{"last" => %{"id" => ^id, "tests" => tests}}} = Task.yield(status, 2_000)
      assert tests == [%{"id" => @init, "status" => "passed"}]
    end

    test "answers from the store without a read once it has read the run's results", %{
      results: results
    } do
      staged = results <> ".staged"
      on_exit(fn -> File.rm(staged) end)
      write_results_when_staged(staged, results)

      assert %{"started" => %{"id" => id}} = ok!(Tools.RunTests, %{test_ids: [@init]})
      stage(staged, [@init], DateTime.utc_now())
      assert_receive {:run_finished, %{id: ^id}}, 2_000
      :ok = ResultsStore.reload()

      :ok = :sys.suspend(ResultsStore)
      on_exit(fn -> :sys.resume(ResultsStore) end)
      status = Task.async(fn -> ok!(Tools.RunStatus) end)

      assert {:ok, %{"last" => %{"tests" => [%{"id" => @init, "status" => "passed"}]}}} =
               Task.yield(status, 1_000)
    end

    test "a result finishing in the millisecond the run started is the run's", %{
      results: results
    } do
      assert %{"started" => %{"id" => id}} = ok!(Tools.RunTests, %{test_ids: [@init]})
      assert_receive {:run_finished, %{id: ^id, started_at: started_at}}, 2_000

      document =
        TestResults.merge(nil, %{@init => %{"status" => "passed"}}, %{
          run_id: "r1",
          finished_at: started_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
          index: IndexStore.get()
        })

      :ok = TestResults.write(document, results)
      :ok = ResultsStore.reload()

      assert %{"last" => %{"tests" => [%{"id" => @init, "status" => "passed"}]}} =
               ok!(Tools.RunStatus)
    end

    test "a cancelled run answers a null exit status" do
      hold_the_run()
      assert %{"started" => %{"id" => id}} = ok!(Tools.RunTests, %{test_ids: [@init]})
      assert_receive {:run_output, ^id, _seq, "up"}, 2_000
      {:ok, _run} = Runs.cancel()

      assert %{"last" => %{"id" => ^id, "exit_status" => nil, "cancelled" => true} = last} =
               ok!(Tools.RunStatus)

      assert last["tests"] == [%{"id" => @init, "status" => "none"}]
    end
  end

  defp tests_argv(ids) do
    Runs.command() ++
      ["grasp.test", "--index", IndexStore.path(), "--out", ResultsStore.path(), "--" | ids]
  end

  # A stand-in for the task that writes the results document once the test has staged it,
  # so the document carries a finish time taken after the run started.
  defp write_results_when_staged(staged, results) do
    Application.put_env(:grasp, :runs_command, [
      "sh",
      "-c",
      ~S|while [ ! -f "$1" ]; do sleep 0.02; done; cp "$1" "$2"|,
      "fake-mix",
      staged,
      results
    ])
  end

  defp stage(staged, ids, finished_at) do
    results = Map.new(ids, &{&1, %{"status" => "passed"}})

    document =
      TestResults.merge(nil, results, %{
        run_id: "r1",
        finished_at: DateTime.to_iso8601(finished_at),
        index: IndexStore.get()
      })

    :ok = TestResults.write(document, staged <> ".tmp")
    File.rename!(staged <> ".tmp", staged)
  end

  defp frame(module, function, arity, file, line),
    do: %{
      "module" => module,
      "function" => function,
      "arity" => arity,
      "file" => file,
      "line" => line
    }

  defp with_changes(changes, opts \\ []) do
    path =
      Path.join(System.tmp_dir!(), "grasp-run-tools-#{System.unique_integer([:positive])}.json")

    document =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("functions", fn records ->
        Enum.map(records, fn record ->
          case changes[record["id"]] do
            nil -> record
            change -> Map.put(record, "change", change)
          end
        end)
      end)

    document =
      if Keyword.has_key?(opts, :git), do: Map.put(document, "git", opts[:git]), else: document

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
