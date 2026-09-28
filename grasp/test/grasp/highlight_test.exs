defmodule Grasp.HighlightTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Grasp.Highlight

  @record %{
    "id" => "Sample.run/1",
    "span" => %{"start_line" => 10, "end_line" => 12},
    "source" => "def run(x) do\n  Enum.map(x, &g/1)\n  <b>\nend",
    "calls" => [
      %{
        "target" => "Enum.map/2",
        "kind" => "remote",
        "range" => %{"start" => [11, 3], "end" => [11, 11]}
      },
      %{
        "target" => "Sample.g/1",
        "kind" => "local",
        "range" => %{"start" => [11, 16], "end" => [11, 17]}
      }
    ]
  }

  @fixture Path.expand("../fixtures/index.json", __DIR__)

  defp render(opts \\ []), do: render(@record, opts)

  defp render(record, opts) do
    record |> render_string(opts) |> LazyHTML.from_fragment()
  end

  defp render_string(record, opts) do
    opts = Keyword.merge([card_id: 7, open_calls: %{}, external?: fn _ -> false end], opts)
    record |> Highlight.render(opts) |> Phoenix.HTML.safe_to_string()
  end

  @diff_record %{
    "id" => "Sample.renamed/1",
    "span" => %{"start_line" => 5, "end_line" => 7},
    "source" => "def run(x) do\n  Enum.map(x, & &1)\nend",
    "base_source" => "def run(y) do\n  Enum.map(x, & &1)\nend",
    "calls" => [
      %{
        "target" => "Enum.map/2",
        "kind" => "remote",
        "range" => %{"start" => [6, 3], "end" => [6, 11]}
      }
    ]
  }

  defp render_diff(record, opts \\ []) do
    opts = Keyword.merge([card_id: 3, open_calls: %{}, external?: fn _ -> false end], opts)
    record |> Highlight.render_diff(opts) |> Phoenix.HTML.safe_to_string()
  end

  test "numbers lines from the span start and escapes source text" do
    html = render()
    assert LazyHTML.query(html, "span.line[data-line='10'] .ln") |> LazyHTML.text() == "10"
    assert LazyHTML.query(html, "span.line[data-line='12']") |> LazyHTML.text() =~ "<b>"
    assert LazyHTML.query(html, "span.line") |> Enum.count() == 4
  end

  test "wraps each call range in a clickable span covering exactly the callee" do
    html = render(open_calls: %{"Enum.map/2" => %{to: 2, color: 0}})
    [map] = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()

    assert LazyHTML.text(map) == "Enum.map"
    assert LazyHTML.attribute(map, "phx-click") == ["open_call"]
    assert LazyHTML.attribute(map, "phx-value-card") == ["7"]
    assert LazyHTML.attribute(map, "data-open") == ["true"]
    assert LazyHTML.query(map, "span.l-module") |> LazyHTML.text() == "Enum"

    [g] = LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> Enum.to_list()
    assert LazyHTML.text(g) == "g"
    assert LazyHTML.attribute(g, "data-open") == ["false"]
  end

  test "an open call carries the colour and the destination of the edge leaving it" do
    html = render(open_calls: %{"Enum.map/2" => %{to: 7, color: 3}})

    [map] = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()
    assert LazyHTML.attribute(map, "data-open") == ["true"]
    assert LazyHTML.attribute(map, "data-color") == ["3"]
    assert LazyHTML.attribute(map, "data-edge-to") == ["7"]

    [g] = LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> Enum.to_list()
    assert LazyHTML.attribute(g, "data-open") == ["false"]
    assert LazyHTML.attribute(g, "data-color") == []
    assert LazyHTML.attribute(g, "data-edge-to") == []
  end

  test "marks external targets" do
    html = render(external?: &(&1 == "Enum.map/2"))

    assert LazyHTML.query(html, "span.call[data-target='Enum.map/2']")
           |> LazyHTML.attribute("data-external") == ["true"]

    assert LazyHTML.query(html, "span.call[data-target='Sample.g/1']")
           |> LazyHTML.attribute("data-external") == ["false"]
  end

  test "nested Lumis spans keep the innermost class and exact columns" do
    record = %{
      "id" => "S.f/1",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => ~S|def f(x), do: "a #{inspect(x)} b"|,
      "calls" => [
        %{
          "target" => "Kernel.inspect/1",
          "kind" => "imported",
          "range" => %{"start" => [1, 20], "end" => [1, 27]}
        }
      ]
    }

    html =
      record
      |> Highlight.render(card_id: 1, open_calls: %{}, external?: fn _ -> false end)
      |> Phoenix.HTML.safe_to_string()
      |> LazyHTML.from_fragment()

    [call] = LazyHTML.query(html, "span.call[data-target='Kernel.inspect/1']") |> Enum.to_list()
    assert LazyHTML.text(call) == "inspect"
    assert LazyHTML.query(call, "span.l-function-call") |> LazyHTML.text() == "inspect"

    assert LazyHTML.query(html, "span.line[data-line='1']") |> LazyHTML.text() ==
             ~S|1def f(x), do: "a #{inspect(x)} b"|
  end

  test "a range spanning two lines produces one call span per line" do
    record = %{
      "id" => "S.spanning/0",
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def f do\n  Enum\n  .map([], & &1)\nend",
      "calls" => [
        %{
          "target" => "Enum.map/2",
          "kind" => "remote",
          "range" => %{"start" => [2, 3], "end" => [3, 7]}
        }
      ]
    }

    html =
      record
      |> Highlight.render(card_id: 1, open_calls: %{}, external?: fn _ -> false end)
      |> Phoenix.HTML.safe_to_string()
      |> LazyHTML.from_fragment()

    spans = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()
    assert Enum.map(spans, &LazyHTML.text/1) == ["Enum", ".map"]
  end

  test "a blank line inside the body keeps its number in the gutter" do
    record = %{
      "id" => "S.blank/0",
      "span" => %{"start_line" => 10, "end_line" => 14},
      "source" => "def f do\n  a = 1\n\n  a\nend",
      "calls" => []
    }

    html = render(record, [])

    assert LazyHTML.query(html, "span.line") |> Enum.count() == 5

    assert LazyHTML.query(html, "span.line") |> LazyHTML.attribute("data-line") ==
             ~w(10 11 12 13 14)

    assert LazyHTML.query(html, "span.line[data-line='12'] .ln") |> LazyHTML.text() == "12"
    assert LazyHTML.query(html, "span.line[data-line='12']") |> LazyHTML.text() == "12"
  end

  test "emits nothing between line spans, so no stray text node sits between two lines" do
    record = %{
      "id" => "S.tight/0",
      "span" => %{"start_line" => 1, "end_line" => 2},
      "source" => "def f do\nend",
      "calls" => []
    }

    refute render_string(record, []) =~ ~r{</span>\s+<span class="line"}
  end

  describe "lines/2" do
    test "gives one entry per source line, numbered from the span" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

      lines = Highlight.lines(record, card_id: 7, open_calls: %{}, external?: fn _ -> false end)

      assert Enum.map(lines, & &1.side) |> Enum.uniq() == [:new]
      assert Enum.map(lines, & &1.line) == Enum.to_list(6..11)
      assert length(lines) == record["source"] |> String.split("\n") |> length()
    end

    test "every line is :eq — outside a diff there is nothing to differ from" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

      lines = Highlight.lines(record, card_id: 7, open_calls: %{}, external?: fn _ -> false end)

      assert Enum.map(lines, & &1.op) |> Enum.uniq() == [:eq]
    end

    test "every line's gutter is the comment control for that line" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

      for line <-
            Highlight.lines(record, card_id: 7, open_calls: %{}, external?: fn _ -> false end) do
        gutter = line.html |> LazyHTML.from_fragment() |> LazyHTML.query(".ln")

        assert LazyHTML.attribute(gutter, "phx-click") == ["comment_start"]
        assert LazyHTML.attribute(gutter, "phx-value-card") == ["7"]
        assert LazyHTML.attribute(gutter, "phx-value-side") == ["new"]
        assert LazyHTML.attribute(gutter, "phx-value-line") == [to_string(line.line)]
        assert LazyHTML.attribute(gutter, "role") == ["button"]
        assert LazyHTML.attribute(gutter, "tabindex") == ["0"]
      end
    end

    test "render/2 is the lines joined" do
      opts = [card_id: 7, open_calls: %{}, external?: fn _ -> false end]

      assert render_string(@record, opts) ==
               @record |> Highlight.lines(opts) |> Enum.map_join("", & &1.html)
    end
  end

  describe "templates" do
    test "a record whose file is a .heex is read with the heex grammar" do
      record = %{
        "id" => "SampleAppWeb.PageHTML.show/1",
        "file" => "lib/sample_app_web/page_html/show.html.heex",
        "span" => %{"start_line" => 1, "end_line" => 2},
        "source" => ~s(<div class="card">\n  <p>hello</p>\n),
        "calls" => []
      }

      lines = Highlight.lines(record, card_id: 7, open_calls: %{}, external?: fn _ -> false end)

      assert Enum.map(lines, & &1.line) == [1, 2]

      doc = lines |> Enum.map_join(& &1.html) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("span.line") |> Enum.count() == 2
      assert doc |> LazyHTML.query("span.line .l-tag") |> LazyHTML.text() == "divpp"

      assert doc
             |> LazyHTML.query("span.line[data-line='1'] .l-tag-attribute")
             |> LazyHTML.text() == "class"
    end

    test "a component tag and an interpolated call in a template are clickable call spans" do
      doc = fixture_lines("SampleAppWeb.GreetHTML.show/1")

      assert doc |> LazyHTML.query("span.line") |> Enum.count() == 9

      assert doc
             |> LazyHTML.query(~s(span.call[phx-click="open_call"]))
             |> LazyHTML.attribute("data-target") == [
               "SampleAppWeb.GreetHTML.badge/1",
               "SampleAppWeb.GreetingComponent.render/1",
               "SampleAppWeb.GreetController.show/2",
               "SampleApp.Greeter.greet/1",
               "SampleApp.Greeter.greet/1",
               "SampleApp.Greeter.greet/1",
               "SampleApp.Greeter.greet/1",
               "SampleAppWeb.GreetController.create/2",
               "Phoenix.Component.link/1",
               "SampleAppWeb.HelloLive.mount/3"
             ]

      assert doc
             |> LazyHTML.query(~s(span.call[data-target="SampleAppWeb.GreetHTML.badge/1"]))
             |> LazyHTML.text() == ".badge"

      assert doc
             |> LazyHTML.query(~s(span.line[data-line="4"] span.call))
             |> LazyHTML.text() == "SampleApp.Greeter.greet"
    end

    test "a route call carries its kind and reads its verb and path on hover" do
      doc = fixture_lines("SampleAppWeb.GreetHTML.show/1")

      route = LazyHTML.query(doc, ~s(span.line[data-line="3"] span.call[data-kind="route"]))

      assert LazyHTML.attribute(route, "data-target") == ["SampleAppWeb.GreetController.show/2"]
      assert LazyHTML.attribute(route, "title") == ["GET /greet/:name"]
      assert LazyHTML.text(route) == ~s("/greet/bob")

      assert doc
             |> LazyHTML.query(~s(span.line[data-line="8"] span.call[data-kind="route"]))
             |> LazyHTML.attribute("title") == ["POST /greet"]

      assert doc
             |> LazyHTML.query(~s(span.call[data-target="SampleAppWeb.GreetHTML.badge/1"]))
             |> LazyHTML.attribute("data-kind") == []
    end

    test "a call written inside a route attribute keeps a span of its own" do
      record = %{
        "id" => "SampleAppWeb.SearchHTML.form/1",
        "kind" => "template",
        "file" => "lib/sample_app_web/search_html/form.html.heex",
        "span" => %{"start_line" => 1, "end_line" => 1},
        "source" => ~S|<a href={~p"/search?#{[q: normalize(@q)]}"}>go</a>| <> "\n",
        "calls" => [
          %{
            "target" => "SampleAppWeb.SearchController.index/2",
            "kind" => "route",
            "range" => %{"start" => [1, 9], "end" => [1, 44]},
            "route" => %{"verb" => "GET", "path" => "/search"}
          },
          %{
            "target" => "SampleApp.Text.normalize/1",
            "kind" => "remote",
            "range" => %{"start" => [1, 27], "end" => [1, 36]}
          }
        ]
      }

      doc = render(record, [])

      assert doc
             |> LazyHTML.query(~s(span.call[data-target="SampleApp.Text.normalize/1"]))
             |> LazyHTML.text() == "normalize"

      assert doc
             |> LazyHTML.query(~s(span.call[data-kind="route"] span.call))
             |> Enum.count() == 0

      assert doc
             |> LazyHTML.query(~s(span.call[data-target="SampleAppWeb.SearchController.index/2"]))
             |> Enum.count() == 2
    end

    test "a modified template's diff numbers its own lines and nothing past them" do
      record = %{
        "id" => "SampleAppWeb.PageHTML.edited/1",
        "kind" => "template",
        "file" => "lib/sample_app_web/page_html/show.html.heex",
        "span" => %{"start_line" => 1, "end_line" => 3},
        "source" => ~s(<h1>Title</h1>\n<p>new</p>\n<footer />\n),
        "base_source" => ~s(<h1>Title</h1>\n<p>old</p>\n<footer />\n),
        "calls" => []
      }

      lines =
        Highlight.diff_lines(record, card_id: 3, open_calls: %{}, external?: fn _ -> false end)

      assert Enum.filter(lines, &(&1.side == :new)) |> Enum.map(& &1.line) == [1, 2, 3]
      assert Enum.filter(lines, &(&1.side == :old)) |> Enum.map(& &1.line) == [2]
      assert Enum.map(lines, & &1.op) == [:eq, :del, :ins, :eq]

      doc = lines |> Enum.map_join(& &1.html) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("span.line[data-line]") |> LazyHTML.attribute("data-line") ==
               ~w(1 2 3)
    end

    test "a component tag inside a ~H heredoc is a clickable call span" do
      doc = fixture_lines("SampleAppWeb.HelloLive.render/1")

      assert doc
             |> LazyHTML.query(
               ~s(span.call[phx-click="open_call"][data-target="SampleAppWeb.GreetingComponent.render/1"])
             )
             |> LazyHTML.text() == "SampleAppWeb.GreetingComponent.render"
    end
  end

  test "a double call carries its kind and reads the behaviour it doubles on hover" do
    record = %{
      "id" => ~s|SampleApp.GeoTest."test looks up"/1|,
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => """
      test "looks up" do
        expect(SampleApp.GeoMock, :lookup, fn _ip -> :ok end)
      end\
      """,
      "calls" => [
        %{
          "target" => "SampleApp.Geo.Http.lookup/1",
          "kind" => "double",
          "range" => %{"start" => [2, 3], "end" => [2, 9]},
          "double" => %{"mock" => "SampleApp.GeoMock", "behaviour" => "SampleApp.Geo"}
        }
      ]
    }

    double =
      record
      |> render([])
      |> LazyHTML.query(~s(span.line[data-line="2"] span.call[data-kind="double"]))

    assert LazyHTML.attribute(double, "data-target") == ["SampleApp.Geo.Http.lookup/1"]
    assert LazyHTML.attribute(double, "phx-click") == ["open_call"]
    assert LazyHTML.attribute(double, "title") == ["Mox double of SampleApp.Geo"]
    assert LazyHTML.text(double) == "expect"
  end

  test "an enqueue call carries its kind and reads its worker and queue on hover" do
    record = %{
      "id" => "SampleAppWeb.GreetController.mail/2",
      "span" => %{"start_line" => 1, "end_line" => 5},
      "source" => """
      def mail(conn, _params) do
        SampleApp.Text.normalize(conn)
        SampleApp.Workers.Mailer.new(%{})
        redirect(conn, to: ~p"/greet/bob")
      end\
      """,
      "calls" => [
        %{
          "target" => "SampleApp.Text.normalize/1",
          "kind" => "remote",
          "range" => %{"start" => [2, 3], "end" => [2, 27]}
        },
        %{
          "target" => "SampleApp.Workers.Mailer.perform/1",
          "kind" => "enqueue",
          "range" => %{"start" => [3, 3], "end" => [3, 31]},
          "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}
        },
        %{
          "target" => "SampleAppWeb.GreetController.show/2",
          "kind" => "route",
          "range" => %{"start" => [4, 22], "end" => [4, 36]},
          "route" => %{"verb" => "GET", "path" => "/greet/:name"}
        }
      ]
    }

    doc = render(record, [])

    enqueue = LazyHTML.query(doc, ~s(span.line[data-line="3"] span.call[data-kind="enqueue"]))

    assert LazyHTML.attribute(enqueue, "data-target") == ["SampleApp.Workers.Mailer.perform/1"]
    assert LazyHTML.attribute(enqueue, "title") == ["Oban job · SampleApp.Workers.Mailer · mail"]
    assert LazyHTML.text(enqueue) == "SampleApp.Workers.Mailer.new"

    route = LazyHTML.query(doc, ~s(span.line[data-line="4"] span.call[data-kind="route"]))

    assert LazyHTML.attribute(route, "data-target") == ["SampleAppWeb.GreetController.show/2"]
    assert LazyHTML.attribute(route, "title") == ["GET /greet/:name"]

    plain = LazyHTML.query(doc, ~s(span.call[data-target="SampleApp.Text.normalize/1"]))

    assert LazyHTML.attribute(plain, "data-kind") == []
    assert LazyHTML.attribute(plain, "title") == []
  end

  describe "coverage" do
    @coverage %{lines: %{10 => "run", 11 => "missed"}, gaps: %{11 => "arm"}}

    test "a counted line says whether it ran, and an uncounted one says nothing" do
      html = render(coverage: @coverage)

      assert LazyHTML.attribute(LazyHTML.query(html, ".line[data-line='10']"), "data-coverage") ==
               ["run"]

      assert LazyHTML.attribute(LazyHTML.query(html, ".line[data-line='11']"), "data-coverage") ==
               ["missed"]

      assert LazyHTML.query(html, ".line[data-line='12'][data-coverage]") |> Enum.count() == 0
      assert LazyHTML.query(html, ".line[data-line='13'][data-coverage]") |> Enum.count() == 0
    end

    test "the first line of a gap carries its kind and words for a screen reader" do
      html = render(coverage: @coverage)

      assert LazyHTML.attribute(LazyHTML.query(html, ".line[data-gap]"), "data-gap") == ["arm"]

      assert html |> LazyHTML.query(".line[data-line='11'] .gap-label") |> LazyHTML.text() ==
               "never entered"

      assert LazyHTML.query(html, ".gap-label") |> Enum.count() == 1
    end

    test "without coverage no line is marked" do
      html = render_string(@record, [])

      refute html =~ "data-coverage"
      refute html =~ "data-gap"
      refute html =~ "never entered"
    end

    test "in a diff only the inserted lines carry the tint; a gap is marked on a kept line too" do
      coverage = %{lines: %{5 => "run", 6 => "missed"}, gaps: %{6 => "clause"}}
      html = @diff_record |> render_diff(coverage: coverage) |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(html, ".line[data-op='ins']"), "data-coverage") ==
               ["run"]

      assert LazyHTML.query(html, ".line[data-op='eq'][data-coverage]") |> Enum.count() == 0
      assert LazyHTML.query(html, ".line[data-op='del'][data-coverage]") |> Enum.count() == 0

      assert LazyHTML.attribute(LazyHTML.query(html, ".line[data-line='6']"), "data-gap") == [
               "clause"
             ]
    end
  end

  describe "diff_lines/2" do
    test "a deleted line is an old-side entry addressing its base line" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")

      lines =
        Highlight.diff_lines(record, card_id: 3, open_calls: %{}, external?: fn _ -> false end)

      [deleted] = Enum.filter(lines, &(&1.side == :old))

      doc = LazyHTML.from_fragment(deleted.html)

      assert LazyHTML.query(doc, ".line") |> LazyHTML.attribute("data-base-line") == [
               to_string(deleted.line)
             ]

      assert LazyHTML.query(doc, ".line") |> LazyHTML.attribute("data-line") == []
      assert LazyHTML.query(doc, ".ln") |> LazyHTML.attribute("tabindex") == ["0"]
      assert LazyHTML.query(doc, ".ln") |> LazyHTML.attribute("phx-value-side") == ["old"]

      assert LazyHTML.query(doc, ".ln") |> LazyHTML.attribute("phx-value-line") == [
               to_string(deleted.line)
             ]

      assert LazyHTML.query(doc, ".ln") |> LazyHTML.text() == ""

      assert Enum.filter(lines, &(&1.side == :new)) |> Enum.map(& &1.line) == [8, 9, 10]
    end

    test "every entry carries what the diff did to it" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")

      lines =
        Highlight.diff_lines(record, card_id: 3, open_calls: %{}, external?: fn _ -> false end)

      assert Enum.map(lines, &{&1.side, &1.op}) ==
               [{:new, :eq}, {:new, :eq}, {:old, :del}, {:new, :ins}]
    end

    test "render_diff/2 is the lines joined" do
      opts = [card_id: 3, open_calls: %{}, external?: fn _ -> false end]

      assert render_diff(@diff_record, opts) ==
               @diff_record |> Highlight.diff_lines(opts) |> Enum.map_join("", & &1.html)
    end
  end

  test "renders a real indexed record with the indexer's own columns" do
    {:ok, index} = Grasp.Index.load(@fixture)
    {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")

    html = render(record, [])

    assert LazyHTML.query(html, "span.call[data-target='String.upcase/1']") |> LazyHTML.text() ==
             "String.upcase"
  end

  test "a source Lumis cannot parse renders as unhighlighted text and says so once" do
    record = %{
      "id" => "S.unparseable/0",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => <<"def f, do: ", 0xFF, "()">>,
      "calls" => []
    }

    {html, log} = with_log(fn -> render(record, []) end)

    assert LazyHTML.query(html, "span.line") |> Enum.count() == 1
    assert LazyHTML.query(html, "span[class^='l-']") |> Enum.count() == 0
    assert log =~ "highlighting unavailable for S.unparseable/0"
  end

  test "escapes a target carrying markup in both attributes that hold it" do
    target = ~s(A."<b>"/1)

    record = %{
      "id" => "S.escaping/0",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => "def f, do: g()",
      "calls" => [
        %{
          "target" => target,
          "kind" => "local",
          "range" => %{"start" => [1, 12], "end" => [1, 13]}
        }
      ]
    }

    string = render_string(record, [])
    refute string =~ ~s(<b>)
    assert string =~ "&lt;b&gt;"
    assert string =~ "&quot;"

    call = string |> LazyHTML.from_fragment() |> LazyHTML.query("span.call")
    assert LazyHTML.attribute(call, "data-target") == [target]
    assert LazyHTML.attribute(call, "phx-value-target") == [target]
  end

  test "a highlighted call carries data-highlight and the others do not" do
    html = render(highlight: %{"call" => "Enum.map/2"})
    assert LazyHTML.query(html, ~s(.call[data-highlight="true"])) |> Enum.count() == 1

    assert LazyHTML.query(html, ~s(.call[data-highlight="true"]))
           |> LazyHTML.attribute("data-target") == ["Enum.map/2"]
  end

  test "highlighted lines carry data-highlight over the range only" do
    html = render(highlight: %{"lines" => [11, 12]})

    assert LazyHTML.query(html, ~s(.line[data-highlight="true"]))
           |> LazyHTML.attribute("data-line") == ~w(11 12)
  end

  test "no highlight, no attribute" do
    html = render()
    assert LazyHTML.query(html, "[data-highlight]") |> Enum.count() == 0
  end

  describe "render_diff/2" do
    test "a deleted line carries its text, no number and a minus" do
      html = @diff_record |> render_diff() |> LazyHTML.from_fragment()
      [del] = html |> LazyHTML.query(".line[data-op='del']") |> Enum.to_list()

      assert LazyHTML.text(del) =~ "def run(y) do"
      assert LazyHTML.attribute(del, "data-line") == []
      assert LazyHTML.query(del, ".ln") |> LazyHTML.text() == ""
      assert LazyHTML.query(del, ".op") |> LazyHTML.text() == "\u2212"
    end

    test "a deleted line is drawn from its own base line, not from its position in the diff" do
      record = %{
        "id" => "Sample.shrunk/0",
        "span" => %{"start_line" => 1, "end_line" => 2},
        "source" => "alpha = 1\ngamma = 3",
        "base_source" => "alpha = 1\nbeta = 2\ngamma = 3",
        "calls" => []
      }

      html = record |> render_diff() |> LazyHTML.from_fragment()
      [del] = html |> LazyHTML.query(".line[data-op='del']") |> Enum.to_list()

      assert LazyHTML.text(del) |> String.replace("\u2212", "") |> String.trim() == "beta = 2"

      assert html |> LazyHTML.query(".line[data-op='eq']") |> LazyHTML.attribute("data-line") ==
               ~w(1 2)
    end

    test "an inserted line is numbered from the span start" do
      html = @diff_record |> render_diff() |> LazyHTML.from_fragment()
      [ins] = html |> LazyHTML.query(".line[data-op='ins']") |> Enum.to_list()

      assert LazyHTML.attribute(ins, "data-line") == ["5"]
      assert LazyHTML.text(ins) =~ "def run(x) do"
      assert LazyHTML.query(ins, ".ln") |> LazyHTML.text() == "5"
      assert LazyHTML.query(ins, ".op") |> LazyHTML.text() == "+"
    end

    test "an unchanged line keeps its current number, its call span and a blank marker" do
      html = @diff_record |> render_diff() |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query(".line[data-op='eq']") |> LazyHTML.attribute("data-line") ==
               ~w(6 7)

      [call] =
        html
        |> LazyHTML.query(".line[data-op='eq'][data-line='6'] span.call")
        |> Enum.to_list()

      assert LazyHTML.attribute(call, "data-target") == ["Enum.map/2"]
      assert LazyHTML.text(call) == "Enum.map"

      assert html |> LazyHTML.query(".line[data-op='eq'][data-line='6'] .op") |> LazyHTML.text() ==
               " "
    end

    test "the deleted line is highlighted from the base source and wraps no call" do
      html = @diff_record |> render_diff() |> LazyHTML.from_fragment()
      del = LazyHTML.query(html, ".line[data-op='del']")

      assert LazyHTML.query(del, "span.call") |> Enum.count() == 0
      assert LazyHTML.query(del, "span.l-keyword-function") |> LazyHTML.text() == "def"
    end

    test "an open call and a highlight still reach the lines the current source kept" do
      html =
        @diff_record
        |> render_diff(
          open_calls: %{"Enum.map/2" => %{to: 9, color: 4}},
          highlight: %{"lines" => [6, 6]}
        )
        |> LazyHTML.from_fragment()

      call = LazyHTML.query(html, "span.call[data-target='Enum.map/2']")
      assert LazyHTML.attribute(call, "data-open") == ["true"]
      assert LazyHTML.attribute(call, "data-edge-to") == ["9"]

      assert html
             |> LazyHTML.query(~s(.line[data-highlight="true"]))
             |> LazyHTML.attribute("data-line") ==
               ["6"]
    end

    test "a record with no base source renders exactly as render/2 does" do
      string = render_diff(@record)

      assert string == render_string(@record, card_id: 3)
      refute string =~ ~s(data-op=)
    end

    test "the real modified fixture record reads as one deletion and one insertion" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")

      html = record |> render_diff() |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query(".line[data-op='del']") |> Enum.count() == 1
      assert html |> LazyHTML.query(".line[data-op='ins']") |> Enum.count() == 1

      assert html |> LazyHTML.query(".line[data-op='eq']") |> LazyHTML.attribute("data-line") ==
               ~w(8 9)

      assert html
             |> LazyHTML.query(".line[data-op='ins'] span.call")
             |> LazyHTML.attribute("data-target") ==
               ["String.upcase/1"]
    end
  end

  describe "signature/1" do
    test "renders the head's tokens, without its indentation and without its trailing do" do
      html = fixture_signature("SampleApp.Greeter.greet/2")
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.text(doc) == ~S|def greet(name, loud? \\ false)|
      assert LazyHTML.query(doc, "span.l-keyword-function") |> LazyHTML.text() == "def"
      assert LazyHTML.query(doc, "span.l-function") |> LazyHTML.text() == "greet"
      assert LazyHTML.query(doc, ".ln") |> Enum.count() == 0
    end

    test "a call in the head is highlighted like any other token, and is not clickable" do
      html = fixture_signature("SampleApp.Greeter.greet_all/1")
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.text(doc) == "def greet_all(names), do: Enum.map(names, &greet/1)"
      assert LazyHTML.query(doc, "span.l-module") |> LazyHTML.text() == "Enum"
      assert LazyHTML.query(doc, "span.call") |> Enum.count() == 0
      refute html =~ "phx-click"
    end

    test "falls back to the escaped function id when nothing in the source defines anything" do
      record = %{
        "id" => "Sample.<b>/1",
        "span" => %{"start_line" => 3},
        "source" => "  # nothing to see\n  :ok"
      }

      assert record |> Highlight.signature() |> Phoenix.HTML.safe_to_string() ==
               "<span>Sample.&lt;b&gt;/1</span>"
    end

    test "reads the base commit's text when the record carries no source of its own" do
      record = %{
        "id" => "Sample.vanished/1",
        "removed" => true,
        "base_source" => "  defp vanished(text) do\n    text\n  end"
      }

      doc = record |> Highlight.signature() |> Phoenix.HTML.safe_to_string()

      assert doc |> LazyHTML.from_fragment() |> LazyHTML.text() == "defp vanished(text)"
    end
  end

  describe "assertions/1" do
    test "gives a test's assertions, numbered as the file numbers them and highlighted" do
      {:ok, index} = Grasp.Index.load(@fixture)

      {:ok, record} =
        Grasp.Index.fetch_function(
          index,
          ~s|SampleApp.TallyTest."test handle_call/3 replies with the next number"/1|
        )

      assert [{13..13//1, html}] = Highlight.assertions(record)
      doc = html |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()

      assert LazyHTML.text(doc) ==
               "assert {:reply, 42, 42} = Counter.handle_call(:next, self(), start)"

      assert LazyHTML.query(doc, ".ln") |> Enum.count() == 0
      assert LazyHTML.query(doc, "span.call") |> Enum.count() == 0
    end

    test "reads an assertion broken over several lines whole, without its indentation" do
      source = """
        test "x" do
          resp = call()

          assert %{
                   status: 200,
                   body: "ok"
                 } = resp
        end
      """

      assert [{13..16//1, html}] = assertions_of(source, 10)

      assert text(html) ==
               "assert %{\n         status: 200,\n         body: \"ok\"\n       } = resp"
    end

    test "reads assert, refute, the assert_/refute_ calls and a piped stage" do
      source = """
        test "x" do
          assert_value = 1
          assert x == 1
          refute y
          assert_receive {:done, _}
          conn
          |> get("/x")
          |> assert_element("a")
          assertion = 2
          assert(z)
        end
      """

      assert assertions_of(source, 1) |> Enum.map(fn {range, html} -> {range, text(html)} end) ==
               [
                 {3..3//1, "assert x == 1"},
                 {4..4//1, "refute y"},
                 {5..5//1, "assert_receive {:done, _}"},
                 {6..8//1, ~s[conn\n|> get("/x")\n|> assert_element("a")]},
                 {10..10//1, "assert(z)"}
               ]
    end

    test "is one range for an assertion nested in another's function" do
      source = """
        test "x" do
          assert_raise ArgumentError, fn ->
            assert f(1)
          end
        end
      """

      assert [{2..4//1, _html}] = assertions_of(source, 1)
    end

    test "is empty for a test asserting nothing, and for a source that does not parse" do
      assert assertions_of(~s|  test "x" do\n    :ok\n  end|, 1) == []
      assert assertions_of(~s|  test "x" do\n    assert (|, 1) == []
    end
  end

  defp assertions_of(source, first_line) do
    id = "M.t#{System.unique_integer([:positive])}/1"

    record = %{
      "id" => id,
      "span" => %{"start_line" => first_line},
      "source" => String.trim_trailing(source)
    }

    Highlight.assertions(record)
  end

  defp text(html),
    do: html |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "signature_line/1" do
    test "numbers the head as the file numbers it, past the docs above it" do
      {:ok, index} = Grasp.Index.load(@fixture)
      {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")

      assert Highlight.signature_line(record) == {8, ~S|def greet(name, loud? \\ false)|}
    end

    test "is nil when no line defines anything" do
      assert Highlight.signature_line(%{"id" => "M.f/1", "source" => "  :ok"}) == nil
    end
  end

  defp fixture_lines(function_id) do
    {:ok, index} = Grasp.Index.load(@fixture)
    {:ok, record} = Grasp.Index.fetch_function(index, function_id)

    record
    |> Highlight.lines(card_id: 7, open_calls: %{}, external?: fn _ -> false end)
    |> Enum.map_join(& &1.html)
    |> LazyHTML.from_fragment()
  end

  defp fixture_signature(function_id) do
    {:ok, index} = Grasp.Index.load(@fixture)
    {:ok, record} = Grasp.Index.fetch_function(index, function_id)

    record |> Highlight.signature() |> Phoenix.HTML.safe_to_string()
  end
end
