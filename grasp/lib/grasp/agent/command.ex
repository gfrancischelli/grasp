defmodule Grasp.Agent.Command do
  @moduledoc """
  Builds the argv that runs the Claude Code CLI headless against this viewer.

  The CLI is asked for `stream-json` on stdout so the runner can render a transcript as it
  arrives, with `--include-partial-messages` so an answer arrives as text deltas and the
  panel reads word by word rather than a paragraph at a time. It is pointed with an inline
  `--mcp-config` at the `/mcp` endpoint Grasp serves
  under its mount prefix — the caller supplies that URL, since only it knows where the host
  mounted Grasp. `--strict-mcp-config` keeps the developer's own `.mcp.json` out of the
  run, and the tool allowlist follows the chat's mode. In `read` mode it is the grasp tools
  plus `Read`, `Grep` and `Glob`, with nothing that writes files or runs commands. In `edit`
  mode it also carries `Edit`, `Write` and a `Bash` narrowed to `mix`, to the read-only git
  commands, to `git fetch` and to `gh pr view`, so the agent can act on a review comment,
  rebuild the index and read a pull request, and still cannot reach for an arbitrary shell
  command. Nothing in the allowlist changes the branch the reader has checked out:
  `mix grasp.pr` puts a pull request in a worktree of its own, and the git work happens
  inside the task rather than under the agent's hand.

  The system prompt names the viewer session the agent is driving; every grasp card tool
  takes that session, so an agent that forgets it would arrange cards on a canvas nobody is
  looking at, and every comment tool takes it too, since a thread belongs to the session it
  was written in and another session's threads are another review's. It also tells the
  agent that the canvas is a graph: a function reached from two callers is one card with an
  edge from each, so the same key is reused rather than the function being described twice,
  and that a question about a change starts from the list of changed functions rather than
  from a search. Several flows asked for at once become
  one group per flow, so each is framed and titled on the canvas instead of running into
  its neighbour. Publishing the comments to the pull request is named in both modes: the
  tool posts them through `gh`, so it needs nothing the agent's own tools grant. A pull
  request asked for by number has its own recipe — `mix grasp.pr N`, reload the index it
  wrote, then lay the change out — which `edit` mode spells out step by step and `read`
  mode answers with the one sentence that sends the user to the mode that can run it. It closes on the mode: what
  `read` refuses, and what `edit` owes the canvas after an edit — a format, a rebuilt index,
  and cards laid out over the code as it now is.
  """

  alias Grasp.Index
  alias Grasp.IndexStore

  @default_port 4040
  @max_turns "60"
  @read_tools "Read,Grep,Glob"
  @read_allowed_tools "mcp__grasp,Read,Grep,Glob"
  @edit_tools "Read,Grep,Glob,Edit,Write,Bash"
  @edit_allowed_tools "mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*),Bash(git fetch:*),Bash(gh pr view:*)"

  @type option ::
          {:command, String.t()}
          | {:session, String.t()}
          | {:mcp_url, String.t()}
          | {:resume, String.t() | nil}
          | {:model, String.t() | nil}
          | {:mode, String.t()}
          | {:reindex, String.t()}

  @doc """
  The command and argv that run `prompt` for one turn of the conversation.

  `:resume` continues the CLI session of a previous run, so the agent keeps the context it
  built up; `:model` overrides the CLI's default model. `:mode` is `"read"` (the default) or
  `"edit"`, and picks both the tools the CLI is given and the closing paragraph of the
  system prompt; `:reindex` is the index-rebuilding command that paragraph spells out, as
  `reindex_command/2` writes it.
  """
  @spec build(String.t(), [option()]) :: {String.t(), [String.t()]}
  def build(prompt, opts) do
    session = Keyword.fetch!(opts, :session)
    mcp_url = Keyword.fetch!(opts, :mcp_url)
    mode = Keyword.get(opts, :mode) || "read"
    reindex = Keyword.get(opts, :reindex) || reindex_command(nil, nil)

    argv =
      [
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--strict-mcp-config",
        "--mcp-config",
        mcp_config(mcp_url),
        "--tools",
        tools(mode),
        "--allowedTools",
        allowed_tools(mode),
        "--max-turns",
        @max_turns,
        "--append-system-prompt",
        system_prompt(session, mode, reindex)
      ] ++
        flag("--resume", opts[:resume]) ++ flag("--model", opts[:model])

    {Keyword.fetch!(opts, :command), argv}
  end

  @doc """
  The instructions the agent runs under, naming the viewer session it drives.

  `mode` is `"read"` or `"edit"`; `reindex` is the command the edit-mode closing tells the
  agent to rebuild the index with.
  """
  @spec system_prompt(String.t(), String.t(), String.t()) :: String.t()
  def system_prompt(session, mode, reindex) do
    """
    You are the review assistant inside Grasp, a call-chain code review tool. The user is looking at a canvas of function cards; your job is to arrange those cards so a flow is easy to read, and to explain briefly.

    The Grasp viewer session you control is "#{session}". Pass session: "#{session}" to every grasp card tool. Pass session: "#{session}" to every comment tool as well: list_comments, add_comment, reply_comment, resolve_comment, publish_comments, and get_function when you want the comments on the function. A comment belongs to the session it was written in, so these tools see only this session's threads.

    Work like this:
    1. Discover with the grasp read tools: search_functions, get_function, get_callers, get_callees, list_entry_points, find_paths (with only `to` it walks callers back to entry points such as controller actions, LiveView callbacks and Oban workers). For questions about what a change does, start from list_changes and trace each changed function to its entry points with find_paths. For questions about tests, tests_for lists the tests that reach a function, nearest first with the hops between them, and untested_changes lists the changed functions no test reaches.
    2. Answer with set_cards: one call that lays out the whole flow, roots at the entry points, each callee under the function that calls it, in call order. The same function reached from two callers is one card with two edges — reuse the key. Add a highlight on a card when one call or line range is the point of interest. When the user asks for several flows at once, give each flow its own group: put the flow's name in the `group` field of every card that belongs to it, so the canvas draws each flow in its own titled frame.
    3. Reply in a few sentences: what the flow does and where to look first. The cards are the answer; do not paste source code. If a function is not in the index, say so.

    The reviewer leaves comments on lines of the cards, the way review comments are left on a pull request. list_comments returns the open ones: the function each thread sits on, the line and the text of that line, the body and the replies. When you are asked to address, answer or handle the comments, take them one at a time — read what the thread points at with get_function or Read, act on what it asks, then reply_comment with one or two sentences on what you did and resolve_comment to close it. add_comment leaves a remark of your own on a line worth the reviewer's attention.

    When asked to publish, post or send the comments to the pull request, call publish_comments — with the number when the request names one — and report from its answer which threads went on their line, which went as file comments because GitHub's diff does not show that line, and any that failed. It skips threads it has already published.

    #{pull_request(mode, reindex)}

    #{closing(mode, reindex)}
    """
    |> String.trim_trailing()
  end

  @doc """
  The command that rebuilds `index` from the project root, as the edit-mode prompt spells
  it out.

  The base ref the index was built against is repeated so the rebuilt index still knows
  which functions the branch changed, and `--out` is added whenever the viewer watches a
  path other than the default `.grasp/index.json` under the root — a rebuild that wrote
  somewhere else would leave the viewer showing the code as it read before the edit.
  """
  @spec reindex_command(Index.t() | nil, String.t() | nil) :: String.t()
  def reindex_command(index, watched_path)

  def reindex_command(nil, _watched_path), do: "mix grasp.index"

  def reindex_command(%Index{} = index, watched_path) do
    base =
      case index.git["base_ref"] do
        ref when is_binary(ref) -> " --base #{ref}"
        _no_base -> ""
      end

    "mix grasp.index" <> base <> out(index.project["root"], watched_path)
  end

  @doc """
  The URL of the standalone viewer's MCP endpoint, on the loopback address it serves.

  It is the address to use when nothing else names one — a run started outside a request,
  where the host's own scheme, port and mount prefix are not known.
  """
  @spec mcp_url() :: String.t()
  def mcp_url do
    # `http: false` is a legal endpoint setting for a node that only runs the MCP client side.
    port =
      case Application.get_env(:grasp, GraspWeb.Endpoint, [])[:http] do
        http when is_list(http) -> Keyword.get(http, :port, @default_port)
        _not_serving -> @default_port
      end

    "http://127.0.0.1:#{port}/mcp"
  end

  @doc """
  The directory the CLI runs in: the root of the indexed project, so `Read` and `Grep`
  resolve the paths the index records, or the viewer's own directory when that root is
  not on this machine.
  """
  @spec cwd() :: String.t()
  def cwd do
    index = IndexStore.get()
    root = index && index.project["root"]

    if is_binary(root) and File.dir?(root), do: root, else: File.cwd!()
  end

  defp tools("edit"), do: @edit_tools
  defp tools(_read), do: @read_tools

  defp allowed_tools("edit"), do: @edit_allowed_tools
  defp allowed_tools(_read), do: @read_allowed_tools

  defp pull_request("edit", _reindex) do
    home = Grasp.Application.home() || File.cwd!()
    index = watched_index(home)

    """
    When the user asks you to open, review or look at a pull request by number:
    1. Run `mix grasp.pr N --root #{home}`. The `--root` is the directory Grasp was started in, and it is what makes the command work from wherever you are — once a pull request is open you are inside the tree being reviewed, and the task must not work on that one. It reads the pull request with `gh`, fetches its base and head branches, checks the head out in a worktree of its own under `.grasp/worktrees/pr-N`, and builds the index of that worktree against the pull request's base, writing it to the index file the viewer watches. The user's own working tree is untouched, so never check a branch out yourself. The task prints the worktree, the branches and the pull request's title; if it fails, report what it printed and stop — if it stopped because the worktree holds an edit that a move to the new head would overwrite, say so and offer `mix grasp.pr N --close --root #{home}`, which throws that edit away.
    2. Call reload_index, so what you read next is the index the task wrote rather than the one it replaced.
    3. Call list_changes, trace each changed function back to its entry points with find_paths, then call set_cards with the roots at the entry points and one group per flow, each group titled after what that flow does. Reply in two sentences that name the pull request's title.
    The pull request's code is in the worktree, which is what the index now names as its project root: read, edit and format files there, and rebuild from there with `mix grasp.index --base origin/<base> --out #{index}`, which is the file the viewer watches.
    Comments stay with the checkout Grasp was started in, whatever tree is being reviewed, so list_comments can answer with this session's threads left on another branch. Reach comments through the comment tools only.
    """
    |> String.trim_trailing()
  end

  defp pull_request(_read, _reindex) do
    "When the user asks you to open, review or look at a pull request by number: the chat has to be switched to edit mode before a pull request can be opened in a worktree, so say that, and offer to review whatever branch is already indexed."
  end

  # The path the store is watching, which `mix grasp.pr` writes too, so a project that
  # configured one of its own is rebuilt into the file its viewer reads. A prompt built
  # with no store running — nothing loaded an index — falls back to the usual place.
  defp watched_index(home) do
    if Process.whereis(IndexStore),
      do: IndexStore.path(),
      else: Path.join(home, ".grasp/index.json")
  end

  defp closing("edit", reindex) do
    "You may edit files under the project root and run mix. After editing: run `mix format` on the files you touched; rebuild the index from the project root with `#{reindex}` — the viewer reloads the cards from it within a couple of seconds; then arrange the cards again (set_cards or highlight_card) so the diagram shows the code as it now is. Keep every change to what the comments ask for, and say what you changed."
  end

  defp closing(_read, _reindex) do
    "Do not edit files or run commands — this chat is in read mode. When a comment asks for a code change, reply with the change you would make and tell the user to switch the chat to edit mode."
  end

  defp out(_root, nil), do: ""

  defp out(root, watched_path) when is_binary(root) do
    path = Path.expand(watched_path)

    if path == Path.join(Path.expand(root), ".grasp/index.json"),
      do: "",
      else: " --out #{Path.relative_to(path, Path.expand(root))}"
  end

  defp out(_root, watched_path), do: " --out #{Path.expand(watched_path)}"

  defp mcp_config(url),
    do: Jason.encode!(%{"mcpServers" => %{"grasp" => %{"type" => "http", "url" => url}}})

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, value]
end
