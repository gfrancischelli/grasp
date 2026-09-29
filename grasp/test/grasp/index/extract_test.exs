defmodule Grasp.Index.ExtractTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Extract

  @source ~S"""
  defmodule Sample do
    # Says hi.
    @doc "Greets."
    @spec greet(String.t(), boolean()) :: String.t()
    def greet(name, loud? \\ false) do
      text = Formatter.wrap(name)
      if loud?, do: shout(text), else: text
    end

    def count(list) when is_list(list), do: length(list)
    def count(_), do: 0

    defmodule Nested do
      def hello, do: Sample.greet("n")
    end

    defmodule __MODULE__.Deep do
      defp hidden, do: :ok
    end
  end
  """

  test "groups clauses and attaches doc, spec and leading comments to the span" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    greet = find(defs, "Sample", :greet)
    assert %{arity: 2, arities: [1, 2], kind: :def, file: "lib/sample.ex"} = greet
    assert greet.start_line == 2
    assert greet.end_line == 8
    assert greet.source == @source |> String.split("\n") |> Enum.slice(1, 7) |> Enum.join("\n")

    count = find(defs, "Sample", :count)
    assert %{arity: 1, arities: [1], start_line: 10, end_line: 11} = count
    assert String.starts_with?(count.source, "  def count(list) when")
    assert String.ends_with?(count.source, "def count(_), do: 0")
  end

  test "a decorator attribute attaches like a doc or a spec" do
    source = ~S"""
    defmodule Acme.Audited do
      @doc "Greets with a trail."
      @spec greet(String.t()) :: String.t()
      @decorate trace()
      def greet(name), do: name

      @decorate trace()
      def wave, do: :ok
    end
    """

    {:ok, %{definitions: defs}} = Extract.extract(source, "lib/acme/audited.ex")

    greet = find(defs, "Acme.Audited", :greet)
    assert greet.start_line == 2
    assert String.starts_with?(greet.source, "  @doc")

    wave = find(defs, "Acme.Audited", :wave)
    assert wave.start_line == 7
    assert String.starts_with?(wave.source, "  @decorate")
  end

  test "resolves nested and __MODULE__-prefixed module names" do
    {:ok, %{definitions: defs, modules: modules}} = Extract.extract(@source, "lib/sample.ex")

    assert %{kind: :def, start_line: 14, end_line: 14} = find(defs, "Sample.Nested", :hello)
    assert %{kind: :defp} = find(defs, "Sample.Deep", :hidden)

    assert modules == [
             %{name: "Sample", file: "lib/sample.ex", line: 1, doc: nil, span: nil, source: nil},
             %{
               name: "Sample.Nested",
               file: "lib/sample.ex",
               line: 13,
               doc: nil,
               span: nil,
               source: nil
             },
             %{
               name: "Sample.Deep",
               file: "lib/sample.ex",
               line: 17,
               doc: nil,
               span: nil,
               source: nil
             }
           ]
  end

  describe "moduledocs" do
    test "a string is the moduledoc's text, spanning the attribute's line" do
      source = ~S"""
      defmodule A do
        @moduledoc "Adds things."
        def f, do: :f
      end
      """

      assert module(source, "A") == %{
               name: "A",
               file: "lib/a.ex",
               line: 1,
               doc: %{text: "Adds things.", hidden: false},
               span: %{start_line: 2, end_line: 2},
               source: ~S(  @moduledoc "Adds things.")
             }
    end

    test "a heredoc spans through its closing line, its text dedented" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        Adds *things*.

        And more.
        """

        def f, do: :f
      end
      '''

      assert %{doc: doc, span: span, source: text} = module(source, "A")
      assert doc == %{text: "Adds *things*.\n\nAnd more.\n", hidden: false}
      assert span == %{start_line: 2, end_line: 6}

      assert text ==
               Enum.join(
                 [~S(  @moduledoc """), "  Adds *things*.", "", "  And more.", ~S(  """)],
                 "\n"
               )
    end

    test "a ~S or ~s sigil without interpolation gives its text" do
      source = ~S'''
      defmodule A do
        @moduledoc ~S"""
        Reads #{literally}.
        """
      end

      defmodule B do
        @moduledoc ~s(Plain words.)
      end
      '''

      assert module(source, "A").doc == %{text: "Reads \#{literally}.\n", hidden: false}
      assert module(source, "A").span == %{start_line: 2, end_line: 4}
      assert module(source, "B").doc == %{text: "Plain words.", hidden: false}
    end

    test "@moduledoc false is hidden and has no text" do
      source = ~S"""
      defmodule A do
        @moduledoc false
      end
      """

      assert %{doc: %{text: nil, hidden: true}, span: %{start_line: 2, end_line: 2}} =
               module(source, "A")
    end

    test "an interpolated string or any other expression has no text, and its lines are kept" do
      source = ~S"""
      defmodule A do
        @moduledoc "Adds #{@what}."
      end

      defmodule B do
        @moduledoc ~s(Adds #{@what}.)
      end

      defmodule C do
        @moduledoc @text
      end
      """

      for {name, line} <- [{"A", 2}, {"B", 6}, {"C", 10}] do
        assert %{doc: %{text: nil, hidden: false}, span: span, source: text} =
                 module(source, name)

        assert span == %{start_line: line, end_line: line}
        assert text =~ "@moduledoc"
      end
    end

    test "a module without one has no doc, span or source" do
      source = ~S"""
      defmodule A do
        def f, do: :f
      end
      """

      assert %{doc: nil, span: nil, source: nil} = module(source, "A")
    end

    test "a nested module's moduledoc is its own, never its parent's" do
      source = ~S"""
      defmodule A do
        defmodule Inner do
          @moduledoc "Inner."
        end

        @moduledoc "Outer."
      end

      defmodule B do
        defmodule Inner do
          @moduledoc "Only the inner one."
        end
      end
      """

      assert module(source, "A").doc.text == "Outer."
      assert module(source, "A").span == %{start_line: 6, end_line: 6}
      assert module(source, "A.Inner").doc.text == "Inner."
      assert module(source, "B").doc == nil
      assert module(source, "B.Inner").doc.text == "Only the inner one."
    end

    test "the first @moduledoc is the one read" do
      source = ~S"""
      defmodule A do
        @moduledoc "First."
        @moduledoc "Second."
      end
      """

      assert module(source, "A").doc.text == "First."
    end

    test "a moduledoc is never part of the first definition's span" do
      source = ~S"""
      defmodule A do
        @moduledoc "Adds things."
        @doc "F."
        def f, do: :f
      end
      """

      {:ok, %{definitions: [f]}} = Extract.extract(source, "lib/a.ex")
      assert {f.start_line, f.end_line} == {3, 4}
    end
  end

  test "collects call sites keyed by the function name position, ranging over the callee only" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    greet = find(defs, "Sample", :greet)

    assert %{range: %{start: {6, 12}, end: {6, 26}}} = site(greet, 6, 22)
    assert %{range: %{start: {7, 19}, end: {7, 24}}} = site(greet, 7, 19)

    count = find(defs, "Sample", :count)
    assert %{range: %{start: {10, 24}, end: {10, 31}}} = site(count, 10, 24)
  end

  @kinds ~S"""
  defmodule Ops do
    defdelegate size(x), to: Enum, as: :count
    defguard is_pos(x) when x > 0
    def zero, do: 0
    def all(list), do: Enum.map(list, &double/1)
    defp double(x), do: x * 2
    defmacro twice(x), do: quote(do: unquote(x) * 2)
  end
  """

  test "recognises every definition kind and parenless heads" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")

    assert %{kind: :defdelegate, arity: 1} = find(defs, "Ops", :size)
    assert %{kind: :defguard, arity: 1} = find(defs, "Ops", :is_pos)
    assert %{kind: :def, arity: 0, arities: [0]} = find(defs, "Ops", :zero)
    assert %{kind: :defp} = find(defs, "Ops", :double)
    assert %{kind: :defmacro} = find(defs, "Ops", :twice)
  end

  test "treats function captures as call sites" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")
    all = find(defs, "Ops", :all)

    assert %{range: %{start: {5, 22}, end: {5, 30}}} = site(all, 5, 27)
    assert %{range: %{start: {5, 38}, end: {5, 44}}} = site(all, 5, 38)
  end

  test "returns the parser error for invalid source" do
    assert {:error, _} = Extract.extract("defmodule Broken do\n  def (\nend\n", "lib/broken.ex")
  end

  test "records the head position and range of every clause" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    greet = find(defs, "Sample", :greet)
    assert greet.head_positions == [{5, 7}]
    assert greet.head_ranges == [%{start: {5, 7}, end: {5, 12}}]

    count = find(defs, "Sample", :count)
    assert count.head_positions == [{10, 7}, {11, 7}]
  end

  test "keeps the guard site and adds no site for the head or its operators" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    count = find(defs, "Sample", :count)

    assert %{range: %{start: {10, 24}, end: {10, 31}}} = site(count, 10, 24)
    refute site(count, 10, 7)
  end

  @defaults ~S"""
  defmodule Defaults do
    def greet(name, prefix \\ String.trim(" p ")) do
      prefix <> name
    end
  end
  """

  test "collects call sites inside default-argument expressions" do
    {:ok, %{definitions: defs}} = Extract.extract(@defaults, "lib/defaults.ex")
    greet = find(defs, "Defaults", :greet)

    assert %{range: %{start: {2, 29}, end: {2, 40}}} = site(greet, 2, 36)
    refute site(greet, 2, 7)
  end

  test "produces no site for special forms the compiler never reports" do
    source = ~S"""
    defmodule Forms do
      def build(map, bin, list) do
        %{a: a} = map
        <<b::binary>> = bin
        [h | t] = list
        ^a = h
        {%Range{first: a}, b, t}
      end
    end
    """

    {:ok, %{definitions: defs}} = Extract.extract(source, "lib/forms.ex")
    assert find(defs, "Forms", :build).call_sites == []
  end

  @templates ~S'''
  defmodule SampleWeb.Page do
    embed_templates "page_html/*"

    def render(assigns) do
      ~H"""
      <.badge label="x" />
      <SampleAppWeb.GreetingComponent.render name={@name} />
      """
    end

    def show(conn, name) do
      render(conn, :show, name: name)
    end

    def legacy(conn), do: render(conn, "show.html", [])
  end
  '''

  test "turns the component tags of a ~H sigil into call sites with file coordinates" do
    {:ok, %{definitions: defs}} = Extract.extract(@templates, "lib/sample_web/page.ex")
    render = find(defs, "SampleWeb.Page", :render)

    assert %{range: %{start: {6, 6}, end: {6, 12}}, template: nil} = site(render, 6, 5)
    assert %{range: %{start: {7, 6}, end: {7, 43}}, template: nil} = site(render, 7, 37)
  end

  test "makes no site of the ~H sigil itself, only of what its template holds" do
    {:ok, %{definitions: defs}} = Extract.extract(@templates, "lib/sample_web/page.ex")
    render = find(defs, "SampleWeb.Page", :render)

    assert Enum.map(render.call_sites, &{&1.line, &1.column}) == [{6, 5}, {7, 37}, {7, 50}]
  end

  test "makes no site of a sigil written in an interpolation" do
    sites = Extract.expression_sites(~S|~p"/users/#{@id}"|, 1, 1)

    refute Enum.any?(sites, &(&1.callee.name == :sigil_p))
  end

  @inline_template ~S'''
  defmodule SampleWeb.Inline do
    def badge(assigns), do: ~H"<.label text={@text} />"
  end
  '''

  test "keys a single-line ~H sigil's tags where the compiler reports them, ranged where written" do
    {:ok, %{definitions: defs}} = Extract.extract(@inline_template, "lib/sample_web/inline.ex")
    badge = find(defs, "SampleWeb.Inline", :badge)

    assert site(badge, 3, 1) == %{
             line: 3,
             column: 1,
             range: %{start: {2, 31}, end: {2, 37}},
             template: nil,
             callee: nil
           }
  end

  test "names the template a render call renders, dropping the .html suffix" do
    {:ok, %{definitions: defs}} = Extract.extract(@templates, "lib/sample_web/page.ex")

    assert %{template: "show"} = site(find(defs, "SampleWeb.Page", :show), 12, 5)
    assert %{template: "show"} = site(find(defs, "SampleWeb.Page", :legacy), 15, 25)
  end

  test "collects the template patterns a module embeds" do
    {:ok, %{embeds: embeds}} = Extract.extract(@templates, "lib/sample_web/page.ex")

    assert embeds == [
             %{
               module: "SampleWeb.Page",
               pattern: "page_html/*",
               suffix: nil,
               root: nil,
               file: "lib/sample_web/page.ex",
               line: 2
             }
           ]
  end

  @embed_options ~S'''
  defmodule SampleWeb.Mailer do
    embed_templates "emails/*", suffix: "_html", root: "../shared"

    embed_templates "texts/*", suffix: @suffix
  end
  '''

  test "reads the suffix and root an embed names, and only when they are literal" do
    {:ok, %{embeds: embeds}} = Extract.extract(@embed_options, "lib/sample_web/mailer.ex")

    assert [emails, texts] = embeds
    assert %{pattern: "emails/*", suffix: "_html", root: "../shared"} = emails
    assert %{pattern: "texts/*", suffix: nil, root: nil} = texts
  end

  test "records the callee as written on every site the Elixir AST produces" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    assert %{callee: %{module: "Formatter", name: :wrap, arity: 1}} =
             site(find(defs, "Sample", :greet), 6, 22)

    assert %{callee: %{module: nil, name: :shout, arity: 1}} =
             site(find(defs, "Sample", :greet), 7, 19)
  end

  test "records the written arity of a capture rather than its argument list" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")
    all = find(defs, "Ops", :all)

    assert %{callee: %{module: "Enum", name: :map, arity: 2}} = site(all, 5, 27)
    assert %{callee: %{module: nil, name: :double, arity: 1}} = site(all, 5, 38)
  end

  test "parses an interpolation body at the file position it was given" do
    assert Extract.expression_sites("SampleApp.Greeter.greet(@name)", 12, 8) == [
             %{
               line: 12,
               column: 26,
               range: %{start: {12, 8}, end: {12, 31}},
               template: nil,
               callee: %{module: "SampleApp.Greeter", name: :greet, arity: 1}
             },
             %{
               line: 12,
               column: 32,
               range: %{start: {12, 32}, end: {12, 33}},
               template: nil,
               callee: %{module: nil, name: :@, arity: 1}
             }
           ]
  end

  test "parses a body that only becomes an expression once an end is added" do
    assert %{callee: %{module: nil, name: :ok?, arity: 1}} =
             Extract.expression_sites(" if ok?(@u) do ", 3, 8)
             |> Enum.find(&(&1.column == 12))
  end

  test "yields nothing for a body no parse can make an expression of" do
    assert Extract.expression_sites(" else ", 1, 1) == []
    assert Extract.expression_sites(" end ", 1, 1) == []
  end

  # The walk makes a one-column site for an `@` node, in an interpolation as in a clause
  # body; the compiler reports no call there, so nothing ever lands on it.
  test "reads a module attribute the way a clause body does" do
    assert Extract.expression_sites("@name", 1, 1) == [
             %{
               line: 1,
               column: 1,
               range: %{start: {1, 1}, end: {1, 2}},
               template: nil,
               callee: %{module: nil, name: :@, arity: 1}
             }
           ]
  end

  test "counts a piped value as the first argument of the call it feeds" do
    assert [%{callee: %{module: "Fmt", name: :money, arity: 1}}] =
             "@amount |> Fmt.money()"
             |> Extract.expression_sites(1, 1)
             |> Enum.filter(&(&1.callee.name == :money))
  end

  test "counts the piped value at every step of a chain" do
    assert "a |> f() |> g(1)"
           |> Extract.expression_sites(1, 1)
           |> Enum.map(& &1.callee)
           |> Enum.filter(&(&1.name in [:f, :g]))
           |> Enum.sort_by(& &1.name) == [
             %{module: nil, name: :f, arity: 1},
             %{module: nil, name: :g, arity: 2}
           ]
  end

  test "adds nothing for a pipe into a variable" do
    assert "a |> b"
           |> Extract.expression_sites(1, 1)
           |> Enum.map(& &1.callee.name) == [:|>]
  end

  test "records no written module for a receiver that is not a module" do
    assert [%{callee: %{module: nil, name: :foo, arity: 1}}] =
             Extract.expression_sites("nil.foo(1)", 1, 1)
  end

  @interpolated ~S'''
  defmodule SampleWeb.Interp do
    def render(assigns) do
      ~H"""
      <p>{SampleApp.Greeter.greet(@name)}</p>
      """
    end
  end
  '''

  test "turns a call written inside a ~H heredoc interpolation into a call site" do
    {:ok, %{definitions: defs}} = Extract.extract(@interpolated, "lib/sample_web/interp.ex")

    assert %{
             range: %{start: {4, 9}, end: {4, 32}},
             callee: %{module: "SampleApp.Greeter", name: :greet, arity: 1}
           } = site(find(defs, "SampleWeb.Interp", :render), 4, 27)
  end

  @inline_interpolated ~S'''
  defmodule SampleWeb.InlineInterp do
    def badge(assigns), do: ~H"<p>{shout(@x)}</p>"
  end
  '''

  test "keys a single-line ~H sigil's interpolated call where the compiler reports it" do
    {:ok, %{definitions: defs}} =
      Extract.extract(@inline_interpolated, "lib/sample_web/inline_interp.ex")

    assert site(find(defs, "SampleWeb.InlineInterp", :badge), 3, 5) == %{
             line: 3,
             column: 5,
             range: %{start: {2, 34}, end: {2, 39}},
             template: nil,
             callee: %{module: nil, name: :shout, arity: 1}
           }
  end

  test "collects both the tags and the interpolations of a template" do
    template = "<.badge label={label(@x)} />\n"

    assert Extract.template_sites(template, {1, 0}, nil) |> Enum.map(&{&1.column, &1.callee}) == [
             {1, nil},
             {16, %{module: nil, name: :label, arity: 1}},
             {22, %{module: nil, name: :@, arity: 1}}
           ]
  end

  test "leaves template nil on a call site that is not a render call" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    assert %{template: nil} = site(find(defs, "Sample", :greet), 6, 22)
  end

  describe "route sites" do
    test "reads the path of a ~p sigil, with an interpolated segment as :dynamic" do
      assert Extract.route_sites(~S|~p"/greet/#{@name}?x=1"|, 1, 1) == [
               %{verb: "GET", path: ["greet", :dynamic], range: %{start: {1, 1}, end: {1, 24}}}
             ]
    end

    test "reads the root path as no segments at all" do
      assert [%{path: []}] = Extract.route_sites(~S|~p"/"|, 1, 1)
    end

    test "reads a segment an interpolation only part of as dynamic whole" do
      assert [%{path: [:dynamic, "b"]}] = Extract.route_sites(~S|~p"/a-#{x}/b"|, 1, 1)
    end

    test "reads no route from a sigil whose path is relative" do
      assert Extract.route_sites(~S|~p"greet"|, 1, 1) == []
    end

    @routed ~S'''
    defmodule SampleWeb.Page do
      def render(assigns) do
        ~H"""
        <a href="/greet/bob">again</a>
        """
      end
    end
    '''

    test "carries the route a ~H heredoc links to on the definition" do
      {:ok, %{definitions: defs}} = Extract.extract(@routed, "lib/sample_web/page.ex")

      assert find(defs, "SampleWeb.Page", :render).route_sites == [
               %{verb: "GET", path: ["greet", "bob"], range: %{start: {4, 13}, end: {4, 25}}}
             ]
    end

    @inline_routed ~S'''
    defmodule SampleWeb.Inline do
      def badge(assigns), do: ~H"<a href='/x'>"
    end
    '''

    test "ranges a single-line ~H sigil's route where the reader sees it" do
      {:ok, %{definitions: defs}} = Extract.extract(@inline_routed, "lib/sample_web/inline.ex")

      assert find(defs, "SampleWeb.Inline", :badge).route_sites == [
               %{verb: "GET", path: ["x"], range: %{start: {2, 38}, end: {2, 42}}}
             ]

      # Those columns are the file's own: they cover the attribute's value, quotes and all.
      line = @inline_routed |> String.split("\n") |> Enum.at(1)
      assert String.slice(line, 37, 4) == "'/x'"
    end

    test "reads an htmx verb from the attribute that names it, counting the sigil once" do
      assert Extract.template_route_sites(~S|<button hx-post={~p"/greet"}>|, {1, 0}) == [
               %{verb: "POST", path: ["greet"], range: %{start: {1, 17}, end: {1, 29}}}
             ]
    end

    test "reads a component form's action as a post and a plain form's as a get" do
      assert [%{verb: "POST", path: ["greet"]}] =
               Extract.template_route_sites(~S|<.form action={~p"/greet"}>|, {1, 0})

      assert [%{verb: "GET", path: ["search"]}] =
               Extract.template_route_sites(~S|<form action="/search">|, {1, 0})

      assert [%{verb: "POST", path: ["x"]}] =
               Extract.template_route_sites(~S|<form action="/x" method="post">|, {1, 0})
    end

    test "reads a link's literal method as its verb" do
      assert [%{verb: "DELETE", path: ["users", :dynamic]}] =
               Extract.template_route_sites(
                 ~S|<.link href={~p"/users/#{@u}"} method="delete">|,
                 {1, 0}
               )

      assert [%{verb: "POST", path: ["hello"]}] =
               Extract.template_route_sites(
                 ~S|<.link navigate={~p"/hello"} method="post">|,
                 {1, 0}
               )

      assert [%{verb: "GET", path: ["x"]}] =
               Extract.template_route_sites(~S|<a href="/x">|, {1, 0})
    end

    test "keeps an htmx attribute's own verb whatever the tag's method says" do
      assert [%{verb: "GET", path: ["x"]}] =
               Extract.template_route_sites(~S|<button hx-get="/x" method="post">|, {1, 0})
    end

    test "reads no route from a protocol-relative URL" do
      assert Extract.template_route_sites(~S|<a href="//cdn.example.com/app.js">|, {1, 0}) == []
      assert Extract.path_segments("//x") == nil
    end

    test "reads no route from a path no parse can know or no router can answer" do
      assert Extract.template_route_sites(~S|<a href={@path}>|, {1, 0}) == []
      assert Extract.template_route_sites(~S|<a href="https://example.com/">|, {1, 0}) == []
      assert Extract.template_route_sites(~S|<a href="#top">|, {1, 0}) == []
    end

    test "cuts a query string and a fragment off the path" do
      assert [%{path: ["x"]}] = Extract.template_route_sites(~S|<a href="/x?q=1#frag">|, {1, 0})
    end

    test "reads a request with a literal path as a route with the verb its name gives" do
      for {call, verb} <- [
            {"get", "GET"},
            {"post", "POST"},
            {"put", "PUT"},
            {"patch", "PATCH"},
            {"delete", "DELETE"},
            {"head", "HEAD"},
            {"options", "OPTIONS"},
            {"live", "GET"},
            {"visit", "GET"}
          ] do
        text = ~s|#{call}(conn, "/greet/bob", %{})|
        start = String.length(call) + 8

        assert Extract.route_sites(text, 1, 1) == [
                 %{
                   verb: verb,
                   path: ["greet", "bob"],
                   range: %{start: {1, start}, end: {1, start + 12}}
                 }
               ]
      end
    end

    test "reads a request whose path is a ~p sigil as one route with the request's verb" do
      assert Extract.route_sites(~S|get(conn, ~p"/greet")|, 1, 1) == [
               %{verb: "GET", path: ["greet"], range: %{start: {1, 11}, end: {1, 21}}}
             ]

      assert Extract.route_sites(~S|post(conn, ~p"/greet/#{name}")|, 1, 1) == [
               %{verb: "POST", path: ["greet", :dynamic], range: %{start: {1, 12}, end: {1, 30}}}
             ]
    end

    test "reads a remote request and a piped one" do
      assert [%{verb: "GET", path: ["x"]}] =
               Extract.route_sites(~S|Phoenix.ConnTest.get(conn, "/x")|, 1, 1)

      assert [%{verb: "DELETE", path: ["x"]}] =
               Extract.route_sites(~S{conn |> delete(~p"/x")}, 1, 1)

      assert [%{verb: "POST", path: ["x"]}] =
               Extract.route_sites(~S{conn |> post("/x", "/y")}, 1, 1)
    end

    test "reads no route from a request whose path is a variable or a relative text" do
      assert Extract.route_sites(~S|get(conn, path)|, 1, 1) == []
      assert Extract.route_sites(~S|get(conn, "greet")|, 1, 1) == []
      assert Extract.route_sites(~S|get("/x")|, 1, 1) == []
      assert Extract.route_sites(~S|Map.get(map, :key)|, 1, 1) == []
    end

    test "reads no route from a remote call on a module that is not a test module" do
      assert Extract.route_sites(~S|Map.get(params, "/")|, 1, 1) == []
      assert Extract.route_sites(~S|Map.put(acc, "/", 1)|, 1, 1) == []
      assert Extract.route_sites(~S|Client.get(client, "/users")|, 1, 1) == []

      assert [%{verb: "GET", path: ["x"]}] =
               Extract.route_sites(~S|SampleWeb.ConnTest.get(conn, "/x")|, 1, 1)

      assert [%{verb: "GET", path: ["hello"]}] =
               Extract.route_sites(~S|Phoenix.LiveViewTest.live(conn, "/hello")|, 1, 1)
    end

    test "reads a heredoc path without the newline before its closing delimiter" do
      text = ~s|get(conn, """\n/heredoc\n""")|
      assert [%{path: ["heredoc"]}] = Extract.route_sites(text, 1, 1)
    end

    @conn_test ~S'''
    defmodule SampleWeb.PageControllerTest do
      use SampleWeb.ConnCase

      test "shows the page", %{conn: conn} do
        conn = get(conn, ~p"/greet")
        assert html_response(conn, 200)
      end
    end
    '''

    test "carries the requests a test makes on its definition" do
      {:ok, %{definitions: defs}} = Extract.extract(@conn_test, "test/sample_web/page_test.exs")

      assert find(defs, "SampleWeb.PageControllerTest", :"test shows the page").route_sites == [
               %{verb: "GET", path: ["greet"], range: %{start: {5, 22}, end: {5, 32}}}
             ]
    end
  end

  describe "ExUnit blocks" do
    @test_source ~S"""
    defmodule SampleApp.GreeterTest do
      use ExUnit.Case, register: false

      setup :named

      setup do
        {:ok, name: String.upcase("ada")}
      end

      setup_all do
        :ok
      end

      test "greets", %{name: name} do
        assert String.length(name) == 3
      end

      test "later"

      describe "greet/2" do
        setup context do
          {:ok, context}
        end

        test "says hello", context do
          helper(context)
        end

        # Runs the slow path.
        @tag :slow
        @tag timeout: 1000
        test "shouts" do
          helper(%{})
        end
      end

      defp named(_context), do: :ok
      defp helper(context), do: context
    end
    """

    test "reads tests and setups as definitions under the names ExUnit compiles" do
      {:ok, %{definitions: defs}} = Extract.extract(@test_source, "test/greeter_test.exs")

      assert Enum.map(defs, &{&1.name, &1.kind, &1.arity}) == [
               {:__ex_unit_setup_1, :setup, 1},
               {:__ex_unit_setup_all_0, :setup, 1},
               {:"test greets", :test, 1},
               {:__ex_unit_setup_0_0, :setup, 1},
               {:"test greet/2 says hello", :test, 1},
               {:"test greet/2 shouts", :test, 1},
               {:named, :defp, 1},
               {:helper, :defp, 1}
             ]

      assert %{test: %{describe: nil, name: "greets", tags: []}, arities: [1]} =
               find(defs, "SampleApp.GreeterTest", :"test greets")

      assert %{test: %{describe: "greet/2", name: "says hello", tags: []}} =
               find(defs, "SampleApp.GreeterTest", :"test greet/2 says hello")

      assert %{test: nil} = find(defs, "SampleApp.GreeterTest", :__ex_unit_setup_1)
      refute Map.has_key?(find(defs, "SampleApp.GreeterTest", :helper), :test)
    end

    test "a tagged test's span starts at its leading comment and carries its tags" do
      {:ok, %{definitions: defs}} = Extract.extract(@test_source, "test/greeter_test.exs")
      shouts = find(defs, "SampleApp.GreeterTest", :"test greet/2 shouts")

      assert shouts.test == %{describe: "greet/2", name: "shouts", tags: ["slow", "timeout"]}
      assert {shouts.start_line, shouts.end_line} == {29, 34}
      assert String.starts_with?(shouts.source, "    # Runs the slow path.")
    end

    test "collects a test's and a setup's call sites from their bodies" do
      {:ok, %{definitions: defs}} = Extract.extract(@test_source, "test/greeter_test.exs")

      greets = find(defs, "SampleApp.GreeterTest", :"test greets")
      assert site(greets, 15, 19).callee == %{module: "String", name: :length, arity: 1}
      assert {greets.start_line, greets.end_line} == {14, 16}

      setup = find(defs, "SampleApp.GreeterTest", :__ex_unit_setup_1)
      assert site(setup, 7, 24).callee == %{module: "String", name: :upcase, arity: 1}
    end

    test "collects the call sites of every clause of a test's block" do
      source = ~S"""
      defmodule SampleApp.RescuingTest do
        use ExUnit.Case, register: false

        test "shouts on failure" do
          raise "quiet"
        rescue
          error -> Formatter.shout(error.message)
        end
      end
      """

      {:ok, %{definitions: [test]}} = Extract.extract(source, "test/rescuing_test.exs")

      assert site(test, 5, 5).callee == %{module: nil, name: :raise, arity: 1}
      assert site(test, 7, 24).callee == %{module: "Formatter", name: :shout, arity: 1}
    end

    test "names match the functions ExUnit compiles, and a pending test is no definition" do
      {:ok, %{definitions: defs}} = Extract.extract(@test_source, "test/greeter_test.exs")
      [{module, _bytecode}] = Code.compile_string(@test_source, "test/greeter_test.exs")

      compiled =
        for {name, 1} <- module.module_info(:functions),
            text = Atom.to_string(name),
            String.starts_with?(text, "test ") or String.starts_with?(text, "__ex_unit_setup"),
            do: name

      :code.purge(module)
      :code.delete(module)

      extracted = for %{kind: kind, name: name} <- defs, kind in [:test, :setup], do: name
      assert Enum.sort(compiled) == Enum.sort([:"test later" | extracted])
    end

    test "numbers setups the way ExUnit does, counting named callbacks and describes" do
      source = ~S"""
      defmodule SampleApp.CountedTest do
        use ExUnit.Case, register: false

        setup [:a, :b]
        setup {SampleApp.Support, :c}

        setup do
          :ok
        end

        setup_all :a

        setup_all _context do
          :ok
        end

        describe "first" do
          test "one", do: :ok
        end

        describe "second" do
          setup :a

          setup do
            :ok
          end
        end

        setup do
          :ok
        end

        defp a(_context), do: :ok
        defp b(_context), do: :ok
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "test/counted_test.exs")

      assert for(%{kind: :setup, name: name} <- defs, do: name) == [
               :__ex_unit_setup_3,
               :__ex_unit_setup_all_1,
               :__ex_unit_setup_1_1,
               :__ex_unit_setup_4
             ]

      assert %{kind: :test, test: %{describe: "first", name: "one"}} =
               find(defs, "SampleApp.CountedTest", :"test first one")
    end

    test "a named setup, a pending test and a describe add no definition of their own" do
      source = ~S"""
      defmodule SampleApp.QuietTest do
        use ExUnit.Case

        setup :named
        setup [:named, :named]
        test "pending"

        describe "nothing yet" do
          test "also pending"
        end

        defp named(_context), do: :ok
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "test/quiet_test.exs")
      assert Enum.map(defs, &{&1.name, &1.kind}) == [{:named, :defp}]
    end
  end

  describe "double sites" do
    @doubles_source ~S"""
    defmodule SampleApp.ClockTest do
      use ExUnit.Case, async: true
      import Mox
      alias SampleApp.Mocks.Clock

      setup do
        stub(Clock, :now, fn -> 0 end)
        :ok
      end

      test "reads the clock" do
        expect(SampleApp.GeoMock, :lookup, fn _ip -> {:ok, "PT"} end)
        Mox.expect(Clock, :at, 2, fn zone, when_ when is_binary(zone) -> when_ end)
        Mox.stub(SampleApp.GeoMock, :lookup, &SampleApp.Geo.lookup/1)
        expect(mock(), :lookup, fn _ip -> :ok end)
        expect(SampleApp.GeoMock, name(), fn _ip -> :ok end)
        SampleApp.GeoMock |> expect(:country, fn -> "PT" end) |> stub(:city, fn _a, _b -> "" end)
      end

      defp mock, do: SampleApp.GeoMock
      defp name, do: :lookup
    end
    """

    test "records each expect and stub on a literal mock and function, local or on Mox, at the arity its fn or capture writes" do
      {:ok, %{definitions: defs}} = Extract.extract(@doubles_source, "test/clock_test.exs")
      test = find(defs, "SampleApp.ClockTest", :"test reads the clock")

      assert test.double_sites == [
               %{
                 mock: "SampleApp.GeoMock",
                 function: :lookup,
                 arity: 1,
                 range: %{start: {12, 5}, end: {12, 11}}
               },
               %{
                 mock: "SampleApp.Mocks.Clock",
                 function: :at,
                 arity: 2,
                 range: %{start: {13, 5}, end: {13, 15}}
               },
               %{
                 mock: "SampleApp.GeoMock",
                 function: :lookup,
                 arity: 1,
                 range: %{start: {14, 5}, end: {14, 13}}
               },
               %{
                 mock: "SampleApp.GeoMock",
                 function: :country,
                 arity: 0,
                 range: %{start: {17, 26}, end: {17, 32}}
               },
               %{
                 mock: "SampleApp.GeoMock",
                 function: :city,
                 arity: 2,
                 range: %{start: {17, 62}, end: {17, 66}}
               }
             ]
    end

    test "records a setup's stubs, and none on a definition that writes no expectation" do
      {:ok, %{definitions: defs}} = Extract.extract(@doubles_source, "test/clock_test.exs")

      assert [%{mock: "SampleApp.Mocks.Clock", function: :now, arity: 0}] =
               find(defs, "SampleApp.ClockTest", :__ex_unit_setup_0).double_sites

      assert find(defs, "SampleApp.ClockTest", :mock).double_sites == []
    end
  end

  describe "clauses and arms" do
    @branch_source ~S"""
    defmodule SampleApp.Branches do
      def classify(:ok), do: :fine

      def classify(value) do
        case value do
          {:ok, inner} ->
            inner

          :error ->
            nil

          _other ->
            :unknown
        end
      end

      def load(id) do
        with {:ok, row} <- fetch(id),
             {:ok, parsed} <- parse(row) do
          parsed
        else
          {:error, :missing} -> nil
          {:error, reason} -> reason
        end
      end

      def sign(n) do
        cond do
          n > 0 -> :positive
          true -> :other
        end
      end

      def wait do
        receive do
          {:ping, from} -> send(from, :pong)
        after
          100 -> :timeout
        end
      end

      def attempt(fun) do
        try do
          fun.()
        rescue
          e in RuntimeError -> e
        else
          value -> value
        end
      end

      def mappers do
        two = fn
          :a -> 1
          _ -> 2
        end

        one = fn x -> x end
        {two, one}
      end

      def nested(x) do
        case x do
          {:ok, y} ->
            case y do
              1 -> :one
              _ -> :many
            end

          _ ->
            :none
        end
      end
    end
    """

    test "records the lines of every clause, in source order" do
      {:ok, %{definitions: defs}} = Extract.extract(@branch_source, "lib/branches.ex")

      assert find(defs, "SampleApp.Branches", :classify).clauses == [{2, 2}, {4, 15}]
      assert find(defs, "SampleApp.Branches", :wait).clauses == [{34, 40}]
    end

    test "records the lines of every arm of every branching construct" do
      {:ok, %{definitions: defs}} = Extract.extract(@branch_source, "lib/branches.ex")
      arms = &find(defs, "SampleApp.Branches", &1).arms

      assert arms.(:classify) == [{6, 7}, {9, 10}, {12, 13}]
      assert arms.(:load) == [{22, 22}, {23, 23}]
      assert arms.(:sign) == [{29, 29}, {30, 30}]
      assert arms.(:wait) == [{36, 36}, {38, 38}]
      assert arms.(:attempt) == [{46, 46}, {48, 48}]
      assert arms.(:mappers) == [{54, 54}, {55, 55}]
      assert arms.(:nested) == [{64, 68}, {66, 66}, {67, 67}, {70, 71}]
    end

    test "reads clauses written in keyword form as arms" do
      source = ~S"""
      defmodule SampleApp.Terse do
        def load(x), do: with({:ok, y} <- x, do: y, else: (_ -> :err))

        def pick(x) do
          case(x, do: (1 -> :a; _ -> :b))
        end
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "lib/terse.ex")

      assert find(defs, "SampleApp.Terse", :load).arms == [{2, 2}]
      assert find(defs, "SampleApp.Terse", :pick).arms == [{5, 5}, {5, 5}]
    end

    test "counts no clause for a head written without a body" do
      source = ~S"""
      defmodule SampleApp.Defaults do
        def pad(text, width \\ 8)

        def pad(text, width) when is_binary(text), do: String.pad_leading(text, width)

        def pad(text, width) do
          pad(to_string(text), width)
        end
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "lib/defaults.ex")

      assert find(defs, "SampleApp.Defaults", :pad).clauses == [{4, 4}, {6, 8}]
    end

    test "reads a try's after and the rescue a def writes directly as arms" do
      source = ~S"""
      defmodule SampleApp.Guarded do
        def run(fun) do
          try do
            fun.()
          after
            :cleanup
          end
        end

        def safe(fun) do
          fun.()
        rescue
          _error -> :failed
        end
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "lib/guarded.ex")

      assert find(defs, "SampleApp.Guarded", :run).arms == [{5, 6}]
      assert find(defs, "SampleApp.Guarded", :safe).arms == [{13, 13}]
    end

    test "records a test or a setup as one clause, with the arms its body holds" do
      source = ~S"""
      defmodule SampleApp.BranchesTest do
        use ExUnit.Case

        setup do
          :ok
        end

        test "branches" do
          case 1 do
            1 -> :ok
          end
        end
      end
      """

      {:ok, %{definitions: defs}} = Extract.extract(source, "test/branches_test.exs")

      setup = find(defs, "SampleApp.BranchesTest", :__ex_unit_setup_0)
      assert {setup.clauses, setup.arms} == {[{4, 6}], []}

      test = find(defs, "SampleApp.BranchesTest", :"test branches")
      assert {test.clauses, test.arms} == {[{8, 12}], [{10, 10}]}
    end
  end

  defp module(source, name) do
    {:ok, %{modules: modules}} = Extract.extract(source, "lib/a.ex")
    Enum.find(modules, &(&1.name == name))
  end

  defp find(defs, module, name), do: Enum.find(defs, &(&1.module == module and &1.name == name))

  defp site(def, line, column),
    do: Enum.find(def.call_sites, &(&1.line == line and &1.column == column))
end
