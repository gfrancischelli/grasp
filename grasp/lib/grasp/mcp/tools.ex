defmodule Grasp.MCP.Tools do
  @moduledoc "Shared plumbing for the MCP tools: the loaded index, session cards, and JSON/error replies."

  alias Anubis.Server.Response
  alias Grasp.Session
  alias Grasp.Session.Disk
  alias Grasp.Session.Forest

  @doc "The loaded index, or the tool error every index-reading tool replies with when none is loaded."
  @spec index() :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index, do: index(Grasp.IndexStore.get())

  @doc "`index/0` over a store value, so the no-index reply can be exercised without a store."
  @spec index(Grasp.Index.t() | nil) :: {:ok, Grasp.Index.t()} | {:error, Response.t()}
  def index(nil), do: {:error, Response.error(Response.tool(), "no index loaded")}
  def index(%Grasp.Index{} = index), do: {:ok, index}

  @doc """
  The description every tool's `session` field carries: what the field addresses, and the
  rule a name has to keep.

  Built from `Grasp.Session.Disk.name_rule/0`, so the schema a client reads and the error a
  refused name is answered with cannot come to say different things.
  """
  @spec session_field_description() :: String.t()
  def session_field_description do
    "The review session to act on; #{Disk.name_rule()}. " <>
      "Default `default`, which the page at `/` shows"
  end

  @doc """
  The description every comment tool's `session` field carries, the field being required.

  Built from `Grasp.Session.Disk.name_rule/0`, as `session_field_description/0` is, so a
  comment tool and a card tool state the same rule. It names no default: a thread belongs
  to the session it was written in, and a comment tool that fell back to one would read and
  write another review's threads without a word.
  """
  @spec comment_session_field_description() :: String.t()
  def comment_session_field_description do
    "The review session whose comments to act on; #{Disk.name_rule()}. " <>
      "Threads belong to the session they were written in, so pass the session you are driving"
  end

  @doc """
  `session` when it is a name a session can carry, or the tool error such a name is
  answered with; `nil`, a session not given, is refused the same way.

  The comment tools check a name without starting a session under it: reading or answering
  threads leaves the viewer's sessions as they are.
  """
  @spec check_session(term()) :: {:ok, Session.name()} | {:error, Response.t()}
  def check_session(session) do
    if Disk.valid_name?(session),
      do: {:ok, session},
      else: {:error, Response.error(Response.tool(), Disk.name_rule())}
  end

  @doc """
  Starts the session named `session`, or the tool error a name no session can carry is
  answered with.

  A session is a file under `.grasp/sessions/`, so a name outside what
  `Grasp.Session.Disk.valid_name?/1` accepts is refused here rather than started: a session
  under such a name would run for the length of the conversation and then be gone, which is
  the one thing a review session is not. Every tool that takes a `session` goes through
  this, so a client learns the rule from the first call that breaks it.
  """
  @spec ensure_session(Session.name()) :: {:ok, Session.name()} | {:error, Response.t()}
  def ensure_session(session) when is_binary(session) do
    with {:ok, session} <- check_session(session) do
      :ok = Session.ensure(session)
      {:ok, session}
    end
  end

  @doc """
  The card `card_id` of the session named `session`, or the message a tool answers with when
  the session holds no such card.

  Starts the session if it is not running, so every card-addressing tool reads the same
  empty forest whether or not anyone has opened the session yet, and refuses a name no
  session can carry as `ensure_session/1` does.
  """
  @spec fetch_card(Session.name(), Forest.id()) ::
          {:ok, Forest.card()} | {:error, String.t() | Response.t()}
  def fetch_card(session, card_id) do
    with {:ok, session} <- ensure_session(session) do
      case Forest.card(Session.get(session), card_id) do
        nil -> {:error, "unknown card: #{card_id}"}
        card -> {:ok, card}
      end
    end
  end

  @doc """
  Every card in `card_ids`, or the message naming the first id the session holds no card for.

  A tool taking a list of ids answers for all of them before it changes anything, so a call
  naming one card that has since closed leaves the graph as it was rather than half moved.
  """
  @spec fetch_cards(Session.name(), [Forest.id()]) ::
          {:ok, [Forest.card()]} | {:error, String.t() | Response.t()}
  def fetch_cards(session, card_ids) when is_list(card_ids) do
    # The session is started here rather than only inside `fetch_card/2`, which an empty list
    # never reaches: the tool goes on to call the session either way.
    with {:ok, session} <- ensure_session(session) do
      card_ids
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, cards} ->
        case fetch_card(session, id) do
          {:ok, card} -> {:cont, {:ok, [card | cards]}}
          {:error, _message} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, cards} -> {:ok, Enum.reverse(cards)}
        {:error, _message} = error -> error
      end
    end
  end

  @doc """
  The group `group_id` of the session named `session`, or the message a tool answers with
  when the session has no such group.

  Starts the session if it is not running, as `fetch_card/2` does.
  """
  @spec fetch_group(Session.name(), Forest.group_id()) ::
          {:ok, Forest.group()} | {:error, String.t() | Response.t()}
  def fetch_group(session, group_id) do
    with {:ok, session} <- ensure_session(session) do
      case Forest.group(Session.get(session), group_id) do
        nil -> {:error, "unknown group: #{group_id}"}
        group -> {:ok, group}
      end
    end
  end

  @doc """
  The record for the function id `id`, or the message a tool answers an unknown id with.

  Any arity a definition with default arguments answers to resolves to that definition, so
  `record["id"]` is the canonical id the graph and the cards are keyed by.
  """
  @spec fetch_function(Grasp.Index.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_function(%Grasp.Index{} = index, id) do
    case Grasp.Index.fetch_function(index, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, "unknown function: #{id}"}
    end
  end

  @doc "A filter term folded to lower case, passing `nil` — an absent term — through."
  @spec downcase(String.t() | nil) :: String.t() | nil
  def downcase(nil), do: nil
  def downcase(string) when is_binary(string), do: String.downcase(string)

  @doc "A JSON tool reply."
  @spec reply(term(), term()) :: {:reply, Response.t(), term()}
  def reply(frame, data), do: {:reply, Response.json(Response.tool(), data), frame}

  @doc "A tool error reply, from a message or from a response an earlier step already built."
  @spec error(term(), Response.t() | String.t()) :: {:reply, Response.t(), term()}
  def error(frame, %Response{} = response), do: {:reply, response, frame}

  def error(frame, message) when is_binary(message),
    do: {:reply, Response.error(Response.tool(), message), frame}
end
