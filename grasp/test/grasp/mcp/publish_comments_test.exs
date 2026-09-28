defmodule Grasp.MCP.PublishCommentsTest do
  # Swaps the application's index for one rooted in this test's own directory, which every
  # mounted view reads, so it must not run beside them.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.IndexStore
  alias Grasp.MCP.Tools

  @moduletag :tmp_dir

  @greet "SampleApp.Greeter.greet/2"

  # The tool publishes through the application's index, and `gh` runs from the project root
  # that index names: the fixture's root is a path the whole suite would share, so the store
  # is pointed at a copy rooted in this test's directory and put back afterwards.
  setup %{tmp_dir: tmp_dir} do
    watched = IndexStore.path()

    document =
      "test/fixtures/index.json"
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["project", "root"], tmp_dir)

    path = Path.join(tmp_dir, "index.json")
    File.write!(path, Jason.encode!(document))
    :ok = IndexStore.load(path)

    on_exit(fn -> :ok = IndexStore.load(watched) end)

    :ok
  end

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  # The store is shared by the whole suite, so a test reads back the thread it opened rather
  # than whatever else the report carries.
  defp unique_body, do: "mcp publish #{System.unique_integer([:positive])}"

  defp published(body, id), do: Enum.find(body["published"], &(&1["comment_id"] == id))

  test "publishes the session's open threads and reports where each one went" do
    session = "mcp-publish-#{System.unique_integer([:positive])}"
    add = &json!(run(Tools.AddComment, %{session: &1, function_id: @greet, line: 7, body: &2}))
    thread = add.(session, unique_body())
    elsewhere = add.("mcp-publish-other-#{System.unique_integer([:positive])}", unique_body())

    body = json!(run(Tools.PublishComments, %{session: session}))

    assert body["pull_request"] == %{
             "number" => 42,
             "url" => "https://github.com/acme/sample_app/pull/42"
           }

    assert published(body, thread["id"])["kind"] == "line"
    assert published(body, thread["id"])["url"] =~ "#discussion_r"
    assert is_list(body["skipped"])
    assert is_list(body["failed"])
    assert is_list(body["warnings"])
    refute published(body, elsewhere["id"])

    listed =
      json!(
        run(Tools.ListComments, %{session: session, function_id: @greet, include_resolved: true})
      )

    listed = Enum.find(listed["comments"], &(&1["id"] == thread["id"]))

    assert listed["github_url"] == published(body, thread["id"])["url"]
  end

  test "answers the failure when the branch has no pull request" do
    assert %Response{isError: true, content: [%{"text" => text}]} =
             run(Tools.PublishComments, %{session: "default", pull_request: 404})

    assert text =~ "no pull requests"
  end

  test "answers a number no pull request can have rather than raising" do
    for number <- [0, -1] do
      assert %Response{isError: true, content: [%{"text" => text}]} =
               run(Tools.PublishComments, %{session: "default", pull_request: number})

      assert text == "pull_request must be a positive number"
    end
  end

  test "the schema takes a session, a pull request number and a resolved switch" do
    schema = Tools.PublishComments.input_schema()

    assert schema["required"] == ["session"]
    assert schema["properties"]["pull_request"]["type"] == "integer"
    assert schema["properties"]["include_resolved"]["description"] =~ "default false"
  end
end
