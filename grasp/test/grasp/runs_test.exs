defmodule Grasp.RunsTest do
  # One run at a time is the point of the server, so the tests share it and run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Grasp.Runs
  alias Grasp.Runs.ProcessTree

  setup do
    root = Path.join(System.tmp_dir!(), "grasp-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Runs.subscribe()

    on_exit(fn ->
      Runs.cancel()
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "a run's lines are broadcast in order and its exit status recorded", %{root: root} do
    assert {:ok, %{id: id, kind: :tests, description: "three lines"} = run} =
             Runs.start(:tests, ["sh", "-c", "echo one; echo two >&2; echo three; exit 3"],
               root: root,
               description: "three lines"
             )

    assert run.output == []
    assert_receive {:run_started, %{id: ^id}}
    assert_receive {:run_output, ^id, _seq, "one"}, 2_000
    assert_receive {:run_output, ^id, _seq, "two"}, 2_000
    assert_receive {:run_output, ^id, _seq, "three"}, 2_000

    assert_receive {:run_finished, %{id: ^id, exit_status: 3, cancelled?: false} = finished},
                   2_000

    assert finished.output == ["one", "two", "three"]
    assert %{current: :idle, last: ^finished} = Runs.status()
  end

  test "the description defaults to the command line", %{root: root} do
    assert {:ok, %{description: "sh -c true"}} =
             Runs.start(:coverage, ["sh", "-c", "true"], root: root)

    assert_receive {:run_finished, %{kind: :coverage, exit_status: 0}}, 2_000
  end

  test "a start while a run is live is refused with the running one", %{root: root} do
    {:ok, %{id: id}} =
      Runs.start(:coverage, ["sh", "-c", "echo started; sleep 30"],
        root: root,
        description: "coverage"
      )

    assert_receive {:run_output, ^id, _seq, "started"}, 2_000

    assert {:error, {:running, %{id: ^id, description: "coverage", output: ["started"]}}} =
             Runs.start(:tests, ["sh", "-c", "true"], root: root)

    assert %{current: %{id: ^id, kind: :coverage}} = Runs.status()
  end

  test "cancel stops the command and every process it started, and says so", %{root: root} do
    {:ok, %{id: id}} =
      Runs.start(
        :tests,
        ["sh", "-c", "echo $$; sh -c 'echo $$; sleep 30 & echo $!; wait' & wait"],
        root: root
      )

    pids = for _ <- 1..3, do: receive_line(id)
    assert Enum.all?(pids, &alive?/1)

    assert {:ok, %{id: ^id, cancelled?: true, exit_status: nil}} = Runs.cancel()
    assert_receive {:run_finished, %{id: ^id, cancelled?: true}}

    for pid <- pids, do: assert_dead(pid)
    assert %{current: :idle, last: %{id: ^id, cancelled?: true}} = Runs.status()
  end

  # A command that runs another through a port puts it in a process group of its own, as
  # `mix grasp.cover` does with `mix test`: a group kill of the run would leave it standing.
  test "cancel reaches a program that left the run's process group", %{root: root} do
    script =
      ~S|IO.puts(System.pid()); System.cmd("sh", ["-c", "echo $$; exec sleep 30"], into: IO.stream())|

    {:ok, %{id: id}} = Runs.start(:tests, ["elixir", "-e", script], root: root)

    vm = receive_line(id, 20_000)
    sleeper = receive_line(id, 20_000)
    refute pgid(vm) == pgid(sleeper)

    assert {:ok, %{cancelled?: true}} = Runs.cancel()

    assert_dead(vm)
    assert_dead(sleeper)
  end

  test "a server that stops takes its run with it", %{root: root} do
    {:ok, %{id: id}} =
      Runs.start(:tests, ["sh", "-c", "echo $$; sleep 30 & echo $!; wait"], root: root)

    pids = for _ <- 1..2, do: receive_line(id)
    server = Process.whereis(Runs)

    :ok = GenServer.stop(Runs)

    for pid <- pids, do: assert_dead(pid)
    assert_restarted(server)
    assert %{current: :idle, last: nil} = Runs.status()
  end

  for failure <- [:error, :raise] do
    test "a table that cannot be read mid-walk continues every process it stopped (#{failure})",
         %{root: root} do
      second_reading = second_reading(unquote(failure))
      calls = :counters.new(1, [])

      table = fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: ProcessTree.read_table(), else: second_reading.()
      end

      {:ok, %{id: id}} =
        Runs.start(
          :tests,
          ["sh", "-c", ~S|trap "" TERM; echo $$; while :; do sleep 0.2; done|],
          root: root,
          process_table: table
        )

      shell = receive_line(id)
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(shell)]) end)
      Process.sleep(100)

      capture_log(fn ->
        assert {:ok, %{id: ^id, cancelled?: true}} = Runs.cancel()
      end)

      assert_receive {:run_finished, %{id: ^id, cancelled?: true}}
      assert :counters.get(calls, 1) == 2

      # The shell ignores SIGTERM, so it outlives the cancel; stopped, it would sit in `T`
      # and fork no further sleep.
      Process.sleep(500)
      {:ok, table} = ProcessTree.read_table()
      tree = ProcessTree.tree(shell, nil, table)
      assert MapSet.size(tree) >= 1
      for pid <- tree, do: refute(stat(pid) =~ "T")
    end
  end

  test "a cancel once the program has exited signals nothing and keeps its status", %{
    root: root
  } do
    {:ok, %{id: id}} = Runs.start(:tests, ["sh", "-c", "echo $$; exec sleep 30"], root: root)
    sleeper = receive_line(id)
    on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(sleeper)]) end)

    send(Runs, {:sys.get_state(Runs).port, {:exit_status, 7}})

    assert {:ok, %{id: ^id, exit_status: 7, cancelled?: false}} = Runs.cancel()
    Process.sleep(100)
    assert alive?(sleeper)
    refute stat(sleeper) =~ "T"
  end

  test "the viewer's build path does not reach the command", %{root: root} do
    previous = System.get_env("MIX_BUILD_PATH")
    System.put_env("MIX_BUILD_PATH", Path.join(root, "_build"))

    on_exit(fn ->
      if previous,
        do: System.put_env("MIX_BUILD_PATH", previous),
        else: System.delete_env("MIX_BUILD_PATH")
    end)

    {:ok, %{id: id}} =
      Runs.start(:tests, ["sh", "-c", ~S|echo "[${MIX_BUILD_PATH-unset}]"|], root: root)

    assert_receive {:run_output, ^id, _seq, "[unset]"}, 2_000
  end

  test "output that never ends a line is broadcast in bounded pieces", %{root: root} do
    {:ok, %{id: id}} =
      Runs.start(:tests, ["sh", "-c", "head -c 1048586 /dev/zero | tr '\\0' a; echo"], root: root)

    assert_receive {:run_output, ^id, _seq, first}, 5_000
    assert byte_size(first) == 1_048_576
    assert_receive {:run_output, ^id, _seq, rest}, 5_000
    assert rest == String.duplicate("a", 10)
  end

  test "cancel with nothing running answers idle" do
    assert Runs.cancel() == :idle
  end

  test "the command sees the environment the viewer has, in the root it is given", %{
    root: root
  } do
    System.put_env("GRASP_RUNS_PROBE", "from the viewer")
    on_exit(fn -> System.delete_env("GRASP_RUNS_PROBE") end)

    {:ok, %{id: id}} =
      Runs.start(:tests, ["sh", "-c", ~S|echo "$GRASP_RUNS_PROBE"; pwd -P|], root: root)

    assert_receive {:run_output, ^id, _seq, "from the viewer"}, 2_000
    assert_receive {:run_output, ^id, _seq, cwd}, 2_000
    assert Path.basename(cwd) == Path.basename(root)
    assert_receive {:run_finished, %{id: ^id, exit_status: 0}}, 2_000
  end

  test "a run keeps its last 200 lines", %{root: root} do
    {:ok, %{id: id}} = Runs.start(:tests, ["sh", "-c", "seq 1 250"], root: root)

    assert_receive {:run_finished, %{id: ^id, output: output}}, 5_000
    assert length(output) == 200
    assert List.first(output) == "51"
    assert List.last(output) == "250"
  end

  test "a line longer than the port's limit arrives whole", %{root: root} do
    {:ok, %{id: id}} =
      Runs.start(:tests, ["sh", "-c", "printf '%070000d\\n' 0; printf 'tail'"], root: root)

    assert_receive {:run_output, ^id, _seq, long}, 2_000
    assert byte_size(long) == 70_000
    assert_receive {:run_output, ^id, _seq, "tail"}, 2_000
    assert_receive {:run_finished, %{id: ^id, exit_status: 0}}, 2_000
  end

  test "a command that is not there, or a root that is not a directory, starts nothing", %{
    root: root
  } do
    assert Runs.start(:tests, ["grasp-no-such-command"], root: root) == {:error, :no_command}

    missing = Path.join(root, "missing")

    assert Runs.start(:tests, ["sh", "-c", "true"], root: missing) ==
             {:error, {:no_root, missing}}

    assert %{current: :idle} = Runs.status()
  end

  test "the root defaults to the configured one" do
    previous = Application.get_env(:grasp, :runs_root)
    root = Path.join(System.tmp_dir!(), "grasp-runs-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:grasp, :runs_root, root)

    on_exit(fn ->
      Application.put_env(:grasp, :runs_root, previous)
      File.rm_rf(root)
    end)

    assert {:ok, %{id: id, root: ^root}} = Runs.start(:tests, ["sh", "-c", "true"])
    assert_receive {:run_finished, %{id: ^id}}, 2_000
  end

  test "each line carries its number, and a run's view counts the lines it has produced", %{
    root: root
  } do
    {:ok, %{id: id, line_count: 0}} =
      Runs.start(:tests, ["sh", "-c", "echo a; echo b; echo c; sleep 30"], root: root)

    assert_receive {:run_output, ^id, 1, "a"}, 2_000
    assert_receive {:run_output, ^id, 2, "b"}, 2_000
    assert_receive {:run_output, ^id, 3, "c"}, 2_000
    assert %{current: %{id: ^id, line_count: 3, output: ["a", "b", "c"]}} = Runs.status()

    assert {:ok, %{line_count: 3}} = Runs.cancel()
  end

  test "the count goes on past the lines a run keeps", %{root: root} do
    {:ok, %{id: id}} = Runs.start(:tests, ["sh", "-c", "seq 1 250"], root: root)

    assert_receive {:run_finished, %{id: ^id, line_count: 250, output: output}}, 5_000
    assert output == Enum.map(51..250, &Integer.to_string/1)
  end

  test "the status topic carries a run's start and finish and none of its lines", %{
    root: root
  } do
    :ok = Runs.subscribe_status()
    {:ok, %{id: id}} = Runs.start(:tests, ["sh", "-c", "echo one"], root: root)

    # The "runs" subscription of the setup receives the line; the status one does not.
    assert_receive {:run_output, ^id, 1, "one"}, 2_000
    assert_receive {:run_finished, %{id: ^id}}, 2_000
    assert_receive {:run_finished, %{id: ^id}}, 2_000
    assert_received {:run_started, %{id: ^id}}
    assert_received {:run_started, %{id: ^id}}
    refute_received {:run_output, ^id, _seq, _line}
  end

  describe "the configured command" do
    setup do
      previous = Application.get_env(:grasp, :runs_command)
      on_exit(fn -> Application.put_env(:grasp, :runs_command, previous) end)
    end

    test "a test run passes the ids after --, one argument each", %{root: root} do
      Application.put_env(:grasp, :runs_command, ["sh", "-c", ~S|printf '%s\n' "$@"|, "fake"])
      ids = [~S|SampleApp.TallyTest."test init keeps the start count"/1|, "-x"]

      {:ok, %{id: id, argv: argv}} = Runs.start_tests(ids, root: root)
      assert argv == ["sh", "-c", ~S|printf '%s\n' "$@"|, "fake", "grasp.test", "--" | ids]

      assert_receive {:run_finished, %{id: ^id, output: output}}, 2_000
      assert output == ["grasp.test", "--" | ids]
    end

    test "unset is mix" do
      Application.delete_env(:grasp, :runs_command)
      assert Runs.command() == ["mix"]
    end

    test "anything but a non-empty list of strings is refused, naming the setting" do
      for bad <- ["mix", [], [:mix], ["mix", 1]] do
        Application.put_env(:grasp, :runs_command, bad)

        assert_raise ArgumentError, ~r/:runs_command must be a non-empty list of strings/, fn ->
          Runs.start_coverage()
        end
      end
    end
  end

  defp receive_line(id, timeout \\ 2_000) do
    assert_receive {:run_output, ^id, _seq, line}, timeout
    String.to_integer(String.trim(line))
  end

  defp alive?(pid) do
    {_out, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  # A process killed after its parent is handed to init and reaped by it, which can take a
  # moment: until then `kill -0` still finds it.
  defp assert_dead(pid, tries \\ 50) do
    cond do
      not alive?(pid) -> :ok
      tries == 0 -> flunk("process #{pid} is still running")
      true -> Process.sleep(100) && assert_dead(pid, tries - 1)
    end
  end

  defp assert_restarted(previous, tries \\ 50) do
    case Process.whereis(Runs) do
      pid when is_pid(pid) and pid != previous -> :ok
      _gone when tries == 0 -> flunk("the runs server did not restart")
      _gone -> Process.sleep(20) && assert_restarted(previous, tries - 1)
    end
  end

  defp second_reading(:error), do: fn -> {:error, :unreadable} end
  defp second_reading(:raise), do: fn -> raise "the table is gone" end

  defp stat(pid) do
    {out, _status} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)])
    String.trim(out)
  end

  defp pgid(pid) do
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)])
    String.trim(out)
  end
end
