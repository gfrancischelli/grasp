defmodule Grasp.Runs do
  @moduledoc """
  Runs one command at a time — a test run (`mix grasp.test …`) or a coverage run
  (`mix grasp.cover`) — and broadcasts what it does.

  A run is a port opened on the command's executable, resolved on `PATH` by
  `System.find_executable/1` and given its arguments as argv, so nothing goes near shell
  quoting. It runs in the project root: the `:root` option, the `:grasp, :runs_root` config,
  and Grasp's home (`Grasp.Application.home/0`) otherwise — the directory Grasp started
  in, or the indexed project's root under `mix grasp.viewer`. The command sees the
  environment the viewer VM has — a database name the viewer's environment sets reaches
  the suite — with one exception: `MIX_BUILD_PATH` is removed. The tasks find their
  `ebin` paths in the project's default build, and a suite given an explicit build path
  compiles its test build into it, over whatever build that path holds. `MIX_ENV` is not
  set here: the commands choose it for the suites they start (`MIX_ENV=test`), and set it
  over whatever the viewer's environment holds.

  Output arrives in line mode with stderr merged into stdout; a line longer than the port's
  limit arrives in chunks that are joined until its end, or until they reach sixteen times
  the limit, which is broadcast as a line of its own so output that never ends a line
  cannot grow without bound. Every line is broadcast on the
  `"runs"` topic as `{:run_output, id, seq, line}` as it arrives, `seq` counting the run's
  lines from 1, and a run keeps its last 200 lines. A run starting broadcasts
  `{:run_started, run}` and a run ending, by exiting or by being cancelled,
  `{:run_finished, run}`, both on `"runs"` and on `"runs:status"`, which carries those two
  alone for a subscriber with no use for the lines (`subscribe_status/0`).

  A run is a map of its `id`, `kind` (`:tests` or `:coverage`), `description`, `argv`,
  `root`, `started_at`, `output`, the last lines oldest first, and `line_count`, how many
  lines it has produced so far — the `seq` of the last of them. A holder of a run's
  snapshot has every line numbered up to `line_count`, and a `{:run_output, …}` at or
  below it is one the snapshot already holds. A finished run adds
  `finished_at`, `exit_status` — the command's, `nil` for a cancelled run — and
  `cancelled?`.

  A second start while a run is live is refused with that run, so the caller can say what
  is under way. Closing a port does not stop its program, and the commands run here start
  programs of their own — both tasks run the suite in a VM of its own — so a cancel
  stops the whole process tree the port started (`Grasp.Runs.ProcessTree`) and closes the
  port after. A cancel that lands once the program has exited, while its last output is
  still arriving, signals nothing — the pid may already name another process — and
  finishes the run with the program's status rather than as cancelled. The server traps
  exits, so a server that is stopped or crashes takes its run
  with it rather than leaving a suite running with nobody to read it.
  """

  use GenServer
  require Logger

  alias Grasp.Runs.ProcessTree

  @topic "runs"
  @status_topic "runs:status"
  @kept_lines 200
  @line_limit 65_536
  @buffer_limit 16 * @line_limit

  @type kind :: :tests | :coverage
  @type run :: %{
          id: String.t(),
          kind: kind(),
          description: String.t(),
          argv: [String.t()],
          root: Path.t(),
          started_at: DateTime.t(),
          output: [String.t()],
          line_count: non_neg_integer()
        }
  @type finished_run :: %{
          id: String.t(),
          kind: kind(),
          description: String.t(),
          argv: [String.t()],
          root: Path.t(),
          started_at: DateTime.t(),
          output: [String.t()],
          line_count: non_neg_integer(),
          finished_at: DateTime.t(),
          exit_status: non_neg_integer() | nil,
          cancelled?: boolean()
        }
  @type status :: %{current: :idle | run(), last: finished_run() | nil}

  @doc "Starts the server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts `argv` — its command and the command's arguments — as a run of `kind`.

  Answers `{:ok, run}`, or `{:error, {:running, run}}` with the run under way when there is
  one. A command not found on `PATH` or not executable is `{:error, :no_command}`, and a
  root that is not a directory `{:error, {:no_root, root}}`.

  Options: `:description`, what the run is to a reader, the command line when absent;
  `:root`, the directory it runs in (see the module doc); `:process_table`, the
  `t:Grasp.Runs.ProcessTree.reader/0` a cancel reads the process table with,
  `Grasp.Runs.ProcessTree.read_table/0` by default.
  """
  @spec start(kind(), [String.t(), ...], keyword()) ::
          {:ok, run()}
          | {:error, {:running, run()} | :no_command | {:no_root, Path.t()}}
  def start(kind, [_command | _args] = argv, opts \\ []) when kind in [:tests, :coverage] do
    GenServer.call(__MODULE__, {:start, kind, argv, opts})
  end

  @doc """
  Starts a test run of `test_ids`, as `start/3` does: `mix grasp.test` with each id an
  argument of its own, so an id's quotes and spaces reach the task as they are written.

  The command in front of `grasp.test` is `command/0`'s. The task is given `--index`, the
  index the viewer holds (`Grasp.IndexStore.path/0`), and `--out`, the results document the
  viewer watches (`Grasp.ResultsStore.path/0`), so it resolves the ids the viewer checked
  against the index they were checked in and writes where the badges and `run_status` read,
  whatever the project's own config names. The `:index` and `:out` options name others. The
  ids follow a `--`, which ends the task's switches, so no id is ever read as one whatever
  it starts with. The description names the one test a run of one runs, and counts the
  tests of any other.
  """
  @spec start_tests([String.t(), ...], keyword()) ::
          {:ok, run()}
          | {:error, {:running, run()} | :no_command | {:no_root, Path.t()}}
  def start_tests([_ | _] = test_ids, opts \\ []) do
    description =
      case test_ids do
        [id] -> "mix grasp.test #{id}"
        ids -> "mix grasp.test (#{length(ids)} tests)"
      end

    paths = paths(opts, &Grasp.ResultsStore.path/0)

    start(:tests, command() ++ ["grasp.test" | paths] ++ ["--" | test_ids],
      description: Keyword.get(opts, :description, description),
      root: opts[:root]
    )
  end

  @doc """
  Starts a coverage run, as `start/3` does: `mix grasp.cover`, behind `command/0`'s command,
  given `--index`, the index the viewer holds, and `--out`, the coverage document the viewer
  watches (`Grasp.CoverageStore.path/0`), as `start_tests/2` gives the test task its paths.
  The `:index` and `:out` options name others.
  """
  @spec start_coverage(keyword()) ::
          {:ok, run()}
          | {:error, {:running, run()} | :no_command | {:no_root, Path.t()}}
  def start_coverage(opts \\ []) do
    paths = paths(opts, &Grasp.CoverageStore.path/0)

    start(:coverage, command() ++ ["grasp.cover" | paths],
      description: Keyword.get(opts, :description, "mix grasp.cover"),
      root: opts[:root]
    )
  end

  defp paths(opts, out) do
    index = Keyword.get_lazy(opts, :index, &Grasp.IndexStore.path/0)
    ["--index", index, "--out", Keyword.get_lazy(opts, :out, out)]
  end

  @doc """
  The command and leading arguments `start_tests/2` and `start_coverage/1` put in front of
  the task they run: the `:grasp, :runs_command` config, a non-empty list of strings, and
  `["mix"]` when it is unset. Any other setting raises an `ArgumentError` naming it. A suite configures a stand-in here, so what a run would have
  been given reaches a command that prints it rather than the project's own `mix`.
  """
  @spec command() :: [String.t(), ...]
  def command do
    case Application.get_env(:grasp, :runs_command) do
      nil ->
        ["mix"]

      [_ | _] = command ->
        if Enum.all?(command, &is_binary/1), do: command, else: invalid_command!(command)

      other ->
        invalid_command!(other)
    end
  end

  defp invalid_command!(command) do
    raise ArgumentError,
          "config :grasp, :runs_command must be a non-empty list of strings, " <>
            "such as [\"mix\"]; got: #{inspect(command)}"
  end

  @doc """
  Cancels the run under way: stops its process tree, closes its port and finishes it as
  cancelled. Answers the cancelled run, or `:idle` when none is running.
  """
  @spec cancel() :: {:ok, finished_run()} | :idle
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc """
  The run under way, or `:idle`, and the last run that finished, `nil` before any has.
  """
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Subscribes the caller to the `\"runs\"` topic's messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @doc """
  Subscribes the caller to the `"runs:status"` topic: `{:run_started, run}` and
  `{:run_finished, run}`, without the lines between.
  """
  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @status_topic)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       run: nil,
       port: nil,
       os_pid: nil,
       parent: nil,
       process_table: nil,
       exit_status: nil,
       buffer: "",
       output: [],
       lines: 0,
       seq: 0,
       last: nil
     }}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port, do: halt(state)
    :ok
  end

  @impl true
  def handle_call({:start, _kind, _argv, _opts}, _from, %{run: run} = state) when run != nil,
    do: {:reply, {:error, {:running, view(state)}}, state}

  def handle_call({:start, kind, [command | args] = argv, opts}, _from, state) do
    root = Path.expand(root(opts))

    cond do
      not File.dir?(root) ->
        {:reply, {:error, {:no_root, root}}, state}

      exe = System.find_executable(command) ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, @line_limit},
            {:args, args},
            {:cd, root},
            {:env, [{~c"MIX_BUILD_PATH", false}]}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)

        run = %{
          id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          kind: kind,
          description: Keyword.get(opts, :description) || Enum.join(argv, " "),
          argv: argv,
          root: root,
          started_at: DateTime.utc_now()
        }

        state = %{
          state
          | run: run,
            port: port,
            os_pid: os_pid,
            parent: ProcessTree.parent(os_pid),
            process_table: Keyword.get(opts, :process_table, &ProcessTree.read_table/0),
            exit_status: nil,
            buffer: "",
            output: [],
            lines: 0,
            seq: 0
        }

        view = view(state)
        broadcast_status({:run_started, view})
        {:reply, {:ok, view}, state}

      true ->
        {:reply, {:error, :no_command}, state}
    end
  end

  def handle_call(:cancel, _from, %{run: nil} = state), do: {:reply, :idle, state}

  def handle_call(:cancel, _from, state) do
    code = state.exit_status
    state = halt(state)
    state = finish(state, code, code == nil)
    {:reply, {:ok, state.last}, state}
  end

  def handle_call(:status, _from, state) do
    current = if state.run, do: view(state), else: :idle
    {:reply, %{current: current, last: state.last}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state),
    do: {:noreply, line(%{state | buffer: ""}, state.buffer <> chunk)}

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    buffer = state.buffer <> chunk

    if byte_size(buffer) >= @buffer_limit,
      do: {:noreply, line(%{state | buffer: ""}, buffer)},
      else: {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:noreply, %{state | exit_status: code}}

  # The port closes once its output has reached end of file and its status has arrived, and
  # an unterminated last line is only delivered after the status: the run is over when the
  # port is, not when the status comes.
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    state = if state.buffer == "", do: state, else: line(%{state | buffer: ""}, state.buffer)
    {:noreply, finish(state, state.exit_status, false)}
  end

  # Trapping exits turns a cancelled run's port closing into a message; any other is a
  # supervisor or a linked caller going down, which takes the run with it through
  # `terminate/2`.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # A cancelled run's port can still have output or its exit status in flight.
  def handle_info({port, _payload}, state) when is_port(port), do: {:noreply, state}

  defp root(opts) do
    Keyword.get(opts, :root) || Application.get_env(:grasp, :runs_root) ||
      Grasp.Application.home() || File.cwd!()
  end

  defp line(state, text) do
    seq = state.seq + 1
    broadcast({:run_output, state.run.id, seq, text})
    output = [text | state.output]
    state = %{state | seq: seq}

    if state.lines >= @kept_lines do
      %{state | output: Enum.take(output, @kept_lines)}
    else
      %{state | output: output, lines: state.lines + 1}
    end
  end

  # The tree is killed only while the program has not reported its exit: once it has, its
  # pid can name another process. A kill that raises has continued what it stopped, and
  # the run still ends and reports.
  defp halt(state) do
    if state.exit_status == nil do
      try do
        ProcessTree.kill(state.os_pid, parent: state.parent, table: state.process_table)
      catch
        kind, reason ->
          Logger.warning("grasp: could not stop the run: #{Exception.format(kind, reason)}")
      end
    end

    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    %{state | port: nil, os_pid: nil, parent: nil, process_table: nil, buffer: ""}
  end

  defp finish(state, code, cancelled?) do
    last =
      state
      |> view()
      |> Map.merge(%{finished_at: DateTime.utc_now(), exit_status: code, cancelled?: cancelled?})

    broadcast_status({:run_finished, last})

    %{
      state
      | run: nil,
        port: nil,
        os_pid: nil,
        parent: nil,
        process_table: nil,
        exit_status: nil,
        buffer: "",
        output: [],
        lines: 0,
        seq: 0,
        last: last
    }
  end

  defp view(state),
    do: Map.merge(state.run, %{output: Enum.reverse(state.output), line_count: state.seq})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, message)

  defp broadcast_status(message) do
    broadcast(message)
    Phoenix.PubSub.broadcast(Grasp.PubSub, @status_topic, message)
  end
end
