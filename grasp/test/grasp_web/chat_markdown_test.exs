defmodule GraspWeb.ChatMarkdownTest do
  use ExUnit.Case, async: true

  alias GraspWeb.ChatMarkdown

  @greeter "SampleApp.Greeter.greet/2"

  defp render(text, known \\ [@greeter]) do
    text
    |> ChatMarkdown.render(&(&1 in known))
    |> Phoenix.HTML.safe_to_string()
  end

  test "Markdown emphasis becomes markup" do
    assert render("Reads the **whole** flow.") =~ "<strong>whole</strong>"
  end

  test "a fenced block is highlighted under its language" do
    html = render("```elixir\nIO.puts(:hi)\n```")

    assert html =~ ~s(<pre class="fence" data-lang="elixir">)
    assert html =~ ~s(<code>)
    assert html =~ ~s(class="l-)
  end

  test "a fence in a language the highlighter does not know is escaped plain text" do
    html = render("```wingdings\na <b> & c\n```")

    assert html =~ ~s(<pre><code>)
    assert html =~ "a &lt;b&gt; &amp; c"
    refute html =~ "<b>"
  end

  test "a fence with no language is escaped plain text" do
    assert render("```\n<b>x</b>\n```") =~ "&lt;b&gt;x&lt;/b&gt;"
  end

  test "an inline function id the index holds becomes a card button" do
    html = render("See `#{@greeter}` for the greeting.")

    assert html =~
             ~s(<button type="button" class="fn" data-fn="#{@greeter}">#{@greeter}</button>)

    refute html =~ "phx-"
  end

  test "a button the answer wrote reaches no event" do
    html = render(~s|<button phx-click="chat_reset">Click to continue</button>|)

    refute html =~ "phx-"
    refute html =~ "chat_reset"
  end

  test "a button dressed as a function link reaches no event" do
    html =
      render(
        ~s|<button type="button" class="fn" phx-click="comment_delete" phx-value-id="3">See details</button>|
      )

    refute html =~ "phx-"
    refute html =~ "comment_delete"
  end

  test "an anchor the answer wrote reaches no event" do
    html = render(~s|<a href="/x" phx-click="chat_reset">go</a>|)

    refute html =~ "phx-"
    refute html =~ "chat_reset"
  end

  test "a function id in link text stays inside the link" do
    html = render("[Foo.bar/1](https://example.com)", ["Foo.bar/1"])

    refute html =~ "<button"
    assert html =~ "Foo.bar/1</a>"
  end

  test "a function id inside an autolink stays inside the link" do
    html = render("https://example.com/Foo.bar/1", ["Foo.bar/1"])

    refute html =~ "<button"
    assert html =~ "<a"
  end

  test "a function id in image alt text stays alt text" do
    html = render("![see Foo.bar/1](/i.png)", ["Foo.bar/1"])

    refute html =~ "button"
    assert html =~ ~s(alt="see Foo.bar/1")
  end

  test "an inline function id the index does not hold stays code" do
    html = render("See `Nope.Missing.fun/1` for nothing.")

    assert html =~ "<code>Nope.Missing.fun/1</code>"
    refute html =~ "button"
  end

  test "a module name the index holds, written as code, becomes a card button" do
    html = render("Built on `SampleApp.Counter`.", ["SampleApp.Counter"])

    assert html =~
             ~s(<button type="button" class="fn" data-fn="SampleApp.Counter">SampleApp.Counter</button>)
  end

  test "a module name the index does not hold stays code, and one in prose stays prose" do
    assert render("Built on `SampleApp.Nowhere`.") =~ "<code>SampleApp.Nowhere</code>"

    html = render("Built on SampleApp.Counter.", ["SampleApp.Counter"])
    refute html =~ "data-fn"
  end

  test "known/1 answers the functions and the modules an index holds" do
    {:ok, index} = Grasp.Index.load(Path.expand("../fixtures/index.json", __DIR__))
    known? = ChatMarkdown.known(index)

    assert known?.(@greeter)
    assert known?.("SampleApp.Greeter.greet/1")
    assert known?.("SampleApp.Counter")
    refute known?.("SampleApp.Nowhere")
    refute ChatMarkdown.known(nil).(@greeter)
  end

  test "a bare function id in prose becomes a card button" do
    html = render("The caller is #{@greeter} and it delegates.")

    assert html =~ ~s(data-fn="#{@greeter}")
    assert html =~ "The caller is <button"
    assert html =~ "</button> and it delegates."
  end

  test "prose around an unknown id is left alone" do
    html = render("Neither #{@greeter} nor Nope.Missing.fun/1 here.")

    assert html =~ ~s(data-fn="#{@greeter}")
    assert html =~ "nor Nope.Missing.fun/1 here."
  end

  test "a function id inside a fence is code, not a button" do
    html = render("```elixir\n#{@greeter}\n```")

    refute html =~ "<button"
    refute html =~ "open_root"
  end

  test "an id written against a default-argument arity follows the index" do
    html = render("Call `SampleApp.Greeter.greet/1`.", ["SampleApp.Greeter.greet/1"])

    assert html =~ ~s(data-fn="SampleApp.Greeter.greet/1")
  end

  test "a script block is stripped with its content" do
    html = render("Before.\n\n<script>alert(1)</script>\n\nAfter.")

    refute html =~ "script"
    refute html =~ "alert(1)"
    assert html =~ "Before."
    assert html =~ "After."
  end

  test "an event handler attribute is stripped" do
    html = render(~s|Text <b onclick="steal()">bold</b> more.|)

    refute html =~ "onclick"
    refute html =~ "steal()"
    assert html =~ "bold"
  end

  test "a javascript href is stripped" do
    html = render("[click](javascript:void)")

    refute html =~ "javascript"
    assert html =~ "click"
  end

  test "an inline style is stripped" do
    html = render(~s|<div style="position:fixed">over everything</div>|)

    refute html =~ "style"
    assert html =~ "over everything"
  end

  test "a link keeps its href and gains a rel" do
    html = render("[docs](https://example.com/docs)")

    assert html =~ ~s(href="https://example.com/docs")
    assert html =~ "noopener"
  end

  test "a table renders as a table" do
    html = render("| a | b |\n| - | - |\n| 1 | 2 |")

    assert html =~ "<table>"
    assert html =~ "<td>1</td>"
  end

  test "a task list renders its checkboxes" do
    html = render("- [x] done\n- [ ] open")

    assert html =~ "checkbox"
  end

  test "text carrying HTML special characters is escaped, not injected" do
    assert render("5 < 6 & 7 > 2") =~ "5 &lt; 6 &amp; 7 &gt; 2"
  end

  test "empty text renders nothing" do
    assert render("") == ""
  end

  describe "memoisation" do
    @cache :grasp_chat_markdown_cache

    test "the same answer resolving the same links is rendered once" do
      text = "A cached answer about `#{@greeter}` no. #{System.unique_integer([:positive])}."
      known? = &(&1 == @greeter)
      before = MapSet.new(:ets.tab2list(@cache), &elem(&1, 0))

      {:safe, html} = ChatMarkdown.render(text, known?)

      [key] =
        for {key, value} <- :ets.tab2list(@cache),
            value == html and not MapSet.member?(before, key),
            do: key

      :ets.insert(@cache, {key, "served from the cache"})
      assert ChatMarkdown.render(text, known?) == {:safe, "served from the cache"}
    end

    test "an answer whose module names resolve differently is rendered again" do
      text = "An answer about `SampleApp.Counter` no. #{System.unique_integer([:positive])}."

      {:safe, linked} = ChatMarkdown.render(text, &(&1 == "SampleApp.Counter"))
      {:safe, plain} = ChatMarkdown.render(text, fn _id -> false end)

      assert linked =~ "data-fn"
      refute plain =~ "data-fn"
    end

    test "an answer whose ids resolve differently is rendered again" do
      text = "Another answer about `#{@greeter}` no. #{System.unique_integer([:positive])}."

      {:safe, linked} = ChatMarkdown.render(text, &(&1 == @greeter))
      {:safe, plain} = ChatMarkdown.render(text, fn _id -> false end)

      assert linked =~ "data-fn"
      refute plain =~ "data-fn"
    end
  end
end
