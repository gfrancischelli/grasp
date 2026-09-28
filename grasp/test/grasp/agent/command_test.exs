defmodule Grasp.Agent.CommandTest do
  use ExUnit.Case, async: true

  alias Grasp.Agent.Command
  alias Grasp.IndexStore

  @opts [
    command: "claude",
    session: "s1",
    mcp_url: "http://127.0.0.1:4040/mcp",
    resume: nil,
    model: nil
  ]

  test "build/2 puts the prompt, the stream format and the MCP config first" do
    assert {"claude", argv} = Command.build("hi", @opts)

    assert [
             "-p",
             "hi",
             "--output-format",
             "stream-json",
             "--verbose",
             "--include-partial-messages",
             "--strict-mcp-config",
             "--mcp-config",
             json | rest
           ] = argv

    assert Jason.decode!(json)["mcpServers"]["grasp"] == %{
             "type" => "http",
             "url" => "http://127.0.0.1:4040/mcp"
           }

    assert ["--tools", "Read,Grep,Glob" | rest] = rest
    assert ["--allowedTools", "mcp__grasp,Read,Grep,Glob" | rest] = rest
    assert ["--max-turns", "60" | rest] = rest
    assert ["--append-system-prompt", system_prompt] = rest
    assert system_prompt =~ ~s(session: "s1")
    assert "--include-partial-messages" in argv
    refute "--resume" in argv
    refute "--model" in argv
  end

  test "build/2 in edit mode hands the CLI the editing tools and the reindex command" do
    {"claude", argv} =
      Command.build("fix it", Keyword.merge(@opts, mode: "edit", reindex: "mix grasp.index"))

    assert ["--tools", "Read,Grep,Glob,Edit,Write,Bash" | rest] = Enum.drop(argv, 9)

    assert [
             "--allowedTools",
             "mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*),Bash(git fetch:*),Bash(gh pr view:*)"
             | _rest
           ] = rest

    assert List.last(argv) =~ "You may edit files under the project root and run mix."
  end

  test "build/2 appends resume and model when they are set" do
    {"claude", argv} = Command.build("hi", Keyword.merge(@opts, resume: "abc", model: "opus"))

    assert Enum.take(argv, -4) == ["--resume", "abc", "--model", "opus"]
  end

  test "build/2 appends the model alone when there is nothing to resume" do
    {"claude", argv} = Command.build("hi", Keyword.put(@opts, :model, "opus"))

    assert Enum.take(argv, -2) == ["--model", "opus"]
    refute "--resume" in argv
  end

  test "system_prompt/3 names the session the agent must pass to every card tool" do
    prompt = Command.system_prompt("s1", "read", "mix grasp.index")

    assert prompt =~ "Grasp"
    assert prompt =~ ~s(The Grasp viewer session you control is "s1".)
    assert prompt =~ "set_cards"
  end

  test "system_prompt/3 names the session the agent must pass to every comment tool" do
    for mode <- ~w(read edit) do
      prompt = Command.system_prompt("s1", mode, "mix grasp.index")

      assert prompt =~
               ~s(Pass session: "s1" to every comment tool as well: list_comments, add_comment, ) <>
                 ~s(reply_comment, resolve_comment, publish_comments, and get_function)
    end
  end

  test "system_prompt/3 asks for a group per flow when several flows are wanted" do
    prompt = Command.system_prompt("s1", "read", "mix grasp.index")

    assert prompt =~ "When the user asks for several flows at once, give each flow its own group"
    assert prompt =~ "`group` field"
  end

  test "system_prompt/3 sends a question about a change through list_changes" do
    prompt = Command.system_prompt("s1", "read", "mix grasp.index")

    assert prompt =~ "list_changes"
    assert prompt =~ "find_paths"
  end

  test "system_prompt/3 explains what a comment is and how a thread is closed, in both modes" do
    for mode <- ["read", "edit"] do
      prompt = Command.system_prompt("s1", mode, "mix grasp.index")

      assert prompt =~ "the way review comments are left on a pull request"
      assert prompt =~ "list_comments"
      assert prompt =~ "reply_comment"
      assert prompt =~ "resolve_comment"
      assert prompt =~ "add_comment"
      assert prompt =~ "publish_comments"
      assert prompt =~ "which went as file comments"
    end
  end

  test "system_prompt/3 refuses edits in read mode and sends the user to edit mode" do
    prompt = Command.system_prompt("s1", "read", "mix grasp.index")

    assert prompt =~ "Do not edit files or run commands — this chat is in read mode."
    assert prompt =~ "tell the user to switch the chat to edit mode"
    refute prompt =~ "You may edit files"
  end

  test "system_prompt/3 in edit mode asks for a format, a rebuilt index and fresh cards" do
    prompt = Command.system_prompt("s1", "edit", "mix grasp.index --base main")

    assert prompt =~ "You may edit files under the project root and run mix."
    assert prompt =~ "run `mix format` on the files you touched"
    assert prompt =~ "rebuild the index from the project root with `mix grasp.index --base main`"
    assert prompt =~ "so the diagram shows the code as it now is"
    refute prompt =~ "this chat is in read mode"
  end

  test "system_prompt/3 in edit mode opens a pull request through the worktree task" do
    prompt = Command.system_prompt("s1", "edit", "mix grasp.index --base main")

    assert prompt =~ "When the user asks you to open, review or look at a pull request by number:"
    home = Grasp.Application.home()

    assert prompt =~ "Run `mix grasp.pr N --root #{home}`"
    assert prompt =~ "mix grasp.pr N --close --root #{home}"
    assert prompt =~ ".grasp/worktrees/pr-N"

    assert prompt =~
             "The user's own working tree is untouched, so never check a branch out yourself."

    assert prompt =~ "reload_index"
    assert prompt =~ "list_changes"

    assert prompt =~
             "mix grasp.index --base origin/<base> --out #{IndexStore.path()}"

    assert prompt =~ "Reach comments through the comment tools only."
    refute prompt =~ "comments.json"
    refute prompt =~ "gh pr checkout"
    refute prompt =~ "git switch"
  end

  test "system_prompt/3 in read mode sends a pull request to edit mode instead of opening it" do
    prompt = Command.system_prompt("s1", "read", "mix grasp.index")

    assert prompt =~ "When the user asks you to open, review or look at a pull request by number:"

    assert prompt =~
             "the chat has to be switched to edit mode before a pull request can be opened in a worktree"

    assert prompt =~ "offer to review whatever branch is already indexed"
    refute prompt =~ "mix grasp.pr"
    refute prompt =~ "gh pr checkout"
  end

  test "reindex_command/2 repeats the base ref the index was built against" do
    index = IndexStore.get()
    assert index.git["base_ref"] == "main"

    assert Command.reindex_command(index, Path.join(index.project["root"], ".grasp/index.json")) ==
             "mix grasp.index --base main"
  end

  test "reindex_command/2 names an index written anywhere but the default path" do
    index = IndexStore.get()
    watched = IndexStore.path()

    assert Command.reindex_command(index, watched) ==
             "mix grasp.index --base main --out #{watched}"
  end

  test "reindex_command/2 writes the out path relative to the project root" do
    index = IndexStore.get()

    assert Command.reindex_command(index, "/tmp/sample_app/tmp/index.json") ==
             "mix grasp.index --base main --out tmp/index.json"
  end

  test "reindex_command/2 without an index is the bare task" do
    assert Command.reindex_command(nil, "/tmp/sample_app/.grasp/index.json") == "mix grasp.index"
  end

  test "mcp_url/0 points at the configured endpoint port" do
    assert Command.mcp_url() == "http://127.0.0.1:4041/mcp"
  end

  test "cwd/0 falls back to the current directory when the indexed root is gone" do
    assert File.dir?("/tmp/sample_app") == false, "the fixture root must not exist"
    assert Command.cwd() == File.cwd!()
  end
end
