defmodule Grasp.Comments do
  @moduledoc """
  Review comments written on lines of the functions the cards show.

  Comments belong to the project rather than to a session. A session is a working
  arrangement of cards that lives only while the viewer runs, whereas a remark about a
  line is worth keeping: the reviewer closes the card, reopens the project tomorrow, and
  expects the thread to still hang off that line. One store therefore holds every thread
  for the indexed project, and each thread names the function it belongs to, so any
  session that happens to draw that function shows it.

  A thread records the line number it was written on *and* the text of that line, the
  snippet. Code moves under a comment, so the number alone is not an anchor;
  `Grasp.Comments.Anchor` re-places a thread against the current record from the snippet.
  The snippet is captured when the comment is written — `snippet/3` reads it off the
  record — because afterwards the line it describes may be gone.

  A thread may cover a range: `end_line` is the last line of it, `nil` for a thread on one
  line. The snippet stays the first line's text, so placing a ranged thread is the same
  question as placing any other — where its first line has gone — and the rest of the range
  is counted out from there by whoever draws it.

  Threads and replies draw their ids from a single counter that only ever grows, so an id
  freed by a delete is never handed out again and a client holding a stale id cannot
  address someone else's comment.

  Persistence is a single JSON document, `.grasp/comments.json` under `Grasp.Application.home/0`
  — the checkout Grasp was started in — chosen so comments travel with that checkout and can
  be read and reviewed like any other file. The home directory is the reader's, not the
  reviewed tree's: a pull request read from a worktree names that worktree as the index's
  project root, and threads left on it still belong to the reader who wrote them and are
  still there once the worktree is gone. The path can be overridden by `start_link/1` or by
  the `:grasp, :comments_path` setting, and before Grasp has started there is no home and
  the store keeps its threads in memory only. The whole document is rewritten
  after every mutation: it is small, and a full rewrite cannot leave a half-applied edit
  behind. A file that cannot be read, parsed or written is a warning and never a crash —
  losing the viewer over a comment file would be a worse failure than losing the file.

  A file the store could not fully read is salvaged rather than discarded: entries it
  cannot decode are skipped and the rest are kept, and the file is renamed to
  `<path>.corrupt` before the next write, so a rewrite never silently replaces a history
  someone still wants. The id counter is likewise recomputed on every read as one past the
  highest id the document holds, so a truncated or hand-edited `next_id` cannot make the
  next comment overwrite an existing one.

  A thread published to a pull request carries the `github` stamp `mark_published/2` writes:
  the review comment's id, its URL and the moment it was posted. The stamp is what tells a
  later publish that the thread is already on GitHub, and the id is what a reply is addressed
  to, so it belongs with the thread rather than in a ledger of its own.

  A comment and each reply can be rewritten by `edit/3`. The rewrite keeps the entry's id,
  author and `created_at`, and records `edited_at`, so a card can say the text is not the
  text first written. A thread published to a pull request keeps its stamp through an edit:
  GitHub holds the text it was sent, and the edit is the checkout's alone.

  Every successful mutation broadcasts `:comments_changed` on the `"comments"` topic.
  """

  use GenServer

  require Logger

  alias Grasp.Comments.Anchor

  @type author :: String.t()
  @type side :: String.t()
  @type store :: GenServer.server()
  @type reply :: %{
          id: pos_integer(),
          author: author(),
          body: String.t(),
          created_at: String.t(),
          edited_at: String.t() | nil
        }
  @type github :: %{id: pos_integer(), url: String.t(), published_at: String.t()}
  @type thread :: %{
          id: pos_integer(),
          function_id: String.t(),
          side: side(),
          line: pos_integer(),
          end_line: pos_integer() | nil,
          snippet: String.t() | nil,
          body: String.t(),
          author: author(),
          created_at: String.t(),
          edited_at: String.t() | nil,
          resolved: boolean(),
          github: github() | nil,
          replies: [reply()]
        }

  @topic "comments"
  @authors ~w(human agent)
  @sides ~w(new old)

  @doc """
  Starts the store.

  `:path` overrides the file to read and write, taking precedence over the
  `:grasp, :comments_path` setting and over the path under the home directory, and
  `:name` registers the store under a name other than the module, for a second store
  running beside the application's, which `list/2` and `add/2` address by that name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribes the caller to `:comments_changed` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @doc """
  Threads sorted by id.

  `:function_id` keeps only the threads on that function, and `:include_resolved` (false
  by default) keeps the resolved ones as well. `store` reads a store other than the
  application's.
  """
  @spec list() :: [thread()]
  @spec list(keyword()) :: [thread()]
  @spec list(keyword(), store()) :: [thread()]
  def list(opts \\ [], store \\ __MODULE__) when is_list(opts),
    do: GenServer.call(store, {:list, opts})

  @doc "Every thread, resolved ones included, grouped by function id and sorted by id."
  @spec by_function() :: %{String.t() => [thread()]}
  def by_function, do: GenServer.call(__MODULE__, :by_function)

  @doc "Fetches the thread `id`."
  @spec fetch(pos_integer()) :: {:ok, thread()} | :error
  def fetch(id) when is_integer(id), do: GenServer.call(__MODULE__, {:fetch, id})

  @doc """
  Opens a thread from `%{function_id, side, line, body, author, snippet, end_line}`.

  `side` is `"new"` or `"old"`, `author` is `"human"` or `"agent"`, `body` is stored
  trimmed and may not be blank, and `snippet` (optional) is the text of the line as it
  reads when the comment is written. `end_line` (optional) makes the thread cover a range
  of the same side, and has to be a line after `line`; anything else is
  `{:error, :invalid_end_line}`. Whether the range fits the function is a question about
  the record the comment is written against, and is answered by the caller holding it.
  `store` writes to a store other than the application's.
  """
  @spec add(map()) :: {:ok, thread()} | {:error, :invalid | :invalid_end_line}
  @spec add(map(), store()) :: {:ok, thread()} | {:error, :invalid | :invalid_end_line}
  def add(attrs, store \\ __MODULE__) when is_map(attrs),
    do: GenServer.call(store, {:add, attrs})

  @doc "Appends a reply `%{body, author}` to the thread `id`, returning the whole thread."
  @spec reply(pos_integer(), map()) :: {:ok, thread()} | {:error, :unknown | :invalid}
  def reply(id, attrs) when is_integer(id) and is_map(attrs),
    do: GenServer.call(__MODULE__, {:reply, id, attrs})

  @doc """
  Rewrites the body of the thread `id` — its opening comment when `reply_id` is `nil`, the
  reply `reply_id` of it otherwise — and stamps the entry's `edited_at`.

  `body` is stored trimmed and may not be blank, as when it was first written; a blank one is
  `{:error, :invalid}`, and a thread or reply the store does not hold is `{:error, :unknown}`.
  Answers the whole thread.
  """
  @spec edit(pos_integer(), pos_integer() | nil, String.t()) ::
          {:ok, thread()} | {:error, :unknown | :invalid}
  def edit(id, reply_id, body)
      when is_integer(id) and (is_integer(reply_id) or is_nil(reply_id)) and is_binary(body),
      do: GenServer.call(__MODULE__, {:edit, id, reply_id, body})

  @doc "Marks the thread `id` resolved or unresolved."
  @spec set_resolved(pos_integer(), boolean()) :: {:ok, thread()} | {:error, :unknown}
  def set_resolved(id, resolved) when is_integer(id) and is_boolean(resolved),
    do: GenServer.call(__MODULE__, {:set_resolved, id, resolved})

  @doc """
  Stamps the thread `id` with the GitHub review comment `%{id, url}` it was published as.

  `published_at` is the moment of the stamp, in the same ISO 8601 UTC spelling as
  `created_at`. A thread stamped twice keeps the latest comment, and a comment without a
  positive integer id and a URL is `{:error, :invalid}`.
  """
  @spec mark_published(pos_integer(), %{id: pos_integer(), url: String.t()}) ::
          {:ok, thread()} | {:error, :unknown | :invalid}
  def mark_published(id, comment) when is_integer(id) and is_map(comment),
    do: GenServer.call(__MODULE__, {:mark_published, id, comment})

  @doc "Deletes the thread `id` and its replies; an unknown id changes nothing."
  @spec delete(pos_integer()) :: :ok
  def delete(id) when is_integer(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Deletes one reply of a thread; an unknown thread or reply changes nothing."
  @spec delete_reply(pos_integer(), pos_integer()) :: :ok
  def delete_reply(thread_id, reply_id) when is_integer(thread_id) and is_integer(reply_id),
    do: GenServer.call(__MODULE__, {:delete_reply, thread_id, reply_id})

  @doc """
  The file the threads are written to, or `nil` when they are held in memory only.

  `store` reads a store other than the application's, as `list/2` and `add/2` do.
  """
  @spec path(store()) :: String.t() | nil
  def path(store \\ __MODULE__), do: GenServer.call(store, :path)

  @doc """
  The trimmed text of line `line` of `record` on `side`, or `nil` when there is no such
  line.

  The `"new"` side is numbered from the record's span, as the cards number it; the
  `"old"` side is numbered from 1, as the diff's base column is.
  """
  @spec snippet(map() | nil, side(), pos_integer()) :: String.t() | nil
  def snippet(record, side, line) do
    case Anchor.lines(record, side) do
      nil ->
        nil

      lines ->
        Enum.find_value(lines, fn {number, text} -> number == line && String.trim(text) end)
    end
  end

  @doc """
  The lines `thread` covers, as they were numbered when it was written.

  A thread on one line is the range of that line alone, so a caller draws every thread the
  same way whether or not it was written over a range.
  """
  @spec range(thread()) :: Range.t()
  def range(thread), do: thread.line..(thread.end_line || thread.line)//1

  @doc false
  @spec encode([thread()], pos_integer()) :: String.t()
  def encode(threads, next_id) do
    document = %{
      "version" => 1,
      "next_id" => next_id,
      "comments" => Enum.map(threads, &encode_thread/1)
    }

    Jason.encode!(document, pretty: true)
  end

  @doc false
  @spec decode(String.t()) ::
          {:ok, {[thread()], pos_integer(), non_neg_integer()}} | {:error, term()}
  def decode(binary) do
    with {:ok, document} <- Jason.decode(binary),
         {:ok, next_id, comments} <- document_parts(document) do
      {threads, dropped} = decode_threads(comments)
      threads = Enum.sort_by(threads, & &1.id)
      {:ok, {threads, counter(threads, next_id), dropped}}
    end
  end

  @impl true
  def init(opts) do
    override = Keyword.get(opts, :path) || Application.get_env(:grasp, :comments_path)

    state = %{
      path: override || derived_path(),
      threads: %{},
      next_id: 1,
      corrupt: false
    }

    {:ok, read(state)}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    function_id = Keyword.get(opts, :function_id)
    include_resolved = Keyword.get(opts, :include_resolved, false)

    threads =
      state.threads
      |> sorted()
      |> Enum.filter(fn thread ->
        (is_nil(function_id) or thread.function_id == function_id) and
          (include_resolved or not thread.resolved)
      end)

    {:reply, threads, state}
  end

  def handle_call(:by_function, _from, state),
    do: {:reply, state.threads |> sorted() |> Enum.group_by(& &1.function_id), state}

  def handle_call({:fetch, id}, _from, state), do: {:reply, Map.fetch(state.threads, id), state}

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:add, attrs}, _from, state) do
    case build_thread(attrs, state.next_id) do
      {:ok, thread} ->
        state = %{
          state
          | threads: Map.put(state.threads, thread.id, thread),
            next_id: state.next_id + 1
        }

        {:reply, {:ok, thread}, commit(state)}

      :error ->
        {:reply, {:error, :invalid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reply, id, attrs}, _from, state) do
    with {:ok, thread} <- Map.fetch(state.threads, id),
         {:ok, reply} <- build_reply(attrs, state.next_id) do
      thread = %{thread | replies: thread.replies ++ [reply]}

      state = %{
        state
        | threads: Map.put(state.threads, id, thread),
          next_id: state.next_id + 1
      }

      {:reply, {:ok, thread}, commit(state)}
    else
      :error -> {:reply, {:error, thread_error(state, id)}, state}
    end
  end

  def handle_call({:edit, id, reply_id, body}, _from, state) do
    with {:ok, thread} <- Map.fetch(state.threads, id),
         {:ok, thread} <- rewrite(thread, reply_id, body) do
      state = %{state | threads: Map.put(state.threads, id, thread)}
      {:reply, {:ok, thread}, commit(state)}
    else
      :error -> {:reply, {:error, :unknown}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_resolved, id, resolved}, _from, state) do
    case Map.fetch(state.threads, id) do
      {:ok, %{resolved: ^resolved} = thread} ->
        {:reply, {:ok, thread}, state}

      {:ok, thread} ->
        thread = %{thread | resolved: resolved}
        state = %{state | threads: Map.put(state.threads, id, thread)}
        {:reply, {:ok, thread}, commit(state)}

      :error ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:mark_published, id, comment}, _from, state) do
    with {:ok, thread} <- Map.fetch(state.threads, id),
         {:ok, github} <- build_github(comment) do
      thread = %{thread | github: github}
      state = %{state | threads: Map.put(state.threads, id, thread)}
      {:reply, {:ok, thread}, commit(state)}
    else
      :error -> {:reply, {:error, thread_error(state, id)}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.threads, id) do
      {nil, _threads} -> {:reply, :ok, state}
      {_thread, threads} -> {:reply, :ok, commit(%{state | threads: threads})}
    end
  end

  def handle_call({:delete_reply, thread_id, reply_id}, _from, state) do
    case Map.fetch(state.threads, thread_id) do
      {:ok, thread} ->
        replies = Enum.reject(thread.replies, &(&1.id == reply_id))

        if replies == thread.replies do
          {:reply, :ok, state}
        else
          thread = %{thread | replies: replies}
          state = %{state | threads: Map.put(state.threads, thread_id, thread)}
          {:reply, :ok, commit(state)}
        end

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp commit(state) do
    state = persist(state)
    Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :comments_changed)
    state
  end

  defp read(%{path: nil} = state), do: empty(state, false)

  defp read(state) do
    case File.read(state.path) do
      {:ok, binary} -> decode_file(binary, state)
      {:error, :enoent} -> empty(state, false)
      {:error, reason} -> empty(log_read_failure(state, reason), true)
    end
  end

  defp decode_file(binary, state) do
    case decode(binary) do
      {:ok, {threads, next_id, 0}} ->
        %{state | threads: Map.new(threads, &{&1.id, &1}), next_id: next_id, corrupt: false}

      {:ok, {threads, next_id, dropped}} ->
        entries = if dropped == 1, do: "entry", else: "entries"
        Logger.warning("grasp: dropped #{dropped} unreadable #{entries} from #{state.path}")

        %{state | threads: Map.new(threads, &{&1.id, &1}), next_id: next_id, corrupt: true}

      {:error, reason} ->
        empty(log_read_failure(state, reason), true)
    end
  end

  defp empty(state, corrupt), do: %{state | threads: %{}, next_id: 1, corrupt: corrupt}

  defp log_read_failure(state, reason) do
    Logger.warning("grasp: could not read comments #{state.path}: #{inspect(reason)}")
    state
  end

  defp persist(%{path: nil} = state), do: state

  defp persist(state) do
    state = keep_corrupt_aside(state)

    case write(state.path, encode(sorted(state.threads), state.next_id)) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("grasp: could not write comments #{state.path}: #{inspect(reason)}")
        state
    end
  end

  defp write(path, document) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, document)
  end

  # Rewriting the document would drop whatever the last read could not decode, so the file
  # it came from is moved aside first and the reviewer keeps a copy to recover by hand.
  defp keep_corrupt_aside(%{corrupt: false} = state), do: state

  # A second damaged file at the same path is kept beside the first rather than over it:
  # `File.rename/2` replaces an existing destination without a word, and the copy it would
  # replace is the one the reader has not looked at yet.
  defp keep_corrupt_aside(state) do
    kept = state.path <> ".corrupt"

    kept =
      if File.exists?(kept),
        do: state.path <> ".#{System.os_time(:second)}.corrupt",
        else: kept

    case File.rename(state.path, kept) do
      :ok -> Logger.warning("grasp: kept the unreadable comments file as #{kept}")
      {:error, reason} -> Logger.warning("grasp: could not keep #{kept}: #{inspect(reason)}")
    end

    %{state | corrupt: false}
  end

  defp derived_path do
    case Grasp.Application.home() do
      home when is_binary(home) -> Path.join(home, ".grasp/comments.json")
      _not_started -> nil
    end
  end

  defp sorted(threads), do: threads |> Map.values() |> Enum.sort_by(& &1.id)

  # One past the highest id the document holds, so a `next_id` that lags behind its own
  # comments — truncated write, hand edit, merge — cannot hand out an id already in use.
  defp counter(threads, next_id) do
    Enum.reduce(threads, max(next_id, 1), fn thread, counter ->
      Enum.reduce(thread.replies, max(counter, thread.id + 1), &max(&2, &1.id + 1))
    end)
  end

  # A mutation that found no thread at all is :unknown; one that found the thread and
  # refused its attributes is :invalid.
  defp thread_error(state, id),
    do: if(Map.has_key?(state.threads, id), do: :invalid, else: :unknown)

  defp build_thread(attrs, id) do
    with {:ok, function_id} <- binary_field(attrs, :function_id),
         {:ok, side} <- member_field(attrs, :side, @sides),
         {:ok, line} <- line_field(attrs),
         {:ok, end_line} <- end_line_value(Map.get(attrs, :end_line), line),
         {:ok, author} <- member_field(attrs, :author, @authors),
         {:ok, body} <- body_field(attrs) do
      {:ok,
       %{
         id: id,
         function_id: function_id,
         side: side,
         line: line,
         end_line: end_line,
         snippet: Map.get(attrs, :snippet),
         body: body,
         author: author,
         created_at: now(),
         edited_at: nil,
         resolved: false,
         github: nil,
         replies: []
       }}
    end
  end

  defp rewrite(thread, reply_id, body) do
    with {:ok, body} <- body_value(body) do
      edited = %{body: body, edited_at: now()}

      case reply_id do
        nil ->
          {:ok, Map.merge(thread, edited)}

        reply_id ->
          case Enum.find_index(thread.replies, &(&1.id == reply_id)) do
            nil ->
              {:error, :unknown}

            at ->
              {:ok,
               %{thread | replies: List.update_at(thread.replies, at, &Map.merge(&1, edited))}}
          end
      end
    end
  end

  defp build_github(%{id: id, url: url}) when is_integer(id) and id > 0 and is_binary(url),
    do: {:ok, %{id: id, url: url, published_at: now()}}

  defp build_github(_comment), do: :error

  defp build_reply(attrs, id) do
    with {:ok, author} <- member_field(attrs, :author, @authors),
         {:ok, body} <- body_field(attrs) do
      {:ok, %{id: id, author: author, body: body, created_at: now(), edited_at: nil}}
    end
  end

  defp binary_field(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _invalid -> :error
    end
  end

  defp member_field(attrs, key, allowed) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> if value in allowed, do: {:ok, value}, else: :error
      _invalid -> :error
    end
  end

  defp line_field(attrs) do
    case Map.get(attrs, :line) do
      line when is_integer(line) and line > 0 -> {:ok, line}
      _invalid -> :error
    end
  end

  # A range that stops where it starts is a thread on one line, so it is refused rather than
  # stored as a range of one: two spellings of the same thread would read differently
  # everywhere the range is drawn.
  defp end_line_value(nil, _line), do: {:ok, nil}

  defp end_line_value(end_line, line) when is_integer(end_line) and end_line > line,
    do: {:ok, end_line}

  defp end_line_value(_invalid, _line), do: {:error, :invalid_end_line}

  defp body_field(attrs) do
    case body_value(Map.get(attrs, :body)) do
      {:ok, body} -> {:ok, body}
      {:error, :invalid} -> :error
    end
  end

  defp body_value(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :invalid}
      trimmed -> {:ok, trimmed}
    end
  end

  defp body_value(_body), do: {:error, :invalid}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp encode_thread(thread) do
    encoded = %{
      "id" => thread.id,
      "function_id" => thread.function_id,
      "side" => thread.side,
      "line" => thread.line,
      "end_line" => thread.end_line,
      "snippet" => thread.snippet,
      "body" => thread.body,
      "author" => thread.author,
      "created_at" => thread.created_at,
      "edited_at" => thread.edited_at,
      "resolved" => thread.resolved,
      "replies" => Enum.map(thread.replies, &encode_reply/1)
    }

    encode_github(encoded, thread.github)
  end

  defp encode_github(encoded, nil), do: encoded

  defp encode_github(encoded, github) do
    Map.put(encoded, "github", %{
      "id" => github.id,
      "url" => github.url,
      "published_at" => github.published_at
    })
  end

  defp encode_reply(reply) do
    %{
      "id" => reply.id,
      "author" => reply.author,
      "body" => reply.body,
      "created_at" => reply.created_at,
      "edited_at" => reply.edited_at
    }
  end

  defp document_parts(%{"version" => 1, "next_id" => next_id, "comments" => comments})
       when is_integer(next_id) and next_id > 0 and is_list(comments),
       do: {:ok, next_id, comments}

  defp document_parts(document), do: {:error, {:invalid_document, document}}

  defp decode_threads(comments) do
    {threads, dropped} =
      Enum.reduce(comments, {[], 0}, fn comment, {threads, dropped} ->
        case decode_thread(comment) do
          {:ok, thread, reply_drops} -> {[thread | threads], dropped + reply_drops}
          :error -> {threads, dropped + 1}
        end
      end)

    {Enum.reverse(threads), dropped}
  end

  defp decode_thread(
         %{
           "id" => id,
           "function_id" => function_id,
           "side" => side,
           "line" => line,
           "body" => body,
           "author" => author,
           "created_at" => created_at
         } = comment
       )
       when is_integer(id) and id > 0 and is_binary(function_id) and is_binary(body) and
              is_binary(created_at) and is_integer(line) and line > 0 and side in @sides and
              author in @authors do
    snippet = Map.get(comment, "snippet")
    edited_at = Map.get(comment, "edited_at")

    with true <- is_nil(snippet) or is_binary(snippet),
         true <- is_nil(edited_at) or is_binary(edited_at),
         {:ok, end_line} <- end_line_value(Map.get(comment, "end_line"), line),
         {:ok, github} <- decode_github(Map.get(comment, "github")) do
      {replies, dropped} = decode_replies(Map.get(comment, "replies", []))

      {:ok,
       %{
         id: id,
         function_id: function_id,
         side: side,
         line: line,
         end_line: end_line,
         snippet: snippet,
         body: body,
         author: author,
         created_at: created_at,
         edited_at: edited_at,
         resolved: Map.get(comment, "resolved") == true,
         github: github,
         replies: replies
       }, dropped}
    else
      _malformed -> :error
    end
  end

  defp decode_thread(_comment), do: :error

  defp decode_github(nil), do: {:ok, nil}

  defp decode_github(%{"id" => id, "url" => url, "published_at" => published_at})
       when is_integer(id) and id > 0 and is_binary(url) and is_binary(published_at),
       do: {:ok, %{id: id, url: url, published_at: published_at}}

  defp decode_github(_github), do: :error

  defp decode_replies(replies) when is_list(replies) do
    {decoded, dropped} =
      Enum.reduce(replies, {[], 0}, fn reply, {decoded, dropped} ->
        case decode_reply(reply) do
          {:ok, reply} -> {[reply | decoded], dropped}
          :error -> {decoded, dropped + 1}
        end
      end)

    {Enum.reverse(decoded), dropped}
  end

  defp decode_replies(_replies), do: {[], 1}

  defp decode_reply(
         %{"id" => id, "author" => author, "body" => body, "created_at" => created_at} = reply
       )
       when is_integer(id) and id > 0 and is_binary(body) and is_binary(created_at) and
              author in @authors do
    case Map.get(reply, "edited_at") do
      edited_at when is_nil(edited_at) or is_binary(edited_at) ->
        {:ok, %{id: id, author: author, body: body, created_at: created_at, edited_at: edited_at}}

      _malformed ->
        :error
    end
  end

  defp decode_reply(_reply), do: :error
end
