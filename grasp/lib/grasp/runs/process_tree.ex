defmodule Grasp.Runs.ProcessTree do
  @moduledoc """
  Stops an OS process and every process descended from it.

  Signalling a process group is not enough for the commands `Grasp.Runs` starts. The BEAM
  starts every port program as the leader of a group of its own, so a `mix` task that runs
  `mix test` through `System.cmd/3` puts the test VM in a group apart from the task's — a
  kill of the task's group leaves the suite running. The tree is read from the parent pids
  `ps -A -o pid= -o ppid=` lists instead, which follows a child whatever group or session it
  moved to. A `ps` without those options (BusyBox's) cannot be read, and a kill then signals
  nothing.

  A process can fork between the listing and the signal, so the tree is frozen first: every
  process found is sent `SIGSTOP`, the table is read again, and the processes that appeared
  are stopped in turn, until a reading finds none it has not stopped. A stopped process
  cannot fork, and cannot exit on its own, so that last reading is the whole tree and every
  process in it is still the one found. Those are sent `SIGTERM`; every process
  stopped is then sent `SIGCONT` and handles the termination the moment it runs again. A
  BEAM stops on `SIGTERM` as on `init:stop/0`; a process that ignores it is past what this
  does.

  A stopped process stays stopped until something continues it, so the `SIGCONT` is sent
  whatever happens during the walk: a table that cannot be read ends the walk, and the
  processes found by then are terminated; anything raised on the way still continues every
  process stopped before it propagates.

  Only a process the reading lists is signalled. The root counts only while the table lists
  it under the parent that started it, so a pid that exited — and may since name another
  process — is left alone, and so is the tree below it: its children have been handed to
  init, and nothing in the table ties them to the run any more.
  """

  @typedoc "The process table as `{pid, parent pid}` rows."
  @type table :: [{pos_integer(), non_neg_integer()}]

  @typedoc "Reads the process table."
  @type reader :: (-> {:ok, table()} | {:error, term()})

  @doc """
  Sends `SIGTERM` to `pid` and to every process descended from it, freezing the tree first
  so none escapes by forking, and answers the pids terminated.

  Options: `:parent`, the pid that started `pid` — the root is signalled only while the
  table lists it under that parent; `:table`, the `t:reader/0` the walk reads the table
  with, `read_table/0` by default. A `pid` the table does not list signals nothing and
  answers `[]`.
  """
  @spec kill(pos_integer(), keyword()) :: [pos_integer()]
  def kill(pid, opts \\ []) when is_integer(pid) and pid > 0 do
    parent = Keyword.get(opts, :parent)
    reader = Keyword.get(opts, :table, &read_table/0)
    stopped = make_ref()
    Process.put(stopped, MapSet.new())

    try do
      targets =
        case freeze(pid, parent, reader, stopped) do
          {:ok, tree} -> tree
          :unreadable -> Process.get(stopped)
        end

      targets = targets |> MapSet.to_list() |> Enum.sort()
      signal("TERM", targets)
      targets
    after
      signal("CONT", stopped |> Process.get() |> MapSet.to_list())
      Process.delete(stopped)
    end
  end

  @doc """
  The pids of `pid` and of every process descended from it in `table`, empty when `table`
  does not list `pid`, or lists it under a parent other than `parent` when one is given.
  """
  @spec tree(pos_integer(), pos_integer() | nil, table()) :: MapSet.t(pos_integer())
  def tree(pid, parent, table) when is_integer(pid) and is_list(table) do
    case List.keyfind(table, pid, 0) do
      {^pid, ppid} when parent == nil or ppid == parent ->
        children = Enum.group_by(table, &elem(&1, 1), &elem(&1, 0))
        descend([pid], children, MapSet.new([pid]))

      _absent ->
        MapSet.new()
    end
  end

  @doc "The parent of `pid` as `read_table/0` lists it, `nil` when it is not listed."
  @spec parent(pos_integer()) :: non_neg_integer() | nil
  def parent(pid) when is_integer(pid) do
    with {:ok, table} <- read_table(),
         {^pid, ppid} <- List.keyfind(table, pid, 0) do
      ppid
    else
      _unlisted -> nil
    end
  end

  @doc "Reads the process table from `ps`, or answers why it could not."
  @spec read_table() :: {:ok, table()} | {:error, term()}
  def read_table do
    case System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {out, status} -> {:error, {:ps, status, out}}
    end
  rescue
    error -> {:error, error}
  end

  defp parse(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      with [pid, ppid] <- String.split(row),
           {pid, ""} <- Integer.parse(pid),
           {ppid, ""} <- Integer.parse(ppid) do
        [{pid, ppid}]
      else
        _other -> []
      end
    end)
  end

  defp freeze(root, parent, reader, stopped) do
    case reader.() do
      {:ok, table} ->
        tree = tree(root, parent, table)
        fresh = MapSet.difference(tree, Process.get(stopped))

        if MapSet.size(fresh) == 0 do
          {:ok, tree}
        else
          Process.put(stopped, MapSet.union(Process.get(stopped), fresh))
          signal("STOP", MapSet.to_list(fresh))
          freeze(root, parent, reader, stopped)
        end

      {:error, _reason} ->
        :unreadable
    end
  end

  defp descend([], _children, found), do: found

  defp descend([pid | rest], children, found) do
    fresh = children |> Map.get(pid, []) |> Enum.reject(&MapSet.member?(found, &1))
    descend(fresh ++ rest, children, Enum.into(fresh, found))
  end

  # A pid that exited since the reading makes `kill` fail for it alone; the rest are still
  # signalled, so its status says nothing worth acting on.
  defp signal(_signal, []), do: :ok

  defp signal(signal, pids) do
    System.cmd("kill", ["-" <> signal | Enum.map(pids, &Integer.to_string/1)],
      stderr_to_stdout: true
    )

    :ok
  end
end
