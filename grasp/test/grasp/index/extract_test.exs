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
             %{name: "Sample", file: "lib/sample.ex", line: 1},
             %{name: "Sample.Nested", file: "lib/sample.ex", line: 13},
             %{name: "Sample.Deep", file: "lib/sample.ex", line: 17}
           ]
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

  defp find(defs, module, name), do: Enum.find(defs, &(&1.module == module and &1.name == name))

  defp site(def, line, column),
    do: Enum.find(def.call_sites, &(&1.line == line and &1.column == column))
end
