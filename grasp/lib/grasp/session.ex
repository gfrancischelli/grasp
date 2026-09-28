defmodule Grasp.Session do
  @moduledoc """
  One review session: a named GenServer owning a `Grasp.Session.Forest`.

  The browser and the MCP server both mutate a session through this API, so state lives
  here rather than in a LiveView. Every mutation broadcasts `{:session, name, forest}` on
  the `"session:<name>"` topic; subscribers re-render from the forest they receive.
  Sessions are started on demand under `Grasp.SessionSupervisor` and found through
  `Grasp.SessionRegistry`.

  ## Persistence

  A session outlives the process that draws it: `Grasp.Session.Disk` holds its file, `init/1`
  reads it back, and every mutation schedules a write. The writes are coalesced — one timer
  at a time, and a mutation arriving while it runs does not push it further out — so a drag
  that moves a card sixty times a second lands on disk about every 150 ms rather than sixty
  times, and the last of them is written when the session stops. A file that cannot be
  decoded is moved aside by the disk module and the session starts empty rather than
  failing to start.

  Cards are pruned against the index when the session loads, so a card whose function left
  the index between one run and the next never reaches the canvas. A reload of the index
  while the session runs does not prune it: the card stays, showing what the reader was
  looking at, until the next restart reads the file back.

  A session writes only when it knows what its file holds. One whose file could not be read,
  or could not be moved aside after failing to decode, runs in memory for the rest of its
  life: the arrangement on disk is the reviewer's only copy, and overwriting it with an
  empty canvas would be the one loss the restart was meant to prevent. A session that
  started when there was no directory at all — no index loaded yet, or a project root that
  is not on this machine — is in the same position: it read nothing, and a directory
  appearing afterwards would hold a file it has never seen. It keeps the directory it
  resolved at startup, so a later one is never written to either; opening the session again
  once the index is there reads the file and writes from then on.

  The process links to nothing and subscribes to nothing: the only message it handles is its
  own `:flush` timer, and it traps exits solely so its supervisor's shutdown reaches
  `terminate/2`. Anything that links to a session from here on has to add a clause for
  `{:EXIT, _pid, _reason}`, which would otherwise crash it.
  """

  use GenServer

  require Logger

  alias Grasp.Session.Disk
  alias Grasp.Session.Forest

  @flush_ms 150
  # How long `delete/1` waits for the registry to let a stopped session's name go.
  @unregister_ms 100

  @type name :: String.t()

  @doc """
  How long a burst of mutations is gathered for before it is written, in milliseconds.

  The debounce window, read out rather than kept private, so anything reasoning about how
  often a session reaches disk reads the one value instead of a copy of it.
  """
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @doc """
  Starts the session named `name` if it is not running.

  A session that has just stopped holds its name until the registry handles the monitor
  message behind it, so a start in that window is refused in favour of a process that is
  already gone. The name is waited out and the session started again, which is why an
  `ensure/1` right after a `stop` answers with a session the caller can call.
  """
  @spec ensure(name()) :: :ok
  def ensure(name) do
    case DynamicSupervisor.start_child(Grasp.SessionSupervisor, {__MODULE__, name}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> ensure_alive(name, pid)
    end
  end

  @doc false
  def child_spec(name),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc "Subscribes the caller to `{:session, name, forest}` broadcasts."
  @spec subscribe(name()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(Grasp.PubSub, topic(name))

  @doc "The current forest."
  @spec get(name()) :: Forest.t()
  def get(name), do: GenServer.call(via(name), :get)

  @doc "Opens `function_id` with no caller, or focuses the card already showing it."
  @spec open_root(name(), String.t()) :: Forest.t()
  def open_root(name, function_id), do: mutate(name, &Forest.open_root(&1, function_id))

  @doc """
  Opens (or focuses) `function_id` as a callee of `card_id`; `opened_by` records the call
  target that was clicked when it differs from the function's canonical id.
  """
  @spec open_child(name(), Forest.id(), String.t(), String.t() | nil) :: Forest.t()
  def open_child(name, card_id, function_id, opened_by \\ nil),
    do: mutate(name, &Forest.open_child(&1, card_id, function_id, opened_by))

  @doc """
  Opens (or focuses) `caller_id` as a caller of `card_id`; `target` records the call target
  the caller writes when it differs from the card's canonical id.
  """
  @spec open_caller(name(), Forest.id(), String.t(), String.t() | nil) :: Forest.t()
  def open_caller(name, card_id, caller_id, target \\ nil),
    do: mutate(name, &Forest.open_caller(&1, card_id, caller_id, target))

  @doc """
  Opens (or focuses) each of `callers` as a caller of the card before it, starting from
  `card_id`; each pairs a caller's id with the call target it writes, or nil.
  """
  @spec open_callers(name(), Forest.id(), [{String.t(), String.t() | nil}]) :: Forest.t()
  def open_callers(name, card_id, callers),
    do: mutate(name, &Forest.open_callers(&1, card_id, callers))

  @doc """
  Opens (or focuses) each of `callees` as a callee of the card before it, starting from
  `card_id`, in one change; each names its function, the call target that opened it or nil,
  and the highlight it wears. The last one is focused.
  """
  @spec open_callees(name(), Forest.id(), [{String.t(), String.t() | nil, Forest.highlight()}]) ::
          Forest.t()
  def open_callees(name, card_id, callees),
    do: mutate(name, &Forest.open_callees(&1, card_id, callees))

  @doc "Closes `card_id` alone, leaving the cards it called behind."
  @spec close(name(), Forest.id()) :: Forest.t()
  def close(name, card_id), do: mutate(name, &Forest.close(&1, card_id))

  @doc "Closes `card_id` and every card that had no other way to be reached."
  @spec close_chain(name(), Forest.id()) :: Forest.t()
  def close_chain(name, card_id), do: mutate(name, &Forest.close_chain(&1, card_id))

  @doc "Focuses `card_id`."
  @spec focus(name(), Forest.id()) :: Forest.t()
  def focus(name, card_id), do: mutate(name, &Forest.focus(&1, card_id))

  @doc "Collapses or expands `card_id`, hiding or showing what only it reaches."
  @spec toggle_collapse(name(), Forest.id()) :: Forest.t()
  def toggle_collapse(name, card_id), do: mutate(name, &Forest.toggle_collapse(&1, card_id))

  @doc "Shows `card_id` as its source or as its diff against the base."
  @spec set_view(name(), Forest.id(), Forest.view()) :: Forest.t()
  def set_view(name, card_id, view), do: mutate(name, &Forest.set_view(&1, card_id, view))

  @doc "Swaps `card_id` between its source and its diff."
  @spec toggle_view(name(), Forest.id()) :: Forest.t()
  def toggle_view(name, card_id), do: mutate(name, &Forest.toggle_view(&1, card_id))

  @doc "Shows `card_id`'s diff as the changed hunks alone or as every line."
  @spec set_context(name(), Forest.id(), Forest.context()) :: Forest.t()
  def set_context(name, card_id, context),
    do: mutate(name, &Forest.set_context(&1, card_id, context))

  @doc "Swaps `card_id` between the changes alone and every line; `loc` is the function's length."
  @spec toggle_context(name(), Forest.id(), non_neg_integer()) :: Forest.t()
  def toggle_context(name, card_id, loc),
    do: mutate(name, &Forest.toggle_context(&1, card_id, loc))

  @doc "Puts `card_id`'s top-left corner at `{x, y}` on the stage."
  @spec move(name(), Forest.id(), {integer(), integer()}) :: Forest.t()
  def move(name, card_id, {x, y}), do: mutate(name, &Forest.move(&1, card_id, {x, y}))

  @doc """
  Places each `{card_id, x, y}` whose card has no position yet, leaving a placed card where
  it is, so a placement computed before a drag cannot undo it. An entry whose coordinates
  are not both integers is skipped.
  """
  @spec place(name(), [{Forest.id(), term(), term()}]) :: Forest.t()
  def place(name, placements) when is_list(placements),
    do: mutate(name, &Forest.place(&1, placements))

  @doc """
  Adds `{dx, dy}` to the position of every placed card in `group_id`, moving the group as
  one. An unknown group changes nothing.
  """
  @spec shift_group(name(), Forest.group_id(), {integer(), integer()}) :: Forest.t()
  def shift_group(name, group_id, {dx, dy}) when is_integer(dx) and is_integer(dy),
    do: mutate(name, &Forest.shift_group(&1, group_id, {dx, dy}))

  @doc """
  Adds `{dx, dy}` to the position of every placed card in `card_ids`, moving them as one.
  Groups are untouched, and an id the session does not hold changes nothing.
  """
  @spec shift_cards(name(), [Forest.id()], {integer(), integer()}) :: Forest.t()
  def shift_cards(name, card_ids, {dx, dy})
      when is_list(card_ids) and is_integer(dx) and is_integer(dy),
      do: mutate(name, &Forest.shift_cards(&1, card_ids, {dx, dy}))

  @doc "Empties every card's position, so the whole canvas is laid out again."
  @spec reset_layout(name()) :: Forest.t()
  def reset_layout(name), do: mutate(name, &Forest.reset_layout/1)

  @doc """
  Puts `card_ids` into a group of their own, titled `title` or untitled when that is nil or
  blank. The group is always a new one, so two may share a title; each card leaves whatever
  group it was in, and a group left with no members is gone.
  """
  @spec new_group(name(), String.t() | nil, [Forest.id()]) :: Forest.t()
  def new_group(name, title, card_ids),
    do: mutate(name, &Forest.new_group(&1, title, card_ids))

  @doc """
  Puts `card_ids` into the group titled `title`, creating it when nothing carries that title
  yet. Each card leaves whatever group it was in, and a group left with no members is gone.
  """
  @spec group_cards(name(), String.t(), [Forest.id()]) :: Forest.t()
  def group_cards(name, title, card_ids),
    do: mutate(name, &Forest.group_cards(&1, title, card_ids))

  @doc "Takes `card_ids` out of their groups, deleting a group left with no members."
  @spec ungroup_cards(name(), [Forest.id()]) :: Forest.t()
  def ungroup_cards(name, card_ids), do: mutate(name, &Forest.ungroup_cards(&1, card_ids))

  @doc """
  Retitles `group_id`, keeping its cards. A blank or nil title leaves the group untitled;
  an unknown group changes nothing.
  """
  @spec rename_group(name(), Forest.group_id(), String.t() | nil) :: Forest.t()
  def rename_group(name, group_id, title),
    do: mutate(name, &Forest.rename_group(&1, group_id, title))

  @doc """
  Puts `card_ids` into the existing group `group_id`, out of whatever group they were in. An
  unknown group changes nothing, and a group left with no members is deleted.
  """
  @spec add_to_group(name(), Forest.group_id(), [Forest.id()]) :: Forest.t()
  def add_to_group(name, group_id, card_ids),
    do: mutate(name, &Forest.add_to_group(&1, group_id, card_ids))

  @doc "Deletes `group_id`, leaving its cards in the graph with no group."
  @spec dissolve_group(name(), Forest.group_id()) :: Forest.t()
  def dissolve_group(name, group_id), do: mutate(name, &Forest.dissolve_group(&1, group_id))

  @doc "Moves focus in `direction`."
  @spec move_focus(name(), Forest.direction()) :: Forest.t()
  def move_focus(name, direction), do: mutate(name, &Forest.move_focus(&1, direction))

  @doc """
  Replaces the whole graph with the cards `specs` describes. The session keeps its current
  forest, and nothing is broadcast, when the spec does not build.
  """
  @spec set_cards(name(), [Forest.spec()]) :: {:ok, Forest.t()} | {:error, term()}
  def set_cards(name, specs), do: GenServer.call(via(name), {:replace, specs})

  @doc "Sets what `card_id` points at: a call, a line range, or nothing."
  @spec set_highlight(name(), Forest.id(), Forest.highlight()) :: Forest.t()
  def set_highlight(name, card_id, highlight),
    do: mutate(name, &Forest.set_highlight(&1, card_id, highlight))

  @doc """
  Deletes the session `name`: its cards are forgotten and its file is removed.

  The order is broadcast, then stop, then remove the file: `{:session_deleted, name}` goes
  out on the session's topic while the process is still there to answer a tab that has not
  finished leaving. The broadcast is asynchronous, so a subscriber may well read it after
  the session has gone; it says what happened, not when.
  The conversation the agent held under that name goes with the cards: a session opened
  under the name afterwards is a new one, and rejoining the transcript of the session it
  replaced would put words in its mouth.
  The review threads written in the session go with it for the same reason
  (`Grasp.Comments.delete_session/1`): they were remarks in that review's conversation.
  The default session may be deleted like any other — deleting it clears the canvas rather
  than taking it away, since the next visit to `/` starts it again, empty.

  It returns once the name is free: `list/0` reads the registry, which releases a name a
  moment after the process holding it goes down, so a caller redrawing the list from the
  return of this would otherwise be told the session it just deleted is still running.
  """
  @spec delete(name()) :: :ok
  def delete(name) do
    Phoenix.PubSub.broadcast(Grasp.PubSub, topic(name), {:session_deleted, name})
    stop(name)
    Grasp.Agent.forget(name)
    :ok = Grasp.Comments.delete_session(name)
    Disk.delete(name)
  end

  @doc """
  Names of the sessions the viewer knows, running and saved alike, sorted.

  A saved session is one with a file and no process, which is every session after a
  restart, so a name here is a name `ensure/1` brings back with its cards.
  """
  @spec list() :: [String.t()]
  def list do
    running = Registry.select(Grasp.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    (running ++ Disk.saved()) |> Enum.uniq() |> Enum.sort()
  end

  @impl true
  def init(name) do
    # Without this a supervisor's shutdown kills the process outright and `terminate/2`
    # never runs, losing whatever mutation the debounce timer was still holding.
    Process.flag(:trap_exit, true)

    # Resolved once and held: a session that read nothing must not write to a directory that
    # turned up under it afterwards.
    dir = Disk.dir()

    {forest, understood} =
      case Disk.read(name, Grasp.IndexStore.get(), dir) do
        {:ok, forest} ->
          {forest, true}

        :empty ->
          {Forest.new(), true}

        {:error, {:corrupt, kept}} ->
          Logger.warning("grasp: the session #{name} did not decode; kept it as #{kept}")
          {Forest.new(), true}

        {:error, reason} ->
          Logger.warning(
            "grasp: the session #{name} will not be written to disk: #{inspect(reason)}"
          )

          {Forest.new(), false}
      end

    state = %{
      name: name,
      forest: forest,
      dirty: false,
      timer: nil,
      dir: dir,
      writable: understood and not is_nil(dir)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.forest, state}

  def handle_call({:mutate, fun}, _from, state) do
    forest =
      case fun.(state.forest) do
        {%Forest{} = forest, _id} -> forest
        %Forest{} = forest -> forest
      end

    broadcast(state.name, forest)
    {:reply, forest, store(state, forest)}
  end

  def handle_call({:replace, specs}, _from, state) do
    case Forest.replace(specs) do
      {:ok, forest} ->
        broadcast(state.name, forest)
        {:reply, {:ok, forest}, store(state, forest)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, %{flush(state) | timer: nil}}

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  # A call that left the graph as it was — an unknown card id, a focus that is already
  # there — is not a new arrangement to save.
  defp store(%{forest: forest} = state, forest), do: state

  defp store(state, forest), do: schedule_write(%{state | forest: forest})

  defp schedule_write(%{writable: false} = state), do: state

  # One timer per burst: a mutation arriving while one is pending rides on it rather than
  # pushing it further out, so a stream of moves is written at a steady rate instead of
  # waiting for the reviewer to stop moving.
  defp schedule_write(%{timer: nil} = state),
    do: %{state | dirty: true, timer: Process.send_after(self(), :flush, @flush_ms)}

  defp schedule_write(state), do: %{state | dirty: true}

  defp flush(%{dirty: false} = state), do: state

  defp flush(state) do
    case Disk.write(state.name, state.forest, state.dir) do
      :ok ->
        %{state | dirty: false}

      # The graph stays owed to the file, so the next flush — the next burst's, or the one
      # `terminate/2` makes on the way out — tries again instead of the failure standing.
      {:error, reason} ->
        Logger.warning("grasp: could not write the session #{state.name}: #{inspect(reason)}")
        state
    end
  end

  defp ensure_alive(name, pid) do
    if Process.alive?(pid) do
      :ok
    else
      await_unregistered(name, 0)
      start(name)
    end
  end

  defp start(name) do
    case DynamicSupervisor.start_child(Grasp.SessionSupervisor, {__MODULE__, name}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stop(name) do
    GenServer.stop(via(name))
    await_unregistered(name, 0)
  catch
    :exit, _not_running -> :ok
  end

  # The registry unregisters a name from the monitor it holds, which is a message it has yet
  # to handle when `GenServer.stop/1` returns. The wait is bounded: a registry that somehow
  # never lets go is not worth blocking a delete over, and the file is removed either way.
  defp await_unregistered(_name, waited) when waited >= @unregister_ms, do: :ok

  defp await_unregistered(name, waited) do
    case Registry.lookup(Grasp.SessionRegistry, name) do
      [] ->
        :ok

      _still_registered ->
        Process.sleep(1)
        await_unregistered(name, waited + 1)
    end
  end

  defp broadcast(name, forest),
    do: Phoenix.PubSub.broadcast(Grasp.PubSub, topic(name), {:session, name, forest})

  defp mutate(name, fun), do: GenServer.call(via(name), {:mutate, fun})
  defp via(name), do: {:via, Registry, {Grasp.SessionRegistry, name}}
  defp topic(name), do: "session:" <> name
end
