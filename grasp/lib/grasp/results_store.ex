defmodule Grasp.ResultsStore do
  @moduledoc """
  Holds the results document `mix grasp.test` writes (see `Grasp.TestResults`) in
  `:persistent_term` and reloads it when the file changes.

  The store polls the file's mtime every two seconds and broadcasts `:results_reloaded` on
  the `"results"` topic after every load that changes what it holds. It watches the one path
  it is given and never lists the directory: the task writes the document to a temporary
  file beside that path and renames it over it, holding `results.json.lock` while it does,
  so neither the half-written file nor the lock is ever the watched one.

  A missing file is no results, which is not an error: most projects have never run a test
  through Grasp. The store holds nothing, and picks the file up the moment it appears; a
  file that goes away takes its results with it. A file that cannot be read or decoded
  keeps the previous document, is logged once per mtime, and is not read again until its
  mtime changes.

  A test run finishing (`{:run_finished, run}` on `Grasp.Runs`' status topic, for a run of
  kind `:tests`) reloads the file at once rather than at the next poll: the mtime has a
  resolution of one second, so a run writing the file within the second of the previous
  write leaves an mtime the poll cannot tell from the one it holds.

  The mtime is read *before* the file, so a rewrite landing between the two leaves the
  stored mtime older than the file's and the next poll picks the rewritten content up.

  Every document loaded carries a `generation` no other load in the VM carries, so a holder
  of answers taken against one can tell whether it still has that document without
  comparing their contents.
  """

  use GenServer
  require Logger

  @key {__MODULE__, :results}
  @topic "results"
  @poll_ms 2_000

  @doc """
  Starts the store.

  `:path` defaults to the `:grasp, :results_path` config, and that to `results.json` in the
  directory the index is read from (`Grasp.IndexStore.configured_path/0`), which is where
  `mix grasp.test` writes it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The loaded results document, or `nil` when there is none."
  @spec get() :: Grasp.TestResults.document() | nil
  def get do
    case snapshot() do
      {_generation, document} -> document
      nil -> nil
    end
  end

  @doc """
  The loaded document together with its generation, read at once, or `nil` when there is
  none.
  """
  @spec snapshot() :: {pos_integer(), Grasp.TestResults.document()} | nil
  def snapshot, do: :persistent_term.get(@key, nil)

  @doc "The results file being watched, whether or not it exists."
  @spec path() :: String.t()
  def path, do: GenServer.call(__MODULE__, :path)

  @doc """
  Loads `path` and starts watching it.

  A missing file clears the results and answers `:ok`; a file that cannot be read keeps the
  previous document and answers the reason.
  """
  @spec load(String.t()) :: :ok | {:error, term()}
  def load(path), do: GenServer.call(__MODULE__, {:load, path})

  @doc "Reloads the watched path at once, as `load/1` does."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Subscribes the caller to `:results_reloaded` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @impl true
  def init(opts) do
    path = Path.expand(Keyword.get(opts, :path) || configured_path())
    # A store starts holding nothing: a document a previous start put there would otherwise
    # be read as this path's contents while this one is missing.
    :persistent_term.erase(@key)
    :ok = Grasp.Runs.subscribe_status()
    {_reply, state} = do_load(path, %{path: path, mtime: nil})
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:load, path}, _from, state) do
    {reply, state} = do_load(Path.expand(path), state)
    {:reply, reply, state}
  end

  def handle_call(:reload, _from, state) do
    {reply, state} = do_load(state.path, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      if mtime(state.path) != state.mtime do
        {_reply, state} = do_load(state.path, state)
        state
      else
        state
      end

    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:run_finished, %{kind: :tests}}, state) do
    {_reply, state} = do_load(state.path, state)
    {:noreply, state}
  end

  def handle_info({:run_finished, _other_kind}, state), do: {:noreply, state}
  def handle_info({:run_started, _run}, state), do: {:noreply, state}

  defp do_load(path, state) do
    mtime = mtime(path)

    result =
      with {:ok, binary} <- File.read(path) do
        Grasp.TestResults.decode(binary)
      end

    case result do
      {:ok, document} ->
        :persistent_term.put(@key, {:erlang.unique_integer([:positive, :monotonic]), document})
        broadcast()
        {:ok, %{state | path: path, mtime: mtime}}

      {:error, :enoent} ->
        if snapshot() != nil do
          :persistent_term.erase(@key)
          broadcast()
        end

        {:ok, %{state | path: path, mtime: nil}}

      {:error, reason} ->
        log_failure(path, mtime, reason, state)
        {{:error, reason}, %{state | path: path, mtime: mtime}}
    end
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :results_reloaded)

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> nil
    end
  end

  # An unreadable file is re-read only once its mtime changes, so logging once per distinct
  # mtime turns a broken document into one warning rather than one every poll.
  defp log_failure(path, mtime, reason, state) do
    if path != state.path or mtime != state.mtime do
      Logger.warning("grasp: could not load test results #{path}: #{inspect(reason)}")
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  defp configured_path do
    Application.get_env(:grasp, :results_path) ||
      Path.join(Path.dirname(Grasp.IndexStore.configured_path()), "results.json")
  end
end
