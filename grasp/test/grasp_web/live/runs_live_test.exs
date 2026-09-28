defmodule GraspWeb.RunsLiveTest do
  # One run at a time is the whole viewer's, and the results document lives in
  # :persistent_term, so these tests share both and run alone.
  use GraspWeb.ConnCase, async: false

  alias Grasp.{IndexStore, ResultsStore, Runs, Session, TestResults}

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @reply ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
  @init ~s|SampleApp.TallyTest."test init keeps the start count"/1|
  @plain ~s|SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1|
  @verified ~s|SampleAppWeb.RoutesTest."test a verified path reaches the controller"/1|
  @greet "SampleApp.Greeter.greet/2"
  @handle_call "SampleApp.Counter.handle_call/3"

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "grasp-runs-live-#{System.unique_integer([:positive])}")
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

    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name, results: results}
  end

  describe "the runs panel" do
    test "toggles from the toolbar, and takes the chat panel's place", %{view: view} do
      assert has_element?(view, "#runs[hidden]")
      assert has_element?(view, "#canvas .toolbar #toggle-runs[data-tip]", "runs")
      refute has_element?(view, "#canvas .toolbar #toggle-runs[data-key]")

      view |> element("#toggle-runs") |> render_click()
      refute has_element?(view, "#runs[hidden]")
      # The last run is the whole viewer's, so what the header names depends on what ran
      # before; that it names something is the panel's.
      assert has_element?(view, "#runs[phx-hook='Runs'] .runs__header .runs__description")
      assert has_element?(view, "#runs #runs-log[phx-update='stream']")

      view |> element("#toggle-chat") |> render_click()
      assert has_element?(view, "#runs[hidden]")
      refute has_element?(view, "#chat[hidden]")

      view |> element("#toggle-runs") |> render_click()
      refute has_element?(view, "#runs[hidden]")
      assert has_element?(view, "#chat[hidden]")

      view |> element("#toggle-runs") |> render_click()
      assert has_element?(view, "#runs[hidden]")
    end

    test "sits in the toolbar after ask and before help", %{view: view} do
      html = render(view)

      positions =
        for id <- ~w(toggle-chat toggle-runs help-toggle) do
          {position, _length} = :binary.match(html, ~s(id="#{id}"))
          position
        end

      assert positions == Enum.sort(positions)
    end

    test "run coverage starts mix grasp.cover and streams what it prints", %{view: view} do
      view |> element("#toggle-runs") |> render_click()
      view |> element("#runs-coverage") |> render_click()

      assert_receive {:run_finished, %{kind: :coverage, argv: argv, exit_status: 0}}, 2_000
      assert argv == Runs.command() ++ ["grasp.cover"]

      eventually(view, fn -> has_element?(view, "#runs .runs__status", "finished") end)
      assert has_element?(view, "#runs .runs__description", "mix grasp.cover")
      assert has_element?(view, "#runs-log .runs__line", "arg grasp.cover")
    end

    test "shows the output as it streams, the run's finish, and cancel", %{view: view} do
      Application.put_env(:grasp, :runs_command, [
        "sh",
        "-c",
        "echo started; echo second; sleep 30",
        "fake-mix"
      ])

      view |> element("#toggle-runs") |> render_click()
      view |> element("#runs-coverage") |> render_click()

      assert_receive {:run_output, id, "second"}, 2_000
      eventually(view, fn -> has_element?(view, "#runs-log .runs__line", "second") end)

      assert elements(view, "#runs-log .runs__line") == ["started", "second"]
      assert has_element?(view, "#runs .runs__status[data-status='running']", "running")
      assert has_element?(view, "#toggle-runs[data-running='true']", "running…")

      view |> element("#runs-cancel") |> render_click()

      assert_receive {:run_finished, %{id: ^id, cancelled?: true}}, 2_000
      assert has_element?(view, "#runs .runs__status[data-status='cancelled']", "cancelled")
      refute has_element?(view, "#runs-cancel")
      assert has_element?(view, "#toggle-runs[data-running='false']", "runs")
      assert elements(view, "#runs-log .runs__line") == ["started", "second"]
    end

    test "a failing run says so with its exit status", %{view: view} do
      Application.put_env(:grasp, :runs_command, ["sh", "-c", "echo broke; exit 2", "fake-mix"])

      view |> element("#toggle-runs") |> render_click()
      view |> element("#runs-coverage") |> render_click()

      assert_receive {:run_finished, %{exit_status: 2}}, 2_000

      eventually(view, fn ->
        has_element?(view, "#runs .runs__status[data-status='failed']", "failed · exit 2")
      end)
    end

    test "cuts a long line and marks the cut", %{view: view} do
      Application.put_env(:grasp, :runs_command, [
        "sh",
        "-c",
        "printf '%05000d\\n' 0",
        "fake-mix"
      ])

      view |> element("#runs-coverage") |> render_click()
      assert_receive {:run_finished, %{exit_status: 0}}, 2_000

      eventually(view, fn -> has_element?(view, "#runs-log .runs__line") end)
      [line] = elements(view, "#runs-log .runs__line")
      assert line == String.duplicate("0", 4_000) <> "…"
    end

    test "a tab opened while a run is under way shows it and its output so far", %{conn: conn} do
      Application.put_env(:grasp, :runs_command, ["sh", "-c", "echo early; sleep 30", "fake-mix"])
      {:ok, %{id: id}} = Runs.start_coverage()
      assert_receive {:run_output, ^id, "early"}, 2_000

      {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")

      assert has_element?(view, "#toggle-runs", "running…")
      assert has_element?(view, "#runs .runs__description", "mix grasp.cover")
      assert elements(view, "#runs-log .runs__line") == ["early"]
    end
  end

  describe "run controls" do
    test "a test card's run runs that test and opens the panel", %{view: view} do
      render_click(view, "open_root", %{"id" => @init})
      assert has_element?(view, "#card-1 #run-1[title='Run this test']:not([disabled])", "run")

      view |> element("#run-1") |> render_click()

      assert_receive {:run_finished, %{kind: :tests, argv: argv, exit_status: 0}}, 2_000
      assert argv == Runs.command() ++ ["grasp.test", @init]

      refute has_element?(view, "#runs[hidden]")
      assert has_element?(view, "#runs .runs__description", "mix grasp.test #{@init}")

      # Each id reaches the command as an argument of its own, quotes and spaces kept.
      eventually(view, fn -> has_element?(view, "#runs-log .runs__line", "arg #{@init}") end)
      assert elements(view, "#runs-log .runs__line") == ["arg grasp.test", "arg #{@init}"]
    end

    test "a function card has no run of its own", %{view: view} do
      render_click(view, "open_root", %{"id" => @greet})
      refute has_element?(view, "#run-1")
    end

    test "the callers menu's run all runs every test it lists", %{view: view} do
      render_click(view, "open_root", %{"id" => @greet})
      view |> element("#card-1 .card__tests") |> render_click()

      assert has_element?(
               view,
               "#card-1 .callers__heading button.callers__run[title='Run every test listed']",
               "run all"
             )

      view |> element("#card-1 .callers__run") |> render_click()

      assert_receive {:run_finished, %{argv: argv}}, 2_000
      assert argv == Runs.command() ++ ["grasp.test", @verified, @plain]
      assert has_element?(view, "#runs .runs__description", "mix grasp.test (2 tests)")
    end

    test "the Changes group runs the tests the branch changed", %{conn: conn} do
      :ok = IndexStore.load(with_changed_tests())
      on_exit(fn -> :ok = IndexStore.load(@fixture) end)
      {:ok, view, _html} = live(conn, "/s/t-#{System.unique_integer([:positive])}")

      assert has_element?(view, "#group-changes > button#run-changed", "run changed tests")

      view |> element("#run-changed") |> render_click()

      assert_receive {:run_finished, %{argv: argv}}, 2_000
      assert argv == Runs.command() ++ ["grasp.test", @reply, @plain]
      refute has_element?(view, "#runs[hidden]")
    end

    test "the Changes group offers no run when the branch changed no test", %{view: view} do
      assert has_element?(view, "#group-changes")
      refute has_element?(view, "#run-changed")
    end

    test "every control that starts a run is disabled while one runs, titled with it", %{
      conn: conn
    } do
      :ok = IndexStore.load(with_changed_tests())
      on_exit(fn -> :ok = IndexStore.load(@fixture) end)
      name = "t-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/s/#{name}")

      Application.put_env(:grasp, :runs_command, ["sh", "-c", "echo up; sleep 30", "fake-mix"])
      Session.open_root(name, @init)
      Session.open_root(name, @greet)
      view |> element("#card-2 .card__tests") |> render_click()

      view |> element("#run-1") |> render_click()
      assert_receive {:run_output, id, "up"}, 2_000

      title = "Running mix grasp.test #{@init}"

      # A test id holds quotes, which no attribute selector can quote, so the titles are
      # read back rather than matched.
      for selector <- ["#run-1", "#card-2 .callers__run", "#run-changed", "#runs-coverage"] do
        assert has_element?(view, "#{selector}[disabled]")
        assert attribute(view, selector, "title") == title
      end

      assert has_element?(view, "#toggle-runs", "running…")

      # A start the page sends anyway is refused, and the run under way stands.
      render_click(view, "run_changed", %{})
      assert %{current: %{id: ^id}} = Runs.status()

      view |> element("#runs-cancel") |> render_click()
      assert_receive {:run_finished, %{id: ^id}}, 2_000

      assert has_element?(view, "#run-1[title='Run this test']:not([disabled])")
      assert has_element?(view, "#card-2 .callers__run:not([disabled])")
      assert has_element?(view, "#run-changed:not([disabled])")
      assert has_element?(view, "#runs-coverage:not([disabled])")
    end

    test "an id the index holds no test for starts nothing", %{view: view} do
      render_click(view, "run_test", %{"test" => @greet})
      render_click(view, "run_test", %{"test" => "SampleApp.Nowhere.\"test x\"/1"})

      refute_receive {:run_started, _run}, 200
      assert %{current: :idle} = Runs.status()
    end
  end

  describe "result badges" do
    setup %{results: results} do
      document =
        TestResults.merge(
          nil,
          %{
            @init => %{"status" => "passed"},
            @reply => %{"status" => "failed"},
            @plain => %{"status" => "skipped"},
            @verified => %{"status" => "failed"}
          },
          %{run_id: "r1", finished_at: "2026-09-28T12:00:00Z", index: IndexStore.get()}
        )

      # The verified test's result is recorded against a body other than the one indexed.
      document = put_in(document, ["tests", @verified, "source_hash"], "0")
      :ok = TestResults.write(document, results)
      :ok = ResultsStore.reload()
      :ok
    end

    test "a test card wears its latest result, or stale", %{view: view, name: name} do
      for id <- [@init, @reply, @plain, @verified], do: Session.open_root(name, id)

      assert has_element?(
               view,
               "#card-1 .card__header .badge--result[data-result='passed']",
               "passed"
             )

      assert has_element?(view, "#card-2 .badge--result[data-result='failed']", "failed")
      assert has_element?(view, "#card-3 .badge--result[data-result='skipped']", "skipped")
      assert has_element?(view, "#card-4 .badge--result[data-result='stale']", "stale")
    end

    test "a function card's tests badge counts the fresh failures", %{view: view, name: name} do
      Session.open_root(name, @handle_call)
      Session.open_root(name, @greet)

      assert has_element?(view, "#card-1 .card__tests[data-failing='1']", "1 test · 1 failing")
      # Of greet's two tests one is skipped and the other's failure is stale.
      assert has_element?(view, "#card-2 .card__tests:not([data-failing])", "2 tests")
      refute has_element?(view, "#card-2 .card__tests", "failing")
      refute has_element?(view, "#card-2 .badge--result")
    end

    test "a test with no result wears none", %{view: view, results: results, name: name} do
      File.rm!(results)
      :ok = ResultsStore.reload()
      Session.open_root(name, @init)

      assert has_element?(view, "#card-1")
      refute has_element?(view, "#card-1 .badge--result")
    end

    test "a finished test run reloads the results it wrote at once", %{
      view: view,
      name: name,
      results: results
    } do
      Session.open_root(name, @init)
      assert has_element?(view, "#card-1 .badge--result", "passed")

      failed =
        TestResults.merge(
          nil,
          %{@init => %{"status" => "failed"}},
          %{run_id: "r2", finished_at: "2026-09-28T12:01:00Z", index: IndexStore.get()}
        )

      staged = results <> ".staged"
      :ok = TestResults.write(failed, staged)
      on_exit(fn -> File.rm(staged) end)

      # The rewrite keeps the mtime the store holds, so no poll could tell it apart: only
      # the run finishing reloads it.
      script = ~S|touch -r "$1" "$2" && mv "$2" "$1"|

      Application.put_env(:grasp, :runs_command, ["sh", "-c", script, "fake-mix", results, staged])

      view |> element("#run-1") |> render_click()
      assert_receive {:run_finished, %{exit_status: 0}}, 2_000

      eventually(view, fn -> has_element?(view, "#card-1 .badge--result", "failed") end)
    end
  end

  defp with_changed_tests do
    path =
      Path.join(System.tmp_dir!(), "grasp-runs-index-#{System.unique_integer([:positive])}.json")

    document =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("functions", fn records ->
        Enum.map(records, fn record ->
          if record["id"] in [@reply, @plain],
            do: Map.put(record, "change", "modified"),
            else: record
        end)
      end)

    File.write!(path, Jason.encode!(document))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp attribute(view, selector, name) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute(name)

    value
  end

  defp elements(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.text/1)
  end

  defp eventually(view, predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("the view never reached the state the test waited for")

      true ->
        Process.sleep(10)
        render(view)
        eventually(view, predicate, attempts - 1)
    end
  end
end
