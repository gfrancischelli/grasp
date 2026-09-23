defmodule GraspWeb.ReviewLive do
  @moduledoc """
  The review page: a sidebar that starts from the project's entry points — routes, jobs,
  live views, processes — with the module list as its last group, the card canvas, and the
  palette (⌘K or `/`). Which sidebar groups arrive open is the sidebar's decision, taken from the
  index and the open review threads at mount and again whenever the index reloads, and owned
  by whoever clicks in between.
  State is the session's forest plus the loaded index; both arrive by PubSub so any change
  — from this browser, another tab, or an MCP client later — renders everywhere. Which cards
  are selected is this tab's alone (`selected`): a selection is a gesture half-finished, and
  broadcasting it would move the cards another reader is picking out.

  Review threads arrive the same way and belong to the project rather than to the session, so
  a comment written here shows on every card drawing that function everywhere. What is this
  tab's own is where a comment is being written (`composing`), which resolved threads have
  been opened back up (`expanded_threads`) and which folds of a changes-only diff have been
  opened (`expanded_folds`) — each is one reader mid-gesture.

  The page is mounted by `Grasp.Router.grasp/2` and depends on the two session keys that
  macro's live session provides: `"grasp_path"`, the prefix the host mounted Grasp at, from
  which every link and asset URL is built, and `"mcp_path"`, where the agent reaches
  `Grasp.Plug`. Both are required — a default would render a page whose links quietly point
  somewhere else — so this LiveView is mountable only through the macro.
  """

  use GraspWeb, :live_view

  import GraspWeb.CardComponents
  import GraspWeb.ChatPanel
  import GraspWeb.Help
  import GraspWeb.Palette
  import GraspWeb.Sidebar

  alias Grasp.{Index, IndexStore, Links, Session}
  alias Grasp.Session.Disk
  alias Grasp.Session.Forest

  @groups GraspWeb.Sidebar.group_kinds()
  @no_command "claude command not found; set GRASP_AGENT_COMMAND"

  @impl true
  def mount(params, session, socket) do
    name = Map.get(params, "name", "default")
    # The live session is the one channel open to both the disconnected render and the
    # connected mount. The agent reaches Grasp over HTTP like any other MCP client, so the
    # scheme, host and port it is given are the host endpoint's own.
    prefix = Map.fetch!(session, "grasp_path")
    mcp_url = socket.endpoint.url() <> Map.fetch!(session, "mcp_path")
    socket = assign(socket, grasp_path: prefix, mcp_url: mcp_url)

    # A name that is not a session name names a file the viewer would have to write, so the
    # tab is sent to the default session rather than opening a session under it.
    if Disk.valid_name?(name),
      do: {:ok, mount_session(socket, name)},
      else: {:ok, push_navigate(socket, to: default_path(socket))}
  end

  defp default_path(socket), do: session_path(socket.assigns.grasp_path, "default")

  defp mount_session(socket, name) do
    :ok = Session.ensure(name)
    :ok = Grasp.Agent.ensure(name)

    if connected?(socket) do
      :ok = Session.subscribe(name)
      :ok = Grasp.Agent.subscribe(name)
      :ok = IndexStore.subscribe()
      :ok = Grasp.Comments.subscribe()
    end

    index = IndexStore.get()

    assign(socket,
      name: name,
      index: index,
      index_error: IndexStore.last_error(),
      index_path: IndexStore.path(),
      forest: Session.get(name),
      sessions: Session.list(),
      session_menu_open?: false,
      new_session_name: "",
      expanded_module: nil,
      expanded_groups: default_expanded(index, length(Grasp.Comments.list())),
      callers_open: nil,
      renaming_group: nil,
      comments: Grasp.Comments.by_function(),
      composing: nil,
      expanded_threads: MapSet.new(),
      expanded_folds: MapSet.new(),
      selected: MapSet.new(),
      palette_open?: false,
      palette_query: "",
      palette_results: [],
      palette_selected: 0,
      sidebar_open?: true,
      chat_open?: false,
      chat_error: nil,
      agent: Grasp.Agent.get(name),
      editor: Application.get_env(:grasp, :editor)
    )
  end

  @impl true
  def handle_info({:session, name, %Forest{} = forest}, %{assigns: %{name: name}} = socket) do
    socket = socket |> assign(forest: forest) |> prune_to_forest(forest)
    {:noreply, push_event(socket, "focus", %{id: forest.focus})}
  end

  def handle_info({:agent, name, view}, %{assigns: %{name: name}} = socket),
    do: {:noreply, assign(socket, agent: view)}

  # A reloaded index is a different index, so the sidebar's defaults are taken again: a
  # re-index that adds a base ref gains a Changes group, and leaving the old set in place
  # would open the page's table of contents shut. Only the resulting set is held — nothing
  # records which groups the user toggled by hand — so it is recomputed, not merged.
  # The selection goes with them: a reload rewrites what the cards are of, and a set picked
  # out of the old index is a claim about functions that may no longer be there.
  def handle_info(:index_reloaded, socket) do
    index = IndexStore.get()

    {:noreply,
     assign(socket,
       index: index,
       expanded_groups: default_expanded(index, length(Grasp.Comments.list())),
       selected: MapSet.new(),
       expanded_folds: MapSet.new(),
       index_error: IndexStore.last_error(),
       index_path: IndexStore.path()
     )}
  end

  # Comments belong to the project rather than to this session, so a thread written in
  # another tab — or by the agent — lands on every card drawing that function.
  def handle_info(:comments_changed, socket), do: {:noreply, refresh_comments(socket)}

  # The session this tab is reading has been forgotten, here or in another tab. Its cards are
  # gone with it, so the tab lands on the default canvas rather than on a name with no
  # session behind it; from the default session itself the navigate re-mounts it empty.
  # A deletion of any other session is a broadcast this tab hears only as a bystander.
  def handle_info({:session_deleted, name}, %{assigns: %{name: name}} = socket),
    do: {:noreply, push_navigate(socket, to: default_path(socket))}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) when group in @groups do
    groups = socket.assigns.expanded_groups

    toggled =
      if MapSet.member?(groups, group),
        do: MapSet.delete(groups, group),
        else: MapSet.put(groups, group)

    {:noreply, assign(socket, expanded_groups: toggled)}
  end

  def handle_event("expand_module", %{"module" => module}, socket) do
    expanded = if socket.assigns.expanded_module == module, do: nil, else: module
    {:noreply, assign(socket, expanded_module: expanded)}
  end

  def handle_event("open_root", %{"id" => id}, socket) when is_binary(id),
    do: socket |> clear_selection() |> mutate(&Session.open_root(&1, canonical(socket, id)))

  def handle_event("open_call", %{"card" => card, "target" => target}, socket)
      when is_binary(target),
      do: mutate(socket, &Session.open_child(&1, int(card), canonical(socket, target), target))

  def handle_event("open_caller", %{"card" => card, "caller" => caller}, socket)
      when is_binary(caller) do
    socket = close_overlays(socket)
    id = int(card)
    caller_id = canonical(socket, caller)
    target = call_target(socket, caller_id, function_id(socket, id))
    mutate(socket, &Session.open_caller(&1, id, caller_id, target))
  end

  # The two card menus and the frame rename are one another's alternatives: each is opened
  # by a click that means "not the other one", and two panels absolutely positioned off
  # adjacent wrappers in the same header would otherwise overlap on a card wide enough.
  def handle_event("toggle_callers", %{"card" => card}, socket) do
    id = int(card)
    open = if socket.assigns.callers_open == id, do: nil, else: id

    {:noreply,
     socket
     |> close_overlays()
     |> assign(callers_open: open, forest: Session.focus(socket.assigns.name, id))}
  end

  # Shift+click, which the canvas hook turns into this rather than into a focus: the card is
  # picked out or put back, and nothing else about it changes.
  def handle_event("toggle_select", %{"card" => card}, socket) do
    selected = socket.assigns.selected

    case int(card) do
      nil ->
        {:noreply, socket}

      id ->
        picked =
          if MapSet.member?(selected, id),
            do: MapSet.delete(selected, id),
            else: MapSet.put(selected, id)

        {:noreply, assign(socket, selected: picked)}
    end
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, clear_selection(socket)}

  # The new frame has no title: naming it is a second decision, taken on the frame itself
  # once the reader can see what it holds. The selection has been spent, so it is dropped,
  # and the focus moves onto the frame's first card so the canvas reveals where it went.
  def handle_event("group_selected", _params, socket) do
    case grouping_ids(socket) do
      [] ->
        {:noreply, socket}

      [first | _] = ids ->
        socket
        |> assign(selected: MapSet.new())
        |> mutate(fn name ->
          Session.new_group(name, nil, ids)
          Session.focus(name, first)
        end)
    end
  end

  # The cards stay selected: taking them out of a frame is as often the first half of
  # putting them in another one as it is the end of the gesture.
  def handle_event("ungroup_selected", _params, socket) do
    case grouping_ids(socket) do
      [] -> {:noreply, socket}
      ids -> mutate(socket, &Session.ungroup_cards(&1, ids))
    end
  end

  def handle_event("edit_group_title", %{"group" => group}, socket),
    do: {:noreply, socket |> close_overlays() |> assign(renaming_group: int(group))}

  def handle_event("rename_group", %{"group" => group, "title" => title}, socket)
      when is_binary(title) do
    socket = assign(socket, renaming_group: nil)
    mutate(socket, &Session.rename_group(&1, int(group), title))
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, renaming_group: nil)}

  def handle_event("close_card", %{"card" => card}, socket) do
    id = int(card)
    mutate(forget_callers_menu(socket, id), &Session.close(&1, id))
  end

  def handle_event("close_chain", %{"card" => card}, socket) do
    id = int(card)
    mutate(forget_callers_menu(socket, id), &Session.close_chain(&1, id))
  end

  # A plain click says which card is meant, and the selection is the other answer to that
  # question, so picking a card up by clicking it lets the rest go. Shift+click never reaches
  # here — the canvas hook takes it for `toggle_select` — so the additive gesture is still
  # the only way to hold several cards at once.
  def handle_event("focus_card", %{"card" => card}, socket),
    do: socket |> clear_selection() |> mutate(&Session.focus(&1, int(card)))

  def handle_event("toggle_collapse", %{"card" => card}, socket),
    do: mutate(socket, &Session.toggle_collapse(&1, int(card)))

  def handle_event("toggle_view", %{"card" => card}, socket),
    do: toggle_view(socket, int(card))

  def handle_event("toggle_view_focused", _params, socket),
    do: toggle_view(socket, socket.assigns.forest.focus)

  def handle_event("toggle_context", %{"card" => card}, socket),
    do: toggle_context(socket, int(card))

  def handle_event("toggle_context_focused", _params, socket),
    do: toggle_context(socket, socket.assigns.forest.focus)

  # Which folds are open is this tab's own, and a fold is named by the line it starts at:
  # nothing else about it has to be remembered, since expanding it is the card drawing that
  # stretch again.
  def handle_event("expand_fold", %{"card" => card, "from" => from}, socket) do
    case {int(card), int(from)} do
      {id, from} when is_integer(id) and is_integer(from) ->
        {:noreply,
         assign(socket, expanded_folds: MapSet.put(socket.assigns.expanded_folds, {id, from}))}

      _not_a_fold ->
        {:noreply, socket}
    end
  end

  # A drop carries a group only when it landed inside another group's frame; every other
  # drop is a move alone, so a card keeps the group it was in wherever on the canvas it is
  # put down. Dragging a selected card into a frame takes the rest of the selection with it,
  # which is what makes the set a set — the others keep the positions they had, since only
  # the one under the pointer was moved.
  def handle_event("move_card", %{"card" => card, "x" => x, "y" => y} = params, socket) do
    case {int(card), int(x), int(y)} do
      {id, x, y} when is_integer(id) and is_integer(x) and is_integer(y) ->
        joining = dragged_set(socket, id)

        mutate(socket, fn name ->
          moved = Session.move(name, id, {x, y})

          case int(params["group"]) do
            nil -> moved
            group -> Session.add_to_group(name, group, joining)
          end
        end)

      _ ->
        {:noreply, socket}
    end
  end

  # The canvas is the only thing that knows how large a card came out, so it says where a
  # card with no position goes. It says it for everything it placed in one pass, and the
  # session keeps only what is still unplaced, so a pass measured before a drag in another
  # tab cannot pull the dragged card back.
  def handle_event("place_cards", %{"cards" => cards}, socket) when is_list(cards) do
    placements =
      Enum.flat_map(cards, fn
        %{"id" => id, "x" => x, "y" => y} ->
          case {int(id), int(x), int(y)} do
            {id, x, y} when is_integer(id) and is_integer(x) and is_integer(y) -> [{id, x, y}]
            _unreadable -> []
          end

        _not_a_placement ->
          []
      end)

    case placements do
      [] -> {:noreply, socket}
      placements -> mutate(socket, &Session.place(&1, placements))
    end
  end

  # A group drag carries deltas rather than the position each card lands on: the members start
  # from positions of their own and keep their places relative to one another, so the frame drawn
  # round them moves unchanged. Membership is untouched — a group is moved, not regrouped.
  def handle_event("move_group", %{"group" => group, "dx" => dx, "dy" => dy}, socket) do
    case {int(group), int(dx), int(dy)} do
      {id, dx, dy} when is_integer(id) and is_integer(dx) and is_integer(dy) ->
        mutate(socket, &Session.shift_group(&1, id, {dx, dy}))

      _ ->
        {:noreply, socket}
    end
  end

  # A graph drag carries the cards a reader reached over the drawn edges, which cross groups
  # freely, so the cards travel by a shared displacement and each stays in the group it is a
  # member of. Ids the canvas sends that do not read as integers name no card and are dropped.
  def handle_event("move_cards", %{"cards" => cards, "dx" => dx, "dy" => dy}, socket)
      when is_list(cards) do
    case {int(dx), int(dy)} do
      {dx, dy} when is_integer(dx) and is_integer(dy) ->
        ids = cards |> Enum.map(&int/1) |> Enum.filter(&is_integer/1)
        mutate(socket, &Session.shift_cards(&1, ids, {dx, dy}))

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("move_cards", _params, socket), do: {:noreply, socket}

  def handle_event("reset_layout", _params, socket),
    do: mutate(socket, &Session.reset_layout/1)

  def handle_event("dissolve_group", %{"group" => group}, socket),
    do: mutate(socket, &Session.dissolve_group(&1, int(group)))

  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_open?, &(not &1))}

  # The list is read when the menu opens rather than on every render: a session started in
  # another tab or by an agent shows up the next time the menu is asked for, and a render
  # that has nothing to do with sessions does not go looking at the disk. A menu opened
  # again opens fresh, so a name the last one refused is not still sitting in the field.
  def handle_event("toggle_session_menu", _params, socket) do
    if socket.assigns.session_menu_open? do
      {:noreply, close_overlays(socket)}
    else
      {:noreply,
       socket
       |> close_overlays()
       |> assign(session_menu_open?: true, sessions: Session.list(), new_session_name: "")}
    end
  end

  def handle_event("close_session_menu", _params, socket), do: {:noreply, close_overlays(socket)}

  # A name that is not a session name is refused here so the reader is told why; the same
  # name would land on the default session anyway, since `mount/3` refuses it too. The
  # rejected name is assigned back, so the field still holds what was typed.
  def handle_event("new_session", %{"name" => name}, socket) when is_binary(name) do
    name = String.trim(name)

    if Disk.valid_name?(name) do
      path = session_path(socket.assigns.grasp_path, name)
      {:noreply, socket |> clear_flash(:error) |> push_navigate(to: path)}
    else
      {:noreply, socket |> assign(new_session_name: name) |> put_flash(:error, Disk.name_rule())}
    end
  end

  # The name arrives from the page, so it is checked the way `mount/3` checks the one in the
  # URL: a name no session could carry addresses no file and no process, and deleting under
  # it would broadcast to a topic nothing is listening on.
  def handle_event("delete_session", %{"name" => name}, socket) when is_binary(name) do
    if Disk.valid_name?(name) do
      :ok = Session.delete(name)
      {:noreply, assign(socket, sessions: Session.list())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_focus", %{"dir" => dir}, socket) when dir in ~w(parent child next prev),
    do: mutate(socket, &Session.move_focus(&1, String.to_existing_atom(dir)))

  def handle_event("close_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close(&1, id))
    end
  end

  def handle_event("close_focused_chain", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close_chain(&1, id))
    end
  end

  def handle_event("collapse_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.toggle_collapse(&1, id))
    end
  end

  def handle_event("chat_toggle", _params, socket) do
    {:noreply, socket |> update(:chat_open?, &(not &1)) |> assign(chat_error: nil)}
  end

  def handle_event("chat_send", %{"prompt" => prompt}, socket) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, ask(socket, trimmed)}
    end
  end

  # A starting prompt is sent as it reads on its button: the reader picked those words, and
  # the agent is being asked the question they saw.
  def handle_event("chat_suggest", %{"prompt" => prompt}, socket) when is_binary(prompt),
    do: {:noreply, ask(socket, prompt)}

  # Retrying sends the last thing the reader asked for, which is what a run that failed
  # before answering was asked.
  def handle_event("chat_retry", _params, socket) do
    case last_prompt(socket.assigns.agent.entries) do
      nil -> {:noreply, socket}
      prompt -> {:noreply, ask(socket, prompt)}
    end
  end

  def handle_event("chat_dequeue", %{"id" => id}, socket) do
    case int(id) do
      nil ->
        {:noreply, socket}

      queued_id ->
        :ok = Grasp.Agent.dequeue(socket.assigns.name, queued_id)
        {:noreply, refresh_agent(socket)}
    end
  end

  # An empty pick returns to the configured default; anything the facade does not know is
  # ignored rather than reported, since the select cannot offer it.
  def handle_event("chat_model", %{"model" => model}, socket) when is_binary(model) do
    case Grasp.Agent.set_model(socket.assigns.name, if(model == "", do: nil, else: model)) do
      :ok -> {:noreply, refresh_agent(socket)}
      {:error, :unknown_model} -> {:noreply, socket}
    end
  end

  # Modes the facade does not know are ignored the same way, for the same reason.
  def handle_event("chat_mode", %{"mode" => mode}, socket) when is_binary(mode) do
    case Grasp.Agent.set_mode(socket.assigns.name, mode) do
      :ok -> {:noreply, refresh_agent(socket)}
      {:error, :unknown_mode} -> {:noreply, socket}
    end
  end

  def handle_event("chat_stop", _params, socket) do
    :ok = Grasp.Agent.stop(socket.assigns.name)
    {:noreply, refresh_agent(socket)}
  end

  def handle_event("chat_reset", _params, socket) do
    :ok = Grasp.Agent.reset(socket.assigns.name)
    {:noreply, socket |> assign(chat_error: nil) |> refresh_agent()}
  end

  def handle_event("palette_show", _params, socket),
    do: {:noreply, socket |> close_overlays() |> assign(palette_open?: true, palette_selected: 0)}

  def handle_event("palette_hide", _params, socket), do: {:noreply, reset_palette(socket)}

  def handle_event("palette_search", %{"q" => query}, socket) do
    results =
      case socket.assigns.index do
        nil -> []
        index -> Index.search(index, query, 20)
      end

    {:noreply,
     assign(socket, palette_query: query, palette_results: results, palette_selected: 0)}
  end

  def handle_event("palette_move", %{"delta" => delta}, socket) when delta in [1, -1] do
    last = length(socket.assigns.palette_results) - 1
    selected = (socket.assigns.palette_selected + delta) |> min(last) |> max(0)
    {:noreply, assign(socket, palette_selected: selected)}
  end

  def handle_event("palette_choose", params, socket) do
    case Enum.at(socket.assigns.palette_results, socket.assigns.palette_selected) do
      nil -> {:noreply, socket}
      fun -> open_from_palette(socket, fun["id"], child?(params))
    end
  end

  def handle_event("palette_open", %{"id" => id} = params, socket) when is_binary(id),
    do: open_from_palette(socket, id, child?(params))

  # A range arrives as its two ends in whichever order they were gestured in, and Shift asks
  # the open composer to stretch rather than for a new one. The box keeps the line it was
  # opened at as its anchor, and the range is whatever lies between that anchor and the line
  # just clicked, so stretching upwards moves the range while the box stays where it was
  # written in. A number the function has no line for is dropped rather than opened on: the
  # gutter only ever offers lines the card drew, so anything else is a page asking for a
  # range the code does not have.
  def handle_event(
        "comment_start",
        %{"card" => card, "side" => side, "line" => line} = params,
        socket
      )
      when side in ~w(new old) do
    card_id = int(card)
    record = record_for(socket, card_id)
    anchor = shift_anchor(socket.assigns.composing, card_id, side, params["shift"])

    range =
      [int(line), int(params["end_line"]), anchor]
      |> Enum.filter(&commentable?(record, side, &1))

    case {card_id, range} do
      {card_id, [_ | _]} when is_integer(card_id) ->
        {:noreply,
         socket
         |> close_overlays()
         |> assign(composing: composing(card_id, side, range, anchor))}

      _garbage ->
        {:noreply, socket}
    end
  end

  # A reply is anchored where its thread is: the composer renders inside the thread, and the
  # side and line it carries are the thread's, so a submit says what it answers either way.
  def handle_event("comment_reply", %{"card" => card, "id" => id}, socket) do
    with card_id when is_integer(card_id) <- int(card),
         thread_id when is_integer(thread_id) <- int(id),
         {:ok, thread} <- Grasp.Comments.fetch(thread_id) do
      composing = %{
        card: card_id,
        side: thread.side,
        anchor: thread.line,
        line: thread.line,
        end_line: thread.end_line,
        reply_to: thread.id,
        edit: nil
      }

      {:noreply, socket |> close_overlays() |> assign(composing: composing)}
    else
      _unknown_thread -> {:noreply, socket}
    end
  end

  # An edit is the one box open on the canvas like any other, so opening it closes whatever
  # else was open. It is drawn in place of the entry it rewrites and names that entry — the
  # thread's opening comment when no reply is given — rather than a line, since the text it
  # replaces is already anchored.
  def handle_event("comment_edit", %{"card" => card, "id" => id} = params, socket) do
    with card_id when is_integer(card_id) <- int(card),
         thread_id when is_integer(thread_id) <- int(id),
         {:ok, thread} <- Grasp.Comments.fetch(thread_id) do
      composing = %{
        card: card_id,
        side: thread.side,
        anchor: thread.line,
        line: thread.line,
        end_line: thread.end_line,
        reply_to: nil,
        edit: %{thread: thread.id, reply: int(params["reply"])}
      }

      {:noreply, socket |> close_overlays() |> assign(composing: composing)}
    else
      _unknown_thread -> {:noreply, socket}
    end
  end

  # The sidebar's row names a thread rather than a card, so the card it belongs on is opened
  # first and the line the thread anchors to is lit up on it. An old-side or outdated anchor
  # has no line in the card's own numbering to light, and a thread whose function has left
  # the index has no card at all, so both stop at what they can do.
  def handle_event("open_comment", %{"id" => id}, socket) do
    with thread_id when is_integer(thread_id) <- int(id),
         {:ok, thread} <- Grasp.Comments.fetch(thread_id),
         %Index{} = index <- socket.assigns.index,
         {:ok, record} <- Index.fetch_function(index, thread.function_id) do
      socket = clear_selection(socket)
      name = socket.assigns.name
      forest = Session.open_root(name, record["id"])

      forest =
        case {Grasp.Comments.Anchor.place(thread, record), Forest.find(forest, record["id"])} do
          {{:new, line}, card_id} when is_integer(card_id) ->
            Session.set_highlight(name, card_id, %{"lines" => [line, line]})

          _no_line_of_its_own ->
            forest
        end

      {:noreply, socket |> assign(forest: forest) |> prune_to_forest(forest)}
    else
      _nothing_to_open -> {:noreply, socket}
    end
  end

  def handle_event("comment_cancel", _params, socket),
    do: {:noreply, assign(socket, composing: nil)}

  # A blank body is the Comment button pressed on an empty box, which says nothing about
  # wanting the box closed, so the draft and the anchor both stay where they are.
  def handle_event("comment_save", %{"body" => body}, socket) when is_binary(body) do
    if String.trim(body) == "" do
      {:noreply, socket}
    else
      write_comment(socket, body)
      {:noreply, socket |> assign(composing: nil) |> refresh_comments()}
    end
  end

  def handle_event("comment_resolve", %{"id" => id, "resolved" => resolved}, socket)
      when resolved in ~w(true false) do
    case int(id) do
      nil ->
        {:noreply, socket}

      thread_id ->
        Grasp.Comments.set_resolved(thread_id, resolved == "true")

        {:noreply,
         socket
         |> assign(expanded_threads: MapSet.delete(socket.assigns.expanded_threads, thread_id))
         |> refresh_comments()}
    end
  end

  def handle_event("comment_delete", %{"id" => id} = params, socket) do
    case {int(id), int(params["reply"])} do
      {nil, _reply} ->
        {:noreply, socket}

      # The reply box lives inside the thread it answers, so deleting the thread takes the
      # box with it and the anchor it was open at now names nothing.
      {thread_id, nil} ->
        Grasp.Comments.delete(thread_id)
        {:noreply, socket |> forget_reply_box(thread_id) |> refresh_comments()}

      {thread_id, reply_id} ->
        Grasp.Comments.delete_reply(thread_id, reply_id)

        socket =
          case socket.assigns.composing do
            %{edit: %{thread: ^thread_id, reply: ^reply_id}} -> assign(socket, composing: nil)
            _elsewhere -> socket
          end

        {:noreply, refresh_comments(socket)}
    end
  end

  # Only a resolved thread is ever collapsed, so the set holds the few the reader has asked
  # to see again rather than the state of every thread on the canvas.
  def handle_event("toggle_thread", %{"id" => id}, socket) do
    case int(id) do
      nil ->
        {:noreply, socket}

      thread_id ->
        expanded = socket.assigns.expanded_threads

        toggled =
          if MapSet.member?(expanded, thread_id),
            do: MapSet.delete(expanded, thread_id),
            else: MapSet.put(expanded, thread_id)

        {:noreply, assign(socket, expanded_threads: toggled)}
    end
  end

  # Events are addressed by name and card id from the DOM, so a stale tab or a hand-made
  # message must be dropped rather than take the whole page down with it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A prompt sent while a run is live is queued rather than refused, and the panel draws the
  # queue from the same view, so both answers land the same way.
  defp ask(socket, prompt) do
    case Grasp.Agent.send_prompt(socket.assigns.name, prompt, mcp_url: socket.assigns.mcp_url) do
      sent when sent in [:ok, {:ok, :queued}] ->
        socket |> assign(chat_error: nil) |> refresh_agent()

      {:error, :no_command} ->
        assign(socket, chat_error: @no_command)
    end
  end

  defp last_prompt(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: :user, text: text} -> text
      _other -> nil
    end)
  end

  # The prompts an empty transcript offers, in the order they are worth asking: what this
  # branch changed, the card the reader is looking at, the threads waiting to be published,
  # and the first route in the index. Each is a whole question, because clicking it sends
  # exactly the words on the button.
  defp chat_suggestions(%{entries: [], running?: false}, index, forest, comments) do
    Enum.concat([
      if(pull_request?(index), do: ["Show me what changed"], else: []),
      case focused_function(forest) do
        nil -> []
        function_id -> ["Explain #{function_id}"]
      end,
      if(comments == %{}, do: [], else: ["Publish the comments"]),
      case first_route(index) do
        nil -> []
        label -> ["Where does #{label} lead?"]
      end
    ])
  end

  defp chat_suggestions(_agent, _index, _forest, _comments), do: []

  defp pull_request?(%Index{git: %{"base_ref" => base_ref}}) when is_binary(base_ref), do: true
  defp pull_request?(%Index{} = index), do: Index.changed_functions(index) != []
  defp pull_request?(nil), do: false

  defp focused_function(%Forest{focus: focus} = forest) when is_integer(focus) do
    case Map.fetch(forest.cards, focus) do
      {:ok, card} -> card.function_id
      :error -> nil
    end
  end

  defp focused_function(%Forest{}), do: nil

  defp first_route(%Index{} = index) do
    case Enum.find(Index.entry_points(index), &(&1["kind"] == "route")) do
      %{"label" => label} when is_binary(label) -> label
      _no_route -> nil
    end
  end

  defp first_route(nil), do: nil

  defp refresh_agent(socket), do: assign(socket, agent: Grasp.Agent.get(socket.assigns.name))

  # The store broadcasts every change to this process as well, so re-reading here only makes
  # the write visible before the broadcast arrives — which is what a disconnected view, and a
  # test asserting on the very next render, depend on.
  defp refresh_comments(socket), do: assign(socket, comments: Grasp.Comments.by_function())

  # The composer a Shift click stretches: one open on the same card and side for a new
  # thread. What it stretches from is the line the box was opened at, which is the one end of
  # the range the click does not move.
  defp shift_anchor(
         %{card: card_id, side: side, anchor: anchor, reply_to: nil, edit: nil},
         card_id,
         side,
         shift
       )
       when shift in [true, "true"],
       do: anchor

  defp shift_anchor(_composing, _card_id, _side, _shift), do: nil

  # A composer writes a range as its two ends, and a range of one line as no end at all, so
  # the thread it opens is spelled the one way the store accepts. A box being stretched keeps
  # the anchor it was opened at; a new one, and one whose anchor the record no longer has,
  # takes the first line of the range it opens over.
  defp composing(card_id, side, range, anchor) do
    first = Enum.min(range)
    last = Enum.max(range)

    %{
      card: card_id,
      side: side,
      anchor: if(anchor in range, do: anchor, else: first),
      line: first,
      end_line: if(last > first, do: last),
      reply_to: nil,
      edit: nil
    }
  end

  # A line of the record the card is drawing, on the side the gesture named. A card whose
  # function has left the index has no line to write on at all.
  defp commentable?(nil, _side, _line), do: false

  defp commentable?(record, side, line) when is_integer(line) and line > 0,
    do: Grasp.MCP.Comments.check_line(record, side, line) == :ok

  defp commentable?(_record, _side, _line), do: false

  defp record_for(socket, card_id) do
    with function_id when is_binary(function_id) <- function_id(socket, card_id),
         %Index{} = index <- socket.assigns.index,
         {:ok, record} <- Index.fetch_function(index, function_id) do
      record
    else
      _no_record -> nil
    end
  end

  defp forget_reply_box(socket, thread_id) do
    case socket.assigns.composing do
      %{reply_to: ^thread_id} -> assign(socket, composing: nil)
      %{edit: %{thread: ^thread_id}} -> assign(socket, composing: nil)
      _elsewhere -> socket
    end
  end

  # A new thread records the line as its author read it: the snippet comes from the record
  # the card is drawing, which is what lets the anchor find the line again after it moves.
  # Where the comment belongs is the view's own record of the open box rather than the form's
  # fields: the anchor and the range were gestured on the gutter, and a submit that carried
  # them back could disagree with the box the reader was typing in.
  defp write_comment(socket, body) do
    case socket.assigns.composing do
      %{edit: %{thread: thread_id, reply: reply_id}} ->
        Grasp.Comments.edit(thread_id, reply_id, body)

      %{reply_to: nil} = composing ->
        open_thread(socket, body, composing)

      %{reply_to: reply_to} ->
        Grasp.Comments.reply(reply_to, %{body: body, author: "human"})

      _closed ->
        :ok
    end
  end

  defp open_thread(socket, body, composing) do
    with function_id when is_binary(function_id) <- function_id(socket, composing.card),
         %Index{} = index <- socket.assigns.index,
         {:ok, record} <- Index.fetch_function(index, function_id) do
      Grasp.Comments.add(%{
        function_id: function_id,
        side: composing.side,
        line: composing.line,
        end_line: composing.end_line,
        body: body,
        author: "human",
        snippet: Grasp.Comments.snippet(record, composing.side, composing.line)
      })
    else
      _garbage -> :ok
    end
  end

  # Whatever the last click opened stands alone: the callers menu, the rename form, the
  # comment composer and the session menu are closed together so that opening one is what
  # closes the other. Escape closes the session menu through here as well.
  # The error the page reports is one of these overlays' own — a name the session menu
  # refused — so it goes when the gesture that raised it is over.
  defp close_overlays(socket) do
    socket
    |> clear_flash(:error)
    |> assign(
      callers_open: nil,
      renaming_group: nil,
      composing: nil,
      session_menu_open?: false
    )
  end

  defp clear_selection(socket), do: assign(socket, selected: MapSet.new())

  # A card off the canvas takes this tab's gestures about it with it, however it left: this
  # tab's own close, another tab's, or an agent's over MCP. Ids are never reused, so nothing
  # is ever put back in by accident.
  defp prune_to_forest(socket, %Forest{} = forest) do
    on_canvas? = &Map.has_key?(forest.cards, &1)

    assign(socket,
      selected: MapSet.filter(socket.assigns.selected, on_canvas?),
      expanded_folds:
        MapSet.filter(socket.assigns.expanded_folds, fn {id, _from} -> on_canvas?.(id) end)
    )
  end

  # The callers menu is addressed by the id of the card it hangs off, so one left open on a
  # card that is closing would have nothing to render against.
  defp forget_callers_menu(socket, id) do
    callers = socket.assigns.callers_open
    assign(socket, callers_open: if(callers == id, do: nil, else: callers))
  end

  # What ⌘G and ⇧⌘G act on. An empty selection means the card in hand rather than nothing at
  # all, so the chords work before anything has been picked out. The ids are sorted, so the
  # card a new frame focuses is the first of them to have been opened rather than whichever
  # was picked out last.
  defp grouping_ids(socket) do
    case Enum.sort(socket.assigns.selected) do
      [] -> List.wrap(socket.assigns.forest.focus)
      ids -> ids
    end
  end

  # A drag of a card nobody selected moves that card alone, even while others are selected:
  # the pointer is the more recent statement of what is being moved.
  defp dragged_set(socket, id) do
    if MapSet.member?(socket.assigns.selected, id),
      do: Enum.sort(MapSet.put(socket.assigns.selected, id)),
      else: [id]
  end

  # Only a modified function has two sides to swap between, so the keyboard passes over a
  # card that has nothing to compare rather than putting it in a view that would render the
  # source back unchanged.
  defp toggle_view(socket, card_id) do
    if diffable?(socket, card_id),
      do: mutate(socket, &Session.toggle_view(&1, card_id)),
      else: {:noreply, socket}
  end

  # The length that decides what `:auto` folds is the function's own, so the card whose
  # context is being swapped has to be found before the session is asked to swap it.
  defp toggle_context(socket, card_id) do
    case record(socket, card_id) do
      nil ->
        {:noreply, socket}

      record ->
        loc = record["source"] |> to_string() |> String.split("\n") |> length()
        mutate(socket, &Session.toggle_context(&1, card_id, loc))
    end
  end

  defp diffable?(socket, card_id) do
    case record(socket, card_id) do
      nil -> false
      record -> Grasp.Diff.diffable?(record)
    end
  end

  defp record(socket, card_id) do
    with %Index{} = index <- socket.assigns.index,
         %{function_id: function_id} <- Forest.card(socket.assigns.forest, card_id),
         {:ok, record} <- Index.fetch_function(index, function_id) do
      record
    else
      _no_record -> nil
    end
  end

  # The form submit carries the query rather than a child flag, so a missing key is a plain
  # root open; the hook sends the boolean and the result buttons the string.
  defp child?(params), do: params["child"] in [true, "true"]

  defp open_from_palette(socket, id, child?) do
    socket = clear_selection(socket)
    name = socket.assigns.name
    id = canonical(socket, id)

    forest =
      case {child?, socket.assigns.forest.focus} do
        {true, focus} when is_integer(focus) ->
          Session.open_child(name, focus, id, call_target(socket, function_id(socket, focus), id))

        _ ->
          Session.open_root(name, id)
      end

    {:noreply, socket |> assign(forest: forest) |> reset_palette()}
  end

  # The edge an opened card gains is identified by the spelling the caller's own source uses,
  # which is not the callee's id whenever the call goes through a default-argument alias. The
  # palette opens whatever the user picked under whatever has focus, so the two need not be
  # joined by a call at all; nil then leaves the graph to fall back to the callee's id, and the
  # edge simply has no call site in the caller's body to paint.
  defp call_target(socket, caller_function_id, callee_function_id)
       when is_binary(caller_function_id) and is_binary(callee_function_id) do
    case socket.assigns.index do
      %Index{} = index -> Links.call_target(index, caller_function_id, callee_function_id)
      _no_index -> nil
    end
  end

  defp call_target(_socket, _caller_function_id, _callee_function_id), do: nil

  defp function_id(socket, card_id) do
    case Forest.card(socket.assigns.forest, card_id) do
      %{function_id: function_id} -> function_id
      _no_card -> nil
    end
  end

  # A call written against a default-argument alias (`greet/1` for `greet/2`) names a
  # function the index stores under its defining arity; opening the raw id instead would
  # give the same function a second card that no call span can ever mark as open.
  defp canonical(socket, id) do
    case socket.assigns.index && Index.fetch_function(socket.assigns.index, id) do
      {:ok, record} -> record["id"]
      _ -> id
    end
  end

  defp reset_palette(socket) do
    assign(socket,
      palette_open?: false,
      palette_query: "",
      palette_results: [],
      palette_selected: 0
    )
  end

  # The session broadcasts the new forest to every subscriber including this process, so
  # the returned forest is assigned here only to make the change visible before the
  # broadcast arrives (which matters in tests, where the view may not be connected).
  defp mutate(socket, fun) do
    forest = fun.(socket.assigns.name)
    {:noreply, socket |> assign(forest: forest) |> prune_to_forest(forest)}
  end

  # What a PR-mode review is against, as the two ends of the comparison. A detached head has
  # no branch name to put on the right of it, and an index built without `--base` has no
  # comparison to name at all.
  defp base_label(%Index{git: %{"base_ref" => base_ref}} = index) when is_binary(base_ref),
    do: base_ref <> "…" <> (index.git["branch"] || "HEAD")

  defp base_label(_index), do: nil

  # Every visible card, flattened out of the sections: the columns are the order a card with
  # no position is placed in, which the node carries as its depth.
  defp nodes(sections) do
    Enum.flat_map(sections, fn section ->
      section.columns
      |> Enum.with_index()
      |> Enum.flat_map(fn {ids, depth} -> Enum.map(ids, &%{id: &1, depth: depth}) end)
    end)
  end

  # A section's cards are spread over its columns, and the count in its header speaks of the
  # cards the reader can see rather than of the columns they happen to fall into.
  defp card_count(%{columns: columns}) do
    case Enum.sum_by(columns, &length/1) do
      1 -> "1 card"
      count -> "#{count} cards"
    end
  end

  # A card id that is not a number is nobody's card, and every session operation is a no-op
  # on an unknown id, so nil carries the garbage through to the same outcome.
  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: nil

  @impl true
  def render(%{index: nil} = assigns) do
    ~H"""
    <main class="app app--empty">
      <h1 class="brand">Grasp</h1>
      <p :if={@index_error} class="empty">
        Could not load {@index_path}: {inspect(@index_error)}
      </p>
      <p :if={!@index_error} class="empty">
        No index at {@index_path} — run <code>mix grasp.index</code>
      </p>
    </main>
    """
  end

  # Only edges between two visible cards mark a call site: a `data-edge-to` naming a card a
  # collapse has taken off the canvas would point the connector layer at nothing. Grouped once
  # here because `Forest.edges/1` walks the whole graph, and every card would otherwise do so.
  def render(assigns) do
    open_calls =
      assigns.forest
      |> Forest.edges()
      |> Enum.group_by(& &1.from, &{&1.target, %{to: &1.to, color: &1.color}})
      |> Map.new(fn {from, calls} -> {from, Map.new(calls)} end)

    sections = Forest.sections(assigns.forest)

    assigns =
      assign(assigns,
        open_calls: open_calls,
        base: base_label(assigns.index),
        sections: sections,
        nodes: nodes(sections)
      )

    ~H"""
    <main
      class={["app", !@sidebar_open? && "app--no-sidebar"]}
      id="app"
      phx-hook="Keys"
      data-sidebar={to_string(@sidebar_open?)}
    >
      <%!-- The page reports one kind of thing this way — a gesture the viewer refused — so the
      message stands until the next gesture closes it or the reader dismisses it. Dismissing
      it is what the element does, so it is a button: it takes focus and answers the keyboard
      rather than the mouse alone. --%>
      <button
        :if={Phoenix.Flash.get(@flash, :error)}
        type="button"
        class="flash"
        role="alert"
        phx-click="lv:clear-flash"
        phx-value-key="error"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </button>
      <aside :if={@sidebar_open?} class="sidebar">
        <h1 class="brand">Grasp</h1>
        <p class="sidebar__project">
          {@index.project["app"]}<span :if={@base} class="sidebar__base">{@base}</span>
        </p>
        <.session_menu
          prefix={@grasp_path}
          name={@name}
          sessions={@sessions}
          open?={@session_menu_open?}
          new_name={@new_session_name}
        />
        <.entry_groups
          index={@index}
          comments={@comments}
          expanded={@expanded_groups}
          expanded_module={@expanded_module}
        />
      </aside>
      <section class="canvas" id="canvas" phx-hook="Canvas">
        <%!-- `data-tip` and `data-key` are what the toolbar's tooltips are drawn from; a
        `title` alongside one would show the browser's own bubble on top of it. --%>
        <div class="toolbar">
          <button
            type="button"
            id="toggle-sidebar"
            phx-click="toggle_sidebar"
            data-tip="Sidebar"
            data-key="⌘M"
          >
            sidebar
          </button>
          <span class="toolbar__sep" aria-hidden="true"></span>
          <button type="button" id="zoom-out" data-tip="Zoom out" data-key="⌘ wheel">−</button>
          <span
            id="zoom-level"
            class="toolbar__zoom"
            phx-update="ignore"
            data-tip="Reset zoom"
            data-key="⌘0"
          >
            100%
          </span>
          <button type="button" id="zoom-in" data-tip="Zoom in" data-key="⌘ wheel">+</button>
          <button type="button" id="zoom-fit" data-tip="Fit all cards" data-key="F">fit</button>
          <span class="toolbar__sep" aria-hidden="true"></span>
          <%!-- The mode is the canvas hook's, written on <body> and on this button, so a patch
          must leave the button alone or it would render a pressed toggle as unpressed. The
          tooltip is the server's and the hook never touches it, so the ignored subtree keeps
          it. --%>
          <button
            type="button"
            id="toggle-signatures"
            phx-update="ignore"
            aria-pressed="false"
            data-tip="Signatures instead of code"
            data-key="S"
          >
            signatures
          </button>
          <%!-- Module clusters are the hook's too, and are drawn until the reader turns them
          off, so the button is rendered pressed and kept out of every patch. --%>
          <button
            type="button"
            id="toggle-modules"
            phx-update="ignore"
            aria-pressed="true"
            data-tip="Module frames"
            data-key="M"
          >
            modules
          </button>
          <button
            type="button"
            id="reset-layout"
            phx-click="reset_layout"
            data-tip="Reset layout"
          >
            reset layout
          </button>
          <button
            type="button"
            id="toggle-chat"
            phx-click="chat_toggle"
            data-tip="Ask the agent"
            data-key="⌘I"
          >
            ask
          </button>
          <%!-- The list it opens is the client's alone, so this button carries no phx-click:
          the Help hook picks the click up from the document. --%>
          <button type="button" id="help-toggle" data-tip="Keys and gestures" data-key="?">
            ?
          </button>
        </div>
        <p :if={@forest.cards == %{}} class="empty">
          Pick a function from the sidebar or press <kbd>⌘K</kbd>.
        </p>
        <.chat_panel
          open?={@chat_open?}
          agent={@agent}
          index={@index}
          error={@chat_error}
          suggestions={chat_suggestions(@agent, @index, @forest, @comments)}
        />
        <div id="stage" class="stage">
          <%!-- A group's frame is measured from the cards inside it and so cannot be a box the
          server renders: the hook owns this layer and fills it on every draw. --%>
          <div id="frames" class="frames" phx-update="ignore" aria-hidden="true"></div>
          <svg id="connectors" class="connectors" phx-update="ignore" aria-hidden="true">
            <%!-- The hook owns the edge paths, but a marker cannot be built from a path string:
            it has to exist in the document before an edge can point at it. The server renders
            one per palette colour, and the ignored subtree keeps them across every patch. --%>
            <defs>
              <marker
                :for={color <- 0..7}
                id={"arrow-#{color}"}
                viewBox="0 0 10 10"
                refX="9"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" class="arrow" data-color={color} />
              </marker>
            </defs>
            <g id="edges"></g>
          </svg>
          <div class="flows">
            <section
              :for={section <- @sections}
              class="flow"
              id={"flow-#{(section.group && section.group.id) || "none"}"}
              data-grouped={section.group != nil}
              data-group={section.group && section.group.id}
            >
              <header :if={section.group} class="flow__title">
                <h3
                  :if={@renaming_group != section.group.id}
                  class={[
                    "flow__title-text",
                    !section.group.title && "flow__title-text--empty"
                  ]}
                  phx-click="edit_group_title"
                  phx-value-group={section.group.id}
                  title="Rename this group"
                >
                  {section.group.title || "Untitled group"}
                </h3>
                <form
                  :if={@renaming_group == section.group.id}
                  class="flow__rename"
                  phx-submit="rename_group"
                >
                  <input type="hidden" name="group" value={section.group.id} />
                  <input
                    type="text"
                    name="title"
                    value={section.group.title}
                    autocomplete="off"
                    aria-label="Group title"
                    autofocus
                    phx-blur="cancel_rename"
                    phx-keydown="cancel_rename"
                    phx-key="Escape"
                  />
                </form>
                <span class="flow__count">{card_count(section)}</span>
                <button
                  type="button"
                  phx-click="dissolve_group"
                  phx-value-group={section.group.id}
                  title="Ungroup"
                >
                  ungroup
                </button>
              </header>
            </section>
          </div>
          <%!-- Every card of every section in one flat layer: a card is where it was put on
          the stage, so nothing about the document order says where it is drawn. --%>
          <div id="nodes" class="nodes">
            <.card_node
              :for={node <- @nodes}
              forest={@forest}
              index={@index}
              card_id={node.id}
              depth={node.depth}
              open_calls={Map.get(@open_calls, node.id, %{})}
              editor={@editor}
              callers_open={@callers_open}
              selected={MapSet.member?(@selected, node.id)}
              comments={@comments}
              composing={@composing}
              expanded_threads={@expanded_threads}
              expanded_folds={@expanded_folds}
            />
          </div>
        </div>
      </section>
      <.palette
        open?={@palette_open?}
        query={@palette_query}
        results={@palette_results}
        selected={@palette_selected}
      />
      <.help_dialog />
    </main>
    """
  end
end
