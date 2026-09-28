defmodule Grasp.Runs.ProcessTree do
  @moduledoc """
  Stops an OS process and every process descended from it.

  Signalling a process group is not enough for the commands `Grasp.Runs` starts. The BEAM
  starts every port program as the leader of a group of its own, so a `mix` task that runs
  `mix test` through `System.cmd/3` puts the test VM in a group apart from the task's — a
  kill of the task's group leaves the suite running. The tree is read from the parent pids
  `ps` lists instead, which follows a child whatever group or session it moved to.

  A process can fork between the listing and the signal, so the tree is frozen first: every
  process found is sent `SIGSTOP`, the table is read again, and the processes that appeared
  are stopped in turn, until a reading finds none it has not stopped. A stopped process
  cannot fork, so that reading is the whole tree. Each is then sent `SIGTERM` and `SIGCONT`,
  and handles the termination the moment it runs again. A BEAM stops on `SIGTERM` as on
  `init:stop/0`; a process that ignores it is past what this does.

  The tree is read before anything is killed: a process whose parent dies is handed to
  init, and a later reading could not tell it belongs to the tree.
  """

  @doc """
  Sends `SIGTERM` to `pid` and to every process descended from it, freezing the tree first
  so none escapes by forking. Answers the pids signalled; a `pid` that has already exited
  signals whatever of its tree still stands.
  """
  @spec kill(pos_integer()) :: [pos_integer()]
  def kill(pid) when is_integer(pid) and pid > 0 do
    pids = freeze(pid, MapSet.new()) |> MapSet.to_list() |> Enum.sort()
    signal("TERM", pids)
    signal("CONT", pids)
    pids
  end

  @doc "The pids of `pid` and of every process descended from it, as `ps` lists them."
  @spec tree(pos_integer()) :: MapSet.t(pos_integer())
  def tree(pid) when is_integer(pid) and pid > 0 do
    children = children_table()
    descend([pid], children, MapSet.new([pid]))
  end

  defp freeze(root, stopped) do
    fresh = root |> tree() |> MapSet.difference(stopped)

    if MapSet.size(fresh) == 0 do
      stopped
    else
      signal("STOP", MapSet.to_list(fresh))
      freeze(root, MapSet.union(stopped, fresh))
    end
  end

  defp descend([], _children, found), do: found

  defp descend([pid | rest], children, found) do
    fresh = children |> Map.get(pid, []) |> Enum.reject(&MapSet.member?(found, &1))
    descend(fresh ++ rest, children, Enum.into(fresh, found))
  end

  defp children_table do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid="])

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row) do
        [pid, ppid] -> [{String.to_integer(ppid), String.to_integer(pid)}]
        _other -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
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
