defmodule Grasp.Index.ChangesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.{Builder, Changes, Extract, Join}

  @base_a ~S"""
  defmodule A do
    def f, do: :f

    def g(x) do
      x + 1
    end

    def h, do: :h
  end
  """

  @current_a ~S"""
  defmodule A do
    def f, do: :f

    def g(x) do
      x + 2
    end

    def new, do: :new
  end
  """

  @untouched ~S"""
  defmodule U do
    def k, do: :k
  end
  """

  @moved ~S"""
  defmodule A do
    def f, do: :f
  end
  """

  @base_defaults ~S"""
  defmodule A do
    def f(a), do: a

    def g, do: :g
  end
  """

  @current_defaults ~S"""
  defmodule A do
    def f(a, b \\ 1), do: a + b
  end
  """

  test "classifies added, modified and unchanged functions and appends removed ones" do
    classified =
      Changes.classify(records(@current_a, "lib/a.ex"), %{"lib/a.ex" => @base_a}, ["lib"])

    by_id = by_id(classified)

    assert Enum.map(classified, & &1.id) == ["A.f/0", "A.g/1", "A.new/0", "A.h/0"]

    assert by_id["A.f/0"].change == "unchanged"
    assert by_id["A.f/0"].base_source == nil
    assert by_id["A.f/0"].removed == false

    assert by_id["A.g/1"].change == "modified"
    assert by_id["A.g/1"].base_source =~ "x + 1"
    assert by_id["A.g/1"].source =~ "x + 2"
    assert by_id["A.g/1"].removed == false

    assert by_id["A.new/0"].change == "added"
    assert by_id["A.new/0"].base_source == nil
  end

  test "turns a definition the base holds and the index does not into a removed record" do
    classified =
      Changes.classify(records(@current_a, "lib/a.ex"), %{"lib/a.ex" => @base_a}, ["lib"])

    removed = by_id(classified)["A.h/0"]

    assert removed.change == "removed"
    assert removed.removed == true
    assert removed.calls == []
    assert removed.hidden_calls == []
    assert removed.source == removed.base_source
    assert removed.source =~ "def h, do: :h"
    assert removed.file == "lib/a.ex"
    assert removed.span == %{start_line: 8, end_line: 8}
    assert removed.module == "A"
    assert removed.name == :h
    assert removed.arity == 0
    assert removed.arities == [0]
    assert removed.kind == :def
  end

  test "a removed record keeps the clauses and arms of its base definition" do
    base = ~S"""
    defmodule A do
      def f, do: :f

      def gone(x) do
        case x do
          1 -> :one
          _ -> :other
        end
      end
    end
    """

    classified = Changes.classify(records(@moved, "lib/a.ex"), %{"lib/a.ex" => base}, ["lib"])
    json = Builder.function_json(by_id(classified)["A.gone/1"])

    assert {json["clauses"], json["arms"]} == {[[4, 9]], [[6, 6], [7, 7]]}
  end

  test "a record in a file the diff did not touch is unchanged" do
    records = records(@current_a, "lib/a.ex") ++ records(@untouched, "lib/u.ex")
    classified = Changes.classify(records, %{"lib/a.ex" => @base_a}, ["lib"])

    assert by_id(classified)["U.k/0"].change == "unchanged"
    assert by_id(classified)["A.new/0"].change == "added"
  end

  test "every function of a file the branch added is added" do
    records = records(@current_a, "lib/a.ex") ++ records(@untouched, "lib/u.ex")
    classified = Changes.classify(records, %{"lib/a.ex" => @base_a, "lib/u.ex" => ""}, ["lib"])

    assert by_id(classified)["U.k/0"].change == "added"
  end

  test "a function moved to another file with its text intact is unchanged" do
    classified = Changes.classify(records(@moved, "lib/b.ex"), %{"lib/a.ex" => @base_a}, ["lib"])
    by_id = by_id(classified)

    assert by_id["A.f/0"].change == "unchanged"
    assert by_id["A.f/0"].file == "lib/b.ex"
    assert by_id["A.g/1"].change == "removed"
    assert by_id["A.h/0"].change == "removed"
  end

  test "a function that gains a default argument is modified under its new id, not removed" do
    classified =
      Changes.classify(
        records(@current_defaults, "lib/a.ex"),
        %{"lib/a.ex" => @base_defaults},
        ["lib"]
      )

    by_id = by_id(classified)

    assert Enum.map(classified, & &1.id) == ["A.f/2", "A.g/0"]

    assert by_id["A.f/2"].change == "modified"
    assert by_id["A.f/2"].base_source =~ "def f(a), do: a"
    assert by_id["A.f/2"].removed == false
    assert by_id["A.f/2"].arities == [1, 2]

    refute Enum.any?(classified, &(&1.id == "A.f/1"))
  end

  test "a definition the current file really dropped is still removed" do
    classified =
      Changes.classify(
        records(@current_defaults, "lib/a.ex"),
        %{"lib/a.ex" => @base_defaults},
        ["lib"]
      )

    removed = by_id(classified)["A.g/0"]

    assert removed.change == "removed"
    assert removed.removed == true
    assert removed.source =~ "def g, do: :g"
  end

  @template "<p>{@name}</p>\n"
  @base_template "<p>hello</p>\n"

  test "classifies a template by its whole text" do
    file = "lib/a_web/page_html/show.html.heex"

    modified =
      Changes.classify(template_records(file, @template), %{file => @base_template}, ["lib"])

    assert [%{change: "modified", base_source: @base_template}] = modified

    unchanged =
      Changes.classify(template_records(file, @template), %{file => @template}, ["lib"])

    assert [%{change: "unchanged", base_source: nil}] = unchanged
  end

  test "classifies a template the branch added, and leaves one the diff never touched" do
    file = "lib/a_web/page_html/show.html.heex"

    assert [%{change: "added", base_source: nil}] =
             Changes.classify(template_records(file, @template), %{file => ""}, ["lib"])

    assert [%{change: "unchanged"}] =
             Changes.classify(template_records(file, @template), %{}, ["lib"])
  end

  describe "classify_modules/3" do
    @base_modules ~S'''
    defmodule Kept do
      @moduledoc "Kept as it stands."
    end

    defmodule Edited do
      @moduledoc """
      Edited, as the base had it.
      """
    end

    defmodule Undocumented do
      @moduledoc "Documented at the base."
    end

    defmodule Documented do
    end

    defmodule Gone do
      @moduledoc "Gone from the head."
    end

    defmodule GoneQuietly do
    end
    '''

    @head_modules ~S'''
    defmodule Kept do
      @moduledoc "Kept as it stands."
    end

    defmodule Edited do
      @moduledoc """
      Edited on the branch.
      """
    end

    defmodule Undocumented do
    end

    defmodule Documented do
      @moduledoc false
    end

    defmodule Fresh do
      @moduledoc "A module the branch added."
    end

    defmodule FreshQuietly do
    end
    '''

    test "classifies each moduledoc against the base module of its name" do
      by_name = by_name(classify_modules(@head_modules, %{"lib/m.ex" => @base_modules}))

      assert %{change: "unchanged", base_source: nil, base_doc: nil, removed: false} =
               by_name["Kept"]

      assert %{change: "modified", removed: false} = edited = by_name["Edited"]
      assert edited.base_source =~ "Edited, as the base had it."
      assert edited.source =~ "Edited on the branch."
      assert edited.base_doc == %{text: "Edited, as the base had it.\n", hidden: false}

      assert %{change: "removed", removed: false, doc: nil} =
               undocumented = by_name["Undocumented"]

      assert undocumented.base_source == ~S(  @moduledoc "Documented at the base.")
      assert undocumented.base_doc == %{text: "Documented at the base.", hidden: false}

      assert %{change: "added", base_source: nil, base_doc: nil} = by_name["Documented"]
      assert %{change: "added", base_source: nil} = by_name["Fresh"]
      assert %{change: "unchanged"} = by_name["FreshQuietly"]
    end

    test "turns a documented module the head does not define into a removed module" do
      classified = classify_modules(@head_modules, %{"lib/m.ex" => @base_modules})

      assert [%{name: "Gone"} = gone] = Enum.filter(classified, & &1.removed)
      assert List.last(classified) == gone

      assert gone == %{
               name: "Gone",
               file: "lib/m.ex",
               line: 18,
               doc: %{text: "Gone from the head.", hidden: false},
               span: %{start_line: 19, end_line: 19},
               source: ~S(  @moduledoc "Gone from the head."),
               change: "removed",
               base_source: ~S(  @moduledoc "Gone from the head."),
               base_doc: %{text: "Gone from the head.", hidden: false},
               removed: true
             }

      refute Enum.any?(classified, &(&1.name == "GoneQuietly"))
    end

    test "@moduledoc false is a moduledoc: added over none, modified over text" do
      base = ~S"""
      defmodule Hidden do
      end

      defmodule Silenced do
        @moduledoc "Spoke at the base."
      end
      """

      head = ~S"""
      defmodule Hidden do
        @moduledoc false
      end

      defmodule Silenced do
        @moduledoc false
      end
      """

      by_name = by_name(classify_modules(head, %{"lib/m.ex" => base}))

      assert %{change: "added", doc: %{text: nil, hidden: true}} = by_name["Hidden"]

      assert %{
               change: "modified",
               doc: %{text: nil, hidden: true},
               base_doc: %{text: "Spoke at the base.", hidden: false}
             } = by_name["Silenced"]
    end

    test "a module that moved to another file with the same moduledoc is unchanged" do
      base = ~S"""
      defmodule Moving do
        @moduledoc "Moves."
      end
      """

      head = ~S"""
      defmodule Moving do
        @moduledoc "Moves."
      end
      """

      {:ok, %{modules: modules}} = Extract.extract(head, "lib/b.ex")

      classified =
        Changes.classify_modules(modules, %{"lib/a.ex" => base, "lib/b.ex" => ""}, ["lib"])

      assert [%{name: "Moving", file: "lib/b.ex", change: "unchanged", removed: false}] =
               classified
    end

    test "a module in a file the diff did not touch is unchanged" do
      assert [%{change: "unchanged", base_source: nil}] =
               classify_modules(~S(defmodule U do @moduledoc "U." end), %{}, "lib/u.ex")
    end

    test "every documented module of a file the branch added is added" do
      assert [%{change: "added"}] =
               classify_modules(
                 ~S(defmodule U do @moduledoc "U." end),
                 %{"lib/u.ex" => ""},
                 "lib/u.ex"
               )
    end

    test "a base source outside the paths invents no removed module" do
      classified =
        Changes.classify_modules([], %{"other/m.ex" => @base_modules}, ["lib"])

      assert classified == []
    end

    test "writes a classified module's record in the shape a function record has" do
      by_name = by_name(classify_modules(@head_modules, %{"lib/m.ex" => @base_modules}))

      assert Builder.module_json(by_name["Edited"], %{"Edited" => ["GenServer"]}) == %{
               "id" => "Edited",
               "kind" => "module",
               "name" => "Edited",
               "file" => "lib/m.ex",
               "line" => 5,
               "behaviours" => ["GenServer"],
               "doc" => %{"text" => "Edited on the branch.\n", "hidden" => false},
               "span" => %{"start_line" => 6, "end_line" => 8},
               "source" =>
                 Enum.join([~S(  @moduledoc """), "  Edited on the branch.", ~S(  """)], "\n"),
               "change" => "modified",
               "base_source" =>
                 Enum.join(
                   [~S(  @moduledoc """), "  Edited, as the base had it.", ~S(  """)],
                   "\n"
                 ),
               "base_doc" => %{"text" => "Edited, as the base had it.\n", "hidden" => false},
               "removed" => false
             }
    end

    test "writes an unclassified module without change facts, and one without a moduledoc without lines" do
      {:ok, %{modules: [module]}} = Extract.extract("defmodule A do\nend\n", "lib/a.ex")

      assert Builder.module_json(module, %{}) == %{
               "id" => "A",
               "kind" => "module",
               "name" => "A",
               "file" => "lib/a.ex",
               "line" => 1,
               "behaviours" => [],
               "doc" => nil
             }
    end
  end

  defp classify_modules(source, compared, file \\ "lib/m.ex") do
    {:ok, %{modules: modules}} = Extract.extract(source, file)
    Changes.classify_modules(modules, compared, ["lib"])
  end

  defp by_name(modules), do: Map.new(modules, &{&1.name, &1})

  defp template_records(file, source) do
    definition = %{
      module: "AWeb.PageHTML",
      name: :show,
      arity: 1,
      arities: [1],
      kind: :template,
      file: file,
      start_line: 1,
      end_line: 1,
      source: source,
      call_sites: [],
      route_sites: [],
      head_positions: [],
      head_ranges: []
    }

    Join.join([definition], [])
  end

  defp records(source, file) do
    {:ok, %{definitions: definitions}} = Extract.extract(source, file)
    Join.join(definitions, [])
  end

  defp by_id(records), do: Map.new(records, &{&1.id, &1})
end
