defmodule Grasp.MCP.CommentToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"

  # Every comment tool acts for one session, so a test that is not about sessions reads and
  # writes one of this module's own; a call that names a session keeps the one it names.
  @session "mcp-comments"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp run(tool, params), do: run_as(tool, Map.put_new(params, :session, @session))

  defp run_as(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  defp other_session, do: "mcp-other-#{System.unique_integer([:positive])}"

  # The store is shared by the whole suite, so a test recognises its own threads by a body
  # no other test writes and never counts what the listing holds.
  defp unique_body, do: "mcp comment #{System.unique_integer([:positive])}"

  defp add(params), do: json!(run(Tools.AddComment, params))

  defp listed(params), do: json!(run(Tools.ListComments, params))

  defp find(body, id), do: Enum.find(body["comments"], &(&1["id"] == id))

  defp message(%Response{isError: true, content: [%{"text" => text}]}), do: text

  describe "add_comment" do
    test "writes a thread the listing shows anchored on its line" do
      body = unique_body()
      thread = add(%{function_id: @greet, line: 9, body: body})

      assert thread["function_id"] == @greet
      assert thread["author"] == "agent"
      assert thread["side"] == "new"
      assert thread["line"] == 9
      assert thread["status"] == "anchored"
      assert thread["anchored_line"] == 9
      assert thread["file"] == "lib/sample_app/greeter.ex"
      assert thread["snippet"] == "text = Formatter.wrap(name)"
      assert thread["resolved"] == false
      assert thread["replies"] == []
      assert thread["github_url"] == nil

      found = find(listed(%{function_id: @greet}), thread["id"])
      assert found["body"] == body
      assert found["status"] == "anchored"
      assert found["anchored_line"] == 9
    end

    test "stores the thread under the canonical id of the function named" do
      thread = add(%{function_id: "SampleApp.Greeter.greet/1", body: unique_body(), line: 8})

      assert thread["function_id"] == @greet
      assert find(listed(%{function_id: @greet}), thread["id"])
    end

    test "writes on the base version of a modified function" do
      thread = add(%{function_id: @shout, side: "old", line: 3, body: unique_body()})

      assert thread["side"] == "old"
      assert thread["status"] == "anchored"
      assert thread["anchored_line"] == 3
      assert thread["snippet"] == "def shout(text), do: text"
    end

    test "writes a thread over a range of lines and lists it with both ends" do
      body = unique_body()
      thread = add(%{function_id: @greet, line: 6, end_line: 8, body: body})

      assert thread["line"] == 6
      assert thread["end_line"] == 8
      assert thread["status"] == "anchored"
      assert thread["anchored_line"] == 6

      found = find(listed(%{function_id: @greet}), thread["id"])
      assert found["end_line"] == 8
    end

    test "a thread on one line is listed with no end line" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})

      assert thread["end_line"] == nil
      assert find(listed(%{function_id: @greet}), thread["id"])["end_line"] == nil
    end

    test "an end line the range does not run to is an error" do
      response =
        run(Tools.AddComment, %{
          function_id: @greet,
          line: 9,
          end_line: 9,
          body: unique_body()
        })

      assert response.isError
      assert message(response) == "end_line 9 must come after line 9"
    end

    test "an end line outside the function is an error naming the range" do
      response =
        run(Tools.AddComment, %{
          function_id: @greet,
          line: 9,
          end_line: 99,
          body: unique_body()
        })

      assert response.isError
      assert message(response) == "line 99 is outside #{@greet} (lines 6..11)"
    end

    test "a line outside the function is an error naming the range" do
      response = run(Tools.AddComment, %{function_id: @greet, line: 99, body: unique_body()})

      assert response.isError
      assert message(response) == "line 99 is outside #{@greet} (lines 6..11)"
    end

    test "the old side of a function the branch left alone is an error" do
      response =
        run(Tools.AddComment, %{function_id: @greet, side: "old", line: 1, body: unique_body()})

      assert response.isError
      assert message(response) =~ "no base version"
    end

    test "a blank body is an error" do
      response = run(Tools.AddComment, %{function_id: @greet, line: 9, body: "   "})

      assert response.isError
      assert message(response) == "body must not be blank"
    end

    test "a side that is neither new nor old is an error" do
      response =
        run(Tools.AddComment, %{function_id: @greet, side: "both", line: 9, body: unique_body()})

      assert response.isError
      assert message(response) =~ ~s(side must be "new" or "old")
    end

    test "an unknown function is an error" do
      response =
        run(Tools.AddComment, %{function_id: "SampleApp.Nope.nope/0", line: 1, body: "x"})

      assert response.isError
      assert message(response) == "unknown function: SampleApp.Nope.nope/0"
    end
  end

  describe "reply_comment" do
    test "appends the agent's reply to the thread" do
      thread = add(%{function_id: @greet, line: 11, body: unique_body()})
      answer = unique_body()

      replied = json!(run(Tools.ReplyComment, %{comment_id: thread["id"], body: answer}))

      assert replied["id"] == thread["id"]
      assert [%{"author" => "agent", "body" => ^answer}] = replied["replies"]
      assert find(listed(%{function_id: @greet}), thread["id"])["replies"] |> length() == 1
    end

    test "an unknown thread is an error" do
      response = run(Tools.ReplyComment, %{comment_id: 987_654, body: "hello"})

      assert response.isError
      assert message(response) == "unknown comment: 987654"
    end
  end

  describe "resolve_comment" do
    test "takes the thread off the open list and puts it back" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})
      id = thread["id"]

      resolved = json!(run(Tools.ResolveComment, %{comment_id: id}))

      assert resolved["resolved"] == true
      refute find(listed(%{function_id: @greet}), id)
      assert find(listed(%{function_id: @greet, include_resolved: true}), id)["resolved"] == true

      reopened = json!(run(Tools.ResolveComment, %{comment_id: id, resolved: false}))

      assert reopened["resolved"] == false
      assert find(listed(%{function_id: @greet}), id)
    end

    test "an unknown thread is an error" do
      response = run(Tools.ResolveComment, %{comment_id: 987_655})

      assert response.isError
      assert message(response) == "unknown comment: 987655"
    end
  end

  describe "list_comments" do
    test "counts what it returns and sorts by id" do
      first = add(%{function_id: @greet, line: 9, body: unique_body()})
      second = add(%{function_id: @greet, line: 11, body: unique_body()})

      body = listed(%{function_id: @greet})
      ids = Enum.map(body["comments"], & &1["id"])

      assert body["total"] == length(body["comments"])
      assert ids == Enum.sort(ids)

      assert Enum.find_index(ids, &(&1 == first["id"])) <
               Enum.find_index(ids, &(&1 == second["id"]))
    end

    test "a function no index knows holds no comments" do
      assert listed(%{function_id: "SampleApp.Nope.nope/0"}) == %{
               "total" => 0,
               "comments" => []
             }
    end
  end

  describe "get_function" do
    test "carries the function's open threads" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})

      body = json!(run(Tools.GetFunction, %{id: @greet}))
      carried = Enum.find(body["comments"], &(&1["id"] == thread["id"]))

      assert carried["anchored_line"] == 9

      json!(run(Tools.ResolveComment, %{comment_id: thread["id"]}))
      body = json!(run(Tools.GetFunction, %{id: @greet}))

      refute Enum.find(body["comments"], &(&1["id"] == thread["id"]))
    end
  end

  describe "sessions" do
    test "add_comment writes into the session named, and list_comments lists that one alone" do
      elsewhere = other_session()
      thread = add(%{session: elsewhere, function_id: @greet, line: 9, body: unique_body()})

      assert find(listed(%{session: elsewhere}), thread["id"])
      refute find(listed(%{session: @session}), thread["id"])
      refute find(listed(%{session: other_session()}), thread["id"])
      assert {:ok, %{session: ^elsewhere}} = Grasp.Comments.fetch(thread["id"])
    end

    test "reply_comment and resolve_comment do not know another session's thread" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})
      id = thread["id"]
      elsewhere = other_session()

      replied = run(Tools.ReplyComment, %{session: elsewhere, comment_id: id, body: "hello"})
      assert replied.isError
      assert message(replied) == "unknown comment: #{id}"

      resolved = run(Tools.ResolveComment, %{session: elsewhere, comment_id: id})
      assert resolved.isError
      assert message(resolved) == "unknown comment: #{id}"

      assert %{"replies" => [], "resolved" => false} = find(listed(%{}), id)
    end

    test "get_function carries the named session's threads, and none without a session" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})
      carried = &Enum.find(&1["comments"], fn comment -> comment["id"] == thread["id"] end)

      assert carried.(json!(run(Tools.GetFunction, %{id: @greet})))
      refute carried.(json!(run(Tools.GetFunction, %{id: @greet, session: other_session()})))
      assert json!(run_as(Tools.GetFunction, %{id: @greet}))["comments"] == []
    end

    test "a name no session could carry is refused by every comment tool" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})

      calls = [
        {Tools.AddComment, %{function_id: @greet, line: 9, body: unique_body()}},
        {Tools.ListComments, %{}},
        {Tools.ReplyComment, %{comment_id: thread["id"], body: "hello"}},
        {Tools.ResolveComment, %{comment_id: thread["id"]}},
        {Tools.PublishComments, %{}},
        {Tools.GetFunction, %{id: @greet}}
      ]

      for {tool, params} <- calls, session <- ["no/such session", ""] do
        response = run_as(tool, Map.put(params, :session, session))
        assert response.isError, "#{inspect(tool)} took #{inspect(session)}"
        assert message(response) == Grasp.Session.Disk.name_rule()
      end

      for {tool, params} <- calls, tool != Tools.GetFunction do
        response = run_as(tool, params)
        assert response.isError, "#{inspect(tool)} ran without a session"
        assert message(response) == Grasp.Session.Disk.name_rule()
      end

      assert %{"replies" => [], "resolved" => false} = find(listed(%{}), thread["id"])
    end
  end

  describe "input schemas" do
    test "name the session, the thread, the line and the body" do
      assert Tools.ListComments.input_schema()["required"] == ["session"]

      assert Enum.sort(Tools.AddComment.input_schema()["required"]) ==
               ~w(body function_id line session)

      assert Enum.sort(Tools.ReplyComment.input_schema()["required"]) ==
               ~w(body comment_id session)

      assert Enum.sort(Tools.ResolveComment.input_schema()["required"]) ==
               ~w(comment_id session)

      assert Tools.PublishComments.input_schema()["required"] == ["session"]
      assert Tools.GetFunction.input_schema()["required"] == ["id"]

      for tool <- [
            Tools.AddComment,
            Tools.ListComments,
            Tools.ReplyComment,
            Tools.ResolveComment,
            Tools.PublishComments
          ] do
        assert tool.input_schema()["properties"]["session"]["description"] =~
                 Grasp.Session.Disk.name_rule()
      end

      # Anubis leaves a field's default out of the JSON schema, so the description carries it
      assert Tools.ListComments.input_schema()["properties"]["include_resolved"]["description"] =~
               "default false"
    end
  end
end
