defmodule Grasp.Comments.PublisherTest do
  # Sets FAKE_GH_LOG, which the whole VM shares.
  use ExUnit.Case, async: false

  alias Grasp.Comments
  alias Grasp.Comments.Publisher
  alias Grasp.Index

  @moduletag :tmp_dir

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"

  # `gh` runs from the project root the index names, so the index under test names the
  # test's own directory rather than the fixture's `/tmp/sample_app`, which is a path the
  # whole suite would share.
  setup %{tmp_dir: tmp_dir} do
    System.put_env("FAKE_GH_LOG", Path.join(tmp_dir, "gh.log"))
    on_exit(fn -> System.delete_env("FAKE_GH_LOG") end)

    {:ok, index} = Index.load("test/fixtures/index.json")
    index = %Index{index | project: Map.put(index.project, "root", tmp_dir)}

    %{index: index, log: Path.join(tmp_dir, "gh.log")}
  end

  # The store is shared by the whole suite and a publish posts every unpublished thread in
  # it, so a test recognises its own by a body no other test writes and never counts what
  # the report or the log holds.
  defp unique_body, do: "publish #{System.unique_integer([:positive])}"

  defp open(attrs) do
    {:ok, thread} =
      Comments.add(
        Map.merge(
          %{session: "default", side: "new", author: "human", body: unique_body()},
          attrs
        )
      )

    thread
  end

  defp entry(list, id), do: Enum.find(list, &(&1.comment_id == id))

  # A comment body carries line breaks, and the stand-in logs each argv as it stands, so one
  # call can span several lines of the log: a call starts where a line begins a gh command.
  defp calls(log), do: log |> File.read!() |> String.split(~r/\n(?=(?:api|pr) )/, trim: true)

  defp api_calls(log), do: log |> calls() |> Enum.filter(&String.starts_with?(&1, "api "))

  defp api_call(log, text), do: Enum.find(api_calls(log), &String.contains?(&1, text))

  describe "publish/2" do
    test "posts a thread inside the diff on its line and stamps it", %{index: index, log: log} do
      body = unique_body()
      thread = open(%{function_id: @greet, line: 7, body: body})

      assert {:ok, report} = Publisher.publish(index)

      assert report.pull_request == %{
               number: 42,
               url: "https://github.com/acme/sample_app/pull/42"
             }

      assert %{kind: :line, url: url} = entry(report.published, thread.id)
      assert url =~ "https://github.com/acme/sample_app/pull/42#discussion_r"
      refute entry(report.skipped, thread.id)
      refute entry(report.failed, thread.id)

      call = api_call(log, body)
      assert call =~ "side=RIGHT"
      assert call =~ "line=7"
      assert call =~ "commit_id=0000000"
      assert call =~ "path=lib/sample_app/greeter.ex"

      assert {:ok, %{github: github}} = Comments.fetch(thread.id)
      assert github.url == url
    end

    test "posts a range the diff covers whole as a multi-line comment", %{index: index, log: log} do
      body = unique_body()
      thread = open(%{function_id: @greet, line: 6, end_line: 8, body: body})

      assert {:ok, report} = Publisher.publish(index)
      assert %{kind: :line} = entry(report.published, thread.id)

      call = api_call(log, body)
      assert call =~ "start_line=6"
      assert call =~ "line=8"
      assert call =~ "-f start_side=RIGHT"
      assert call =~ "-f side=RIGHT"
    end

    test "posts a range reaching past the diff on the file, naming both its ends", %{
      index: index,
      log: log
    } do
      body = unique_body()
      thread = open(%{function_id: @greet, line: 6, end_line: 10, body: body})

      assert {:ok, report} = Publisher.publish(index)
      assert %{kind: :file} = entry(report.published, thread.id)

      call = api_call(log, body)
      assert call =~ "subject_type=file"
      refute call =~ "start_line="
      assert call =~ "body=`#{@greet}` · L6–L10"
    end

    test "skips a thread it has already published", %{index: index} do
      thread = open(%{function_id: @greet, line: 7})

      assert {:ok, _report} = Publisher.publish(index)
      assert {:ok, report} = Publisher.publish(index)

      assert entry(report.skipped, thread.id) == %{
               comment_id: thread.id,
               reason: "already published"
             }

      refute entry(report.published, thread.id)
    end

    test "posts a line the diff does not show on the file, under where it was written", %{
      index: index,
      log: log
    } do
      body = unique_body()
      thread = open(%{function_id: @shout, line: 9, author: "agent", body: body})

      assert {:ok, report} = Publisher.publish(index)
      assert %{kind: :file} = entry(report.published, thread.id)

      call = api_call(log, body)
      assert call =~ "subject_type=file"
      refute call =~ "side=RIGHT"
      assert call =~ "path=lib/sample_app/formatter.ex"
      assert call =~ "body=`SampleApp.Formatter.shout/1` · L9\n\nclaude: #{body}"
    end

    test "posts a comment on the base side as a file comment naming the deleted line", %{
      index: index,
      log: log
    } do
      body = unique_body()

      thread =
        open(%{
          function_id: @shout,
          side: "old",
          line: 3,
          body: body,
          snippet: "def shout(text), do: text"
        })

      assert {:ok, report} = Publisher.publish(index)
      assert %{kind: :file} = entry(report.published, thread.id)

      call = api_call(log, body)
      assert call =~ "subject_type=file"

      assert call =~
               "body=`SampleApp.Formatter.shout/1` · deleted line 3\n\n" <>
                 "> def shout(text), do: text\n\n#{body}"
    end

    test "posts each reply under the comment it answers", %{index: index, log: log} do
      body = unique_body()
      reply_body = unique_body()
      thread = open(%{function_id: @greet, line: 7, body: body})
      {:ok, _thread} = Comments.reply(thread.id, %{body: reply_body, author: "agent"})

      assert {:ok, report} = Publisher.publish(index)
      assert entry(report.published, thread.id)
      refute Enum.any?(report.warnings, &(&1 =~ "comment #{thread.id}"))

      posted = api_calls(log)
      comment = Enum.find_index(posted, &String.contains?(&1, body))
      reply = Enum.find_index(posted, &String.contains?(&1, "claude: #{reply_body}"))

      assert is_integer(comment), "the comment was not posted"
      assert is_integer(reply), "the reply was not posted"
      assert reply > comment
      assert Enum.at(posted, reply) =~ "/replies"
    end

    test "reports a comment GitHub refuses and leaves it unstamped", %{index: index} do
      thread = open(%{function_id: @greet, line: 7, body: "GHFAIL"})

      assert {:ok, report} = Publisher.publish(index)
      assert %{error: error} = entry(report.failed, thread.id)
      assert error =~ "422"
      refute entry(report.published, thread.id)

      assert {:ok, %{github: nil}} = Comments.fetch(thread.id)
    end

    test "reports a function the index no longer holds", %{index: %Index{} = index} do
      thread = open(%{function_id: @greet, line: 7})
      gone = %Index{index | functions: Map.delete(index.functions, @greet)}

      assert {:ok, report} = Publisher.publish(gone)

      assert entry(report.failed, thread.id) == %{
               comment_id: thread.id,
               error: "function is no longer in the index"
             }
    end

    test "answers the failure when the checkout has no pull request", %{index: index} do
      assert {:error, message} = Publisher.publish(index, pull_request: 404)
      assert message =~ "no pull requests"
    end

    test "answers the failure when the project root is not on this machine", %{
      index: %Index{} = index,
      tmp_dir: tmp_dir
    } do
      gone = Path.join(tmp_dir, "moved-away")
      elsewhere = %Index{index | project: Map.put(index.project, "root", gone)}

      assert Publisher.publish(elsewhere) ==
               {:error, "project root #{gone} is not a directory on this machine"}
    end

    test "answers the failure when the index names no project root", %{index: %Index{} = index} do
      rootless = %Index{index | project: Map.delete(index.project, "root")}

      assert Publisher.publish(rootless) == {:error, "the index names no project root"}
    end

    test "refuses a number no pull request can have", %{index: index} do
      assert Publisher.publish(index, pull_request: 0) ==
               {:error, "pull_request must be a positive number"}

      assert Publisher.publish(index, pull_request: -1) ==
               {:error, "pull_request must be a positive number"}
    end

    test "publishes a resolved thread only when asked to", %{index: index} do
      thread = open(%{function_id: @greet, line: 7})
      {:ok, _thread} = Comments.set_resolved(thread.id, true)

      assert {:ok, report} = Publisher.publish(index)
      refute entry(report.published, thread.id)

      assert {:ok, report} = Publisher.publish(index, include_resolved: true)
      assert %{kind: :line} = entry(report.published, thread.id)
    end

    test "warns when the index records no head, which no sha can be matched against", %{
      index: %Index{} = index
    } do
      headless = %Index{index | git: Map.put(index.git, "head", "")}

      assert {:ok, report} = Publisher.publish(headless)
      assert Enum.any?(report.warnings, &(&1 =~ "the pull request head is 0000000"))
    end

    test "warns when the index was built at another commit", %{index: index} do
      assert {:ok, report} = Publisher.publish(index, pull_request: 99)

      assert [warning] = Enum.filter(report.warnings, &(&1 =~ "9999999"))
      assert warning =~ "0000000"
      assert warning =~ "line numbers may be off"
    end
  end
end
