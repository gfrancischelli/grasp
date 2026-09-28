defmodule Grasp.RunsTest do
  # One run at a time is the point of the server, so the tests share it and run alone.
  use ExUnit.Case, async: false

  alias Grasp.Runs

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
    assert_receive {:run_output, ^id, "one"}, 2_000
    assert_receive {:run_output, ^id, "two"}, 2_000
    assert_receive {:run_output, ^id, "three"}, 2_000

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

    assert_receive {:run_output, ^id, "started"}, 2_000

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

    assert_receive {:run_output, ^id, "from the viewer"}, 2_000
    assert_receive {:run_output, ^id, cwd}, 2_000
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

    assert_receive {:run_output, ^id, long}, 2_000
    assert byte_size(long) == 70_000
    assert_receive {:run_output, ^id, "tail"}, 2_000
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

  defp receive_line(id, timeout \\ 2_000) do
    assert_receive {:run_output, ^id, line}, timeout
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

  defp pgid(pid) do
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)])
    String.trim(out)
  end
end
