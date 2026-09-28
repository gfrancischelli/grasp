defmodule Grasp.IndexStore do
  @moduledoc """
  Holds the loaded `Grasp.Index` in `:persistent_term` and reloads it when the index
  file changes.

  The index for a mid-sized project is several megabytes; `:persistent_term` keeps it
  off-heap so every LiveView reads it without copying. The store polls the file's mtime
  every two seconds — `mix grasp.index` rewrites the whole file, so an mtime change is
  the signal — and broadcasts `:index_reloaded` on the `"index"` topic after a successful
  reload.

  A failed load (missing or invalid file) keeps the previous index, records the reason in
  `last_error/0` for the page to show, and records the file's mtime all the same, so the
  next poll waits for the file to change instead of re-reading and re-logging an
  unreadable index every two seconds.

  A project that has never run `mix grasp.index` has no file at all, which is a beginning
  rather than a failure: the store watches the path it would be written to, holds no index
  and no error, and the poll picks the file up the moment it appears.

  The mtime is read *before* the file, so a rewrite landing between the two leaves the
  stored mtime older than the file's and the next poll picks the new content up; reading
  it after would pair the old index with the new mtime and never reload.

  The store also owns the two caches an index is rendered through — `Grasp.Highlight`'s
  parse cache and `GraspWeb.ChatMarkdown`'s — so both tables live as long as the
  application, and clears them on every successful load. A memoised parse is keyed by
  function id and carries the line numbers of the span it was computed for, so a stale
  entry would highlight the new index's source at the old index's coordinates; a memoised
  answer holds links to the functions the index had when it was rendered.
  """

  use GenServer
  require Logger

  @key {__MODULE__, :index}
  @topic "index"
  @poll_ms 2_000

  @doc """
  Starts the store.

  `:path` defaults to the `:grasp, :index_path` config, and that to `.grasp/index.json`
  under `Grasp.Application.home/0` — the directory Grasp was started in, which is also
  where `Grasp.Comments` keeps its file and what `Grasp.Reindexer` compares a document's
  project root against, so all three agree on which checkout is the reader's own.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The loaded index, or `nil` when none has been loaded."
  @spec get() :: Grasp.Index.t() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc """
  The index file being watched, whether or not it exists yet.

  `timeout` is worth raising for a caller that cannot afford to fail: loading a
  multi-megabyte document happens inside the store's own callbacks, and a call made while
  one is in flight waits for it.
  """
  @spec path() :: String.t()
  @spec path(timeout()) :: String.t()
  def path(timeout \\ 5_000), do: GenServer.call(__MODULE__, :path, timeout)

  @doc "The reason the last load failed, or `nil` when the last load succeeded."
  @spec last_error() :: term() | nil
  def last_error, do: GenServer.call(__MODULE__, :last_error)

  @doc "Loads `path`, replaces the index and starts watching that path."
  @spec load(String.t()) :: :ok | {:error, term()}
  def load(path), do: GenServer.call(__MODULE__, {:load, path})

  @doc """
  Reloads the watched path now.

  `timeout` covers decoding the document, which is the slow part and happens in the
  store's callback.
  """
  @spec reload() :: :ok | {:error, term()}
  @spec reload(timeout()) :: :ok | {:error, term()}
  def reload(timeout \\ 5_000), do: GenServer.call(__MODULE__, :reload, timeout)

  @doc "Subscribes the caller to `:index_reloaded` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @impl true
  def init(opts) do
    path = Path.expand(Keyword.get(opts, :path) || configured_path())
    :ok = Grasp.Highlight.ensure_cache()
    :ok = GraspWeb.ChatMarkdown.ensure_cache()
    state = %{path: path, mtime: nil, last_error: nil}

    state =
      if File.regular?(path) do
        case do_load(path, state) do
          {:ok, state} -> state
          {:error, _reason, state} -> state
        end
      else
        # A store watching a file that is not there holds no index: one a previous start put
        # there would be read as this path's contents.
        :persistent_term.erase(@key)
        state
      end

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call(:last_error, _from, state), do: {:reply, state.last_error, state}

  def handle_call({:load, path}, _from, state), do: load_path(path, state)

  def handle_call(:reload, _from, state), do: load_path(state.path, state)

  @impl true
  def handle_info(:poll, state) do
    state =
      case File.stat(state.path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime != state.mtime ->
          case do_load(state.path, state) do
            {:ok, state} -> state
            {:error, _reason, state} -> state
          end

        _ ->
          state
      end

    schedule_poll()
    {:noreply, state}
  end

  defp load_path(path, state) do
    case do_load(path, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_load(path, state) do
    # Configuration gives a path relative to the project root; storing it expanded keeps
    # mtime polling and `path/0` independent of the current working directory.
    path = Path.expand(path)
    mtime = mtime(path)

    case Grasp.Index.load(path) do
      {:ok, index} ->
        :persistent_term.put(@key, index)
        :ok = Grasp.Highlight.clear_cache()
        :ok = GraspWeb.ChatMarkdown.clear_cache()
        Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :index_reloaded)
        {:ok, %{state | path: path, mtime: mtime, last_error: nil}}

      {:error, reason} ->
        log_failure(path, mtime, reason, state)
        {:error, reason, %{state | path: path, mtime: mtime, last_error: reason}}
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> nil
    end
  end

  # An unreadable file is re-read only once its mtime changes, so logging once per distinct
  # mtime turns a broken index into one warning rather than one every poll.
  defp log_failure(path, mtime, reason, state) do
    if is_nil(mtime) or path != state.path or mtime != state.mtime do
      Logger.warning("grasp: could not load index #{path}: #{inspect(reason)}")
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  @doc """
  The index file the store watches unless started with a `:path` of its own: the
  `:grasp, :index_path` config, and `.grasp/index.json` under `Grasp.Application.home/0`
  when that is unset.
  """
  # Home rather than the working directory: an index written for a worktree still belongs
  # to the reader's own checkout, and that is the directory the comments file, the sessions
  # and the reindexer's own idea of "this project" are all anchored to. Before Grasp has
  # started there is no home, and the working directory is the same thing.
  @spec configured_path() :: Path.t()
  def configured_path do
    Application.get_env(:grasp, :index_path) ||
      Path.join(Grasp.Application.home() || File.cwd!(), ".grasp/index.json")
  end
end
