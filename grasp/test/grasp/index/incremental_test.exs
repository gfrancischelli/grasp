defmodule Grasp.Index.IncrementalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Grasp.Index.Incremental

  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/index.json", __DIR__)
  @sample_app Path.expand("../../fixtures/sample_app", __DIR__)
  @greeter "lib/sample_app/greeter.ex"
  @html "lib/sample_app_web/greet_html.ex"
  @template "lib/sample_app_web/greet_html/show.html.heex"
  @controller "lib/sample_app_web/greet_controller.ex"
  @mount "SampleAppWeb.HelloLive.mount/3"
  @plain_request ~S(SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1)

  @changed_greeter ~S'''
  defmodule SampleApp.Greeter do
    @moduledoc "Greets people, exercising aliases, imports, defaults, captures and nesting."
    alias SampleApp.Formatter
    import SampleApp.Formatter, only: [shout: 1]

    @doc "Greets someone, loudly if asked."
    @spec greet(String.t(), boolean()) :: String.t()
    def greet(name, loud? \\ false) do
      text = Formatter.trim(name)
      if loud?, do: shout(text), else: text
    end

    @doc "Greets everyone."
    @spec greet_all([String.t()]) :: [String.t()]
    def greet_all(names), do: Enum.map(names, &greet/1)

    @doc "Greets no one in particular."
    @spec greet_none() :: String.t()
    def greet_none, do: shout("nobody")

    defmodule Nested do
      @moduledoc "A nested module calling back into its parent."

      @doc "Greets from inside."
      @spec hello() :: String.t()
      def hello, do: SampleApp.Greeter.greet("nested")
    end
  end
  '''

  @formatter "lib/sample_app/formatter.ex"

  @formatter_with_whisper """
  defmodule SampleApp.Formatter do
    @moduledoc "Formats text."

    @doc "Wraps."
    def wrap(name), do: "[" <> name <> "]"

    @doc "Shouts."
    def shout(text), do: String.upcase(text)

    @doc "Whispers, as the base commit remembers it."
    def whisper(text), do: String.downcase(text)
  end
  """

  setup %{tmp_dir: tmp_dir} do
    document = @fixture |> File.read!() |> Jason.decode!()
    %{document: put_in(document, ["project", "root"], tmp_dir), root: tmp_dir}
  end

  describe "update/5 over a changed Elixir source" do
    setup %{root: root} do
      write(root, @greeter, @changed_greeter)

      events =
        [
          {@greeter, SampleApp.Greeter, {:greet, 2}, "trim(name)",
           {SampleApp.Formatter, :trim, 1}, :remote},
          {@greeter, SampleApp.Greeter, {:greet, 2}, "shout(text)",
           {SampleApp.Formatter, :shout, 1}, :imported},
          {@greeter, SampleApp.Greeter, {:greet_all, 1}, "map(names", {Enum, :map, 2}, :remote},
          {@greeter, SampleApp.Greeter, {:greet_all, 1}, "greet/1",
           {SampleApp.Greeter, :greet, 1}, :local},
          {@greeter, SampleApp.Greeter, {:greet_none, 0}, "shout(\"nobody\")",
           {SampleApp.Formatter, :shout, 1}, :imported},
          {@greeter, SampleApp.Greeter.Nested, {:hello, 0}, "greet(\"nested\")",
           {SampleApp.Greeter, :greet, 1}, :remote}
        ]
        |> Enum.map(&event(&1, @changed_greeter))

      %{events: events}
    end

    test "adds the function the file gained", %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      record = fetch(updated, "SampleApp.Greeter.greet_none/0")
      assert record["file"] == @greeter
      assert record["kind"] == "def"
      assert record["span"] == %{"start_line" => 17, "end_line" => 19}
      assert targets(record) == ["SampleApp.Formatter.shout/1"]
    end

    test "follows a renamed call and leaves no stale record",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      assert targets(fetch(updated, "SampleApp.Greeter.greet/2")) == [
               "SampleApp.Formatter.trim/1",
               "SampleApp.Formatter.shout/1"
             ]

      assert Enum.count(updated["functions"], &(&1["id"] == "SampleApp.Greeter.greet/2")) == 1

      refute Enum.any?(
               updated["functions"],
               &Enum.any?(&1["calls"], fn call ->
                 call["target"] == "SampleApp.Formatter.wrap/1"
               end)
             )
    end

    test "leaves every record of another file exactly as it was",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      before = by_id(Enum.reject(document["functions"], &(&1["file"] == @greeter)))
      assert by_id(Enum.reject(updated["functions"], &(&1["file"] == @greeter))) == before
    end

    test "keeps every test record and resolves the routes a test requests",
         %{document: document, root: root, events: events} do
      tests = Enum.filter(document["functions"], &String.starts_with?(&1["file"], "test/"))
      assert Enum.any?(tests, &(&1["kind"] == "test"))
      assert Enum.any?(tests, &(&1["kind"] == "setup"))

      # The route call is taken off the record and its site left on, so only the update's
      # own resolution can put it back.
      requesting =
        map_record(document, @plain_request, fn record ->
          Map.update!(record, "calls", &Enum.reject(&1, fn call -> call["kind"] == "route" end))
        end)

      assert [%{"path" => ["again"], "verb" => "GET"}] =
               fetch(requesting, @plain_request)["route_sites"]

      {:ok, updated} = update(requesting, root, [@greeter], events)

      assert updated["project"]["test_paths"] == ["test"]

      assert by_id(Enum.reject(tests, &(&1["id"] == @plain_request))) ==
               updated["functions"]
               |> Enum.filter(&String.starts_with?(&1["file"], "test/"))
               |> Enum.reject(&(&1["id"] == @plain_request))
               |> by_id()

      request = fetch(updated, @plain_request)
      kept = fetch(requesting, @plain_request)

      assert Map.delete(request, "calls") == Map.delete(kept, "calls")

      assert Enum.filter(request["calls"], &(&1["kind"] != "route")) == kept["calls"]

      assert %{
               "kind" => "route",
               "target" => "SampleAppWeb.GreetController.again/2",
               "route" => %{"verb" => "GET", "path" => "/again"}
             } = Enum.find(request["calls"], &(&1["kind"] == "route"))
    end

    test "orders records and modules by file and by where in the file they start",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      assert updated["functions"] ==
               Enum.sort_by(
                 updated["functions"],
                 &{&1["file"], &1["span"]["start_line"], &1["id"]}
               )

      assert updated["modules"] ==
               Enum.sort_by(updated["modules"], &{&1["file"], &1["line"], &1["name"]})
    end

    test "drops a positioned event that lands on no call site",
         %{document: document, root: root, events: events} do
      moved = %{
        file: @greeter,
        module: SampleApp.Greeter,
        function: {:greet_none, 0},
        line: 19,
        column: 99,
        target: {SampleApp.Formatter, :wrap, 1},
        kind: :remote
      }

      {:ok, updated} = update(document, root, [@greeter], [moved | events])
      record = fetch(updated, "SampleApp.Greeter.greet_none/0")

      assert record["hidden_calls"] == []
      assert targets(record) == ["SampleApp.Formatter.shout/1"]
    end

    test "recomputes entry points when the application can be introspected",
         %{document: document, root: root, events: events} do
      document = put_in(document, ["project", "app"], "grasp")
      {:ok, updated} = update(document, root, [@greeter], events)

      assert updated["entry_points"] == []
      refute updated["entry_points"] == document["entry_points"]
    end

    test "keeps the records of a file that will not parse",
         %{document: document, root: root, events: events} do
      write(root, @greeter, "defmodule SampleApp.Greeter do\n  def oops(\n")

      {result, log} = with_log(fn -> update(document, root, [@greeter], events) end)
      {:ok, updated} = result

      assert log =~ "could not be read"
      assert log =~ "left as"

      assert fetch(updated, "SampleApp.Greeter.greet/2") ==
               fetch(document, "SampleApp.Greeter.greet/2")

      assert fetch(updated, "SampleApp.Greeter.greet_all/1")
      refute fetch(updated, "SampleApp.Greeter.greet_none/0")

      assert Enum.find(updated["modules"], &(&1["name"] == "SampleApp.Greeter")) ==
               Enum.find(document["modules"], &(&1["name"] == "SampleApp.Greeter"))
    end

    test "drops the records of a file that is no longer there",
         %{document: document, root: root, events: events} do
      File.rm!(Path.join(root, @greeter))
      {:ok, updated} = update(document, root, [@greeter], events)

      refute Enum.any?(updated["functions"], &(&1["file"] == @greeter))
      refute Enum.any?(updated["modules"], &(&1["file"] == @greeter))
      assert fetch(updated, "SampleApp.Formatter.wrap/1")
    end

    test "re-reads the modules the file defines, keeping their behaviours",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      modules = Map.new(updated["modules"], &{&1["name"], &1})

      assert modules["SampleApp.Greeter"]["file"] == @greeter
      assert modules["SampleApp.Greeter"]["behaviours"] == []
      assert modules["SampleApp.Greeter.Nested"]["line"] == 21
      assert modules["SampleApp.Counter"] == counter_module(document)
    end

    test "keeps a call reaching a file it did not rebuild",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      assert targets(fetch(updated, "SampleApp.Greeter.Nested.hello/0")) == [
               "SampleApp.Greeter.greet/1"
             ]
    end

    test "keeps a hidden call whose target lives in a file it did not rebuild",
         %{document: document, root: root, events: events} do
      hidden = %{
        file: @greeter,
        module: SampleApp.Greeter,
        function: {:greet_none, 0},
        line: 19,
        column: nil,
        target: {SampleApp.Formatter, :wrap, 1},
        kind: :remote
      }

      {:ok, updated} = update(document, root, [@greeter], [hidden | events])

      assert fetch(updated, "SampleApp.Greeter.greet_none/0")["hidden_calls"] == [
               %{"target" => "SampleApp.Formatter.wrap/1", "kind" => "remote", "line" => 19}
             ]
    end

    test "ignores events naming a file it is not rebuilding",
         %{document: document, root: root, events: events} do
      stray = %{
        file: "lib/sample_app/formatter.ex",
        module: SampleApp.Formatter,
        function: {:wrap, 1},
        line: 6,
        column: 5,
        target: {String, :trim, 1},
        kind: :remote
      }

      {:ok, updated} = update(document, root, [@greeter], [stray | events])

      assert fetch(updated, "SampleApp.Formatter.wrap/1") ==
               fetch(document, "SampleApp.Formatter.wrap/1")
    end

    test "classifies everything unchanged without a base",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)

      for record <- Enum.filter(updated["functions"], &(&1["file"] == @greeter)) do
        assert record["change"] == "unchanged"
        assert record["base_source"] == nil
        assert record["removed"] == false
      end
    end

    test "keeps the entry points the document holds when the app is not loaded",
         %{document: document, root: root, events: events} do
      {:ok, updated} = update(document, root, [@greeter], events)
      assert updated["entry_points"] == document["entry_points"]
    end
  end

  describe "update/5 over a changed template" do
    test "rebuilds the template through the module that embeds it",
         %{document: document, root: root} do
      copy(root, @html)

      write(root, @template, ~S'''
      <.badge label="bye" />
      <p>gone</p>
      ''')

      {:ok, updated} = update(document, root, [@template], [])

      show = fetch(updated, "SampleAppWeb.GreetHTML.show/1")
      assert show["kind"] == "template"
      assert show["source"] == File.read!(Path.join(root, @template))
      assert show["span"] == %{"start_line" => 1, "end_line" => 2}
      assert fetch(updated, "SampleAppWeb.GreetHTML.badge/1")["file"] == @html
    end
  end

  describe "update/5 over a template that links to a route" do
    test "resolves the link against the routes the document knows",
         %{document: document, root: root} do
      copy(root, @html)
      write(root, @template, ~S|<a href="/greet/bob">again</a>|)

      {:ok, updated} = update(document, root, [@template], [])

      assert %{
               "target" => "SampleAppWeb.GreetController.show/2",
               "kind" => "route",
               "route" => %{"verb" => "GET", "path" => "/greet/:name"}
             } =
               updated
               |> fetch("SampleAppWeb.GreetHTML.show/1")
               |> Map.fetch!("calls")
               |> Enum.find(&(&1["kind"] == "route"))
    end
  end

  describe "update/5 over a file that did not change" do
    test "draws a route edge on a record it did not rebuild",
         %{document: document, root: root} do
      copy(root, @greeter)

      routeless =
        map_record(document, "SampleAppWeb.GreetHTML.show/1", fn record ->
          Map.update!(
            record,
            "calls",
            &Enum.reject(&1, fn call -> call["target"] == @mount end)
          )
        end)

      {:ok, updated} = update(routeless, root, [@greeter], [])

      show = fetch(updated, "SampleAppWeb.GreetHTML.show/1")

      assert %{"kind" => "route", "route" => %{"verb" => "GET", "path" => "/hello"}} =
               Enum.find(show["calls"], &(&1["target"] == @mount))

      kept = fetch(document, "SampleAppWeb.GreetHTML.show/1")
      assert show["source"] == kept["source"]
      assert show["span"] == kept["span"]
    end

    test "reverts an enqueue edge on a record it did not rebuild when the worker is gone",
         %{document: document, root: root} do
      copy(root, @greeter)

      workerless =
        Map.update!(
          document,
          "entry_points",
          &Enum.reject(&1, fn entry -> entry["kind"] == "oban_worker" end)
        )

      {:ok, updated} = update(workerless, root, [@greeter], [])

      calls = updated |> fetch("SampleAppWeb.GreetController.mail/2") |> Map.fetch!("calls")

      assert Enum.find(calls, &(&1["target"] == "SampleApp.Workers.Mailer.perform/1")) == nil

      assert %{"kind" => "remote", "range" => %{"start" => [19, 12], "end" => [19, 40]}} =
               Enum.find(calls, &(&1["target"] == "SampleApp.Workers.Mailer.new/1"))
    end
  end

  describe "update/5 over a source that enqueues a job" do
    test "resolves the call against the worker the document knows",
         %{document: document, root: root} do
      copy(root, @controller)
      source = File.read!(Path.join(root, @controller))

      events = [
        event(
          {@controller, SampleAppWeb.GreetController, {:mail, 2}, "new(%{",
           {SampleApp.Workers.Mailer, :new, 1}, :remote},
          source
        )
      ]

      {:ok, updated} = update(document, root, [@controller], events)

      assert %{
               "target" => "SampleApp.Workers.Mailer.perform/1",
               "kind" => "enqueue",
               "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}
             } =
               updated
               |> fetch("SampleAppWeb.GreetController.mail/2")
               |> Map.fetch!("calls")
               |> Enum.find(&(&1["kind"] == "enqueue"))
    end
  end

  describe "update/5 over a template whose module will not parse" do
    test "keeps the template record too", %{document: document, root: root} do
      write(root, @html, "defmodule SampleAppWeb.GreetHTML do\n  def oops(\n")
      write(root, @template, "<p>rewritten</p>\n")

      {result, _log} = with_log(fn -> update(document, root, [@template], []) end)
      {:ok, updated} = result

      assert fetch(updated, "SampleAppWeb.GreetHTML.show/1") ==
               fetch(document, "SampleAppWeb.GreetHTML.show/1")

      assert fetch(updated, "SampleAppWeb.GreetHTML.badge/1")
    end
  end

  describe "update/5 against a base commit" do
    test "marks the file it rebuilt against what the base holds", %{
      document: document,
      root: root
    } do
      write(root, @greeter, @changed_greeter)
      base = repository(root, @greeter, File.read!(Path.join(@sample_app, @greeter)))

      {:ok, updated} = update(document, root, [@greeter], [], base)

      assert fetch(updated, "SampleApp.Greeter.greet/2")["change"] == "modified"

      assert fetch(updated, "SampleApp.Greeter.greet/2")["base_source"] =~
               "Formatter.wrap(name)"

      assert fetch(updated, "SampleApp.Greeter.greet_none/0")["change"] == "added"
      assert fetch(updated, "SampleApp.Greeter.greet_all/1")["change"] == "unchanged"
    end

    test "keeps the classification it had when git cannot answer",
         %{document: document, root: root} do
      write(root, @greeter, @changed_greeter)
      base = %{root: root, base_sha: String.duplicate("a", 40), paths: ["lib"]}

      {result, log} = with_log(fn -> update(document, root, [@greeter], [], base) end)
      {:ok, updated} = result

      assert log =~ "keep the classification they had"
      assert fetch(updated, "SampleApp.Greeter.Nested.hello/0")["change"] == "added"
      assert fetch(updated, "SampleApp.Greeter.greet/2")["change"] == "unchanged"
      assert fetch(updated, "SampleApp.Greeter.greet_none/0")["change"] == "unchanged"
      assert fetch(updated, "SampleApp.Greeter.greet_none/0")["base_source"] == nil
    end

    test "a function the base removed and this file defines again is not removed",
         %{document: document, root: root} do
      write(root, @formatter, @formatter_with_whisper)
      base = %{root: root, base_sha: String.duplicate("a", 40), paths: ["lib"]}

      {result, _log} = with_log(fn -> update(document, root, [@formatter], [], base) end)
      {:ok, updated} = result
      whisper = fetch(updated, "SampleApp.Formatter.whisper/1")

      assert whisper["removed"] == false
      assert whisper["change"] == "unchanged"
      assert whisper["base_source"] == nil
      assert Enum.count(updated["functions"], &(&1["id"] == "SampleApp.Formatter.whisper/1")) == 1
    end
  end

  describe "update/5 over the moduledocs of a rebuilt file" do
    test "classifies the modules it rebuilt against what the base holds",
         %{document: document, root: root} do
      original = File.read!(Path.join(@sample_app, @greeter))

      base_source =
        original <>
          ~S"""

          defmodule SampleApp.Greeter.Retired do
            @moduledoc "Retired from greeting."
          end
          """

      write(root, @greeter, redocument(@changed_greeter, "Greets people, briefly."))
      base = repository(root, @greeter, base_source)

      {:ok, updated} = update(document, root, [@greeter], [], base)

      greeter = module(updated, "SampleApp.Greeter")
      assert greeter["change"] == "modified"
      assert greeter["doc"] == %{"text" => "Greets people, briefly.", "hidden" => false}
      assert greeter["source"] == ~S(  @moduledoc "Greets people, briefly.")
      assert greeter["base_source"] =~ "Greets people, exercising aliases"
      assert greeter["base_doc"]["text"] =~ "Greets people, exercising aliases"
      assert greeter["removed"] == false

      assert module(updated, "SampleApp.Greeter.Nested")["change"] == "unchanged"

      assert %{
               "change" => "removed",
               "removed" => true,
               "file" => @greeter,
               "doc" => %{"text" => "Retired from greeting."}
             } = module(updated, "SampleApp.Greeter.Retired")

      refute Map.has_key?(module(updated, "SampleApp.Counter"), "change")
    end

    test "keeps each module's classification without a base",
         %{document: document, root: root} do
      document = classify_module(document, "SampleApp.Greeter")
      write(root, @greeter, @changed_greeter)

      {:ok, updated} = update(document, root, [@greeter], [])

      assert %{
               "change" => "modified",
               "base_source" => ~S(  @moduledoc "Greets."),
               "base_doc" => %{"text" => "Greets.", "hidden" => false},
               "removed" => false
             } = module(updated, "SampleApp.Greeter")

      assert module(updated, "SampleApp.Greeter")["doc"]["text"] =~ "Greets people"
      refute Map.has_key?(module(updated, "SampleApp.Greeter.Nested"), "change")
    end

    test "keeps each module's classification when git cannot answer",
         %{document: document, root: root} do
      document = classify_module(document, "SampleApp.Greeter")
      write(root, @greeter, @changed_greeter)
      base = %{root: root, base_sha: String.duplicate("a", 40), paths: ["lib"]}

      {result, _log} = with_log(fn -> update(document, root, [@greeter], [], base) end)
      {:ok, updated} = result

      assert module(updated, "SampleApp.Greeter")["change"] == "modified"
      assert module(updated, "SampleApp.Greeter")["base_source"] == ~S(  @moduledoc "Greets.")
    end

    test "a removed module record the file defines again is dropped",
         %{document: document, root: root} do
      retired = %{
        "id" => "SampleApp.Greeter",
        "kind" => "module",
        "name" => "SampleApp.Greeter",
        "file" => "lib/sample_app/old_greeter.ex",
        "line" => 1,
        "behaviours" => [],
        "doc" => %{"text" => "Greets.", "hidden" => false},
        "change" => "removed",
        "base_source" => ~S(  @moduledoc "Greets."),
        "base_doc" => %{"text" => "Greets.", "hidden" => false},
        "removed" => true
      }

      document = Map.update!(document, "modules", &[retired | &1])
      write(root, @greeter, @changed_greeter)

      {:ok, updated} = update(document, root, [@greeter], [])

      assert [%{"file" => @greeter}] =
               Enum.filter(updated["modules"], &(&1["name"] == "SampleApp.Greeter"))
    end
  end

  defp redocument(source, text),
    do:
      String.replace(
        source,
        ~S(@moduledoc "Greets people, exercising aliases, imports, defaults, captures and nesting."),
        ~s(@moduledoc "#{text}")
      )

  defp classify_module(document, name) do
    Map.update!(document, "modules", fn modules ->
      Enum.map(modules, fn module ->
        if module["name"] == name,
          do:
            Map.merge(module, %{
              "change" => "modified",
              "base_source" => ~S(  @moduledoc "Greets."),
              "base_doc" => %{"text" => "Greets.", "hidden" => false},
              "removed" => false
            }),
          else: module
      end)
    end)
  end

  defp module(document, name), do: Enum.find(document["modules"], &(&1["name"] == name))

  defp update(document, root, changed, events, base \\ nil),
    do: Incremental.update(document, root, changed, events, base)

  defp write(root, relative, source) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp copy(root, relative),
    do: write(root, relative, File.read!(Path.join(@sample_app, relative)))

  # The position a tracer event carries is the one the compiler reports: the line and column
  # the called function's name starts at, which is where the needle is found.
  defp event({file, module, function, needle, target, kind}, source) do
    {line, column} = position(source, needle)

    %{
      file: file,
      module: module,
      function: function,
      line: line,
      column: column,
      target: target,
      kind: kind
    }
  end

  defp position(source, needle) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {text, line} ->
      case :binary.match(text, needle) do
        {at, _length} -> {line, at + 1}
        :nomatch -> nil
      end
    end)
  end

  # A repository holding the untouched fixture source, so `git show` has a base to read.
  defp repository(root, relative, source) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end
    git.(["init", "--quiet"])
    git.(["config", "user.email", "grasp@example.com"])
    git.(["config", "user.name", "Grasp"])

    kept = File.read!(Path.join(root, relative))
    File.write!(Path.join(root, relative), source)
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "base"])
    File.write!(Path.join(root, relative), kept)

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    %{root: root, base_sha: String.trim(sha), paths: ["lib"]}
  end

  defp map_record(document, id, fun) do
    Map.update!(document, "functions", fn records ->
      Enum.map(records, fn record ->
        if record["id"] == id, do: fun.(record), else: record
      end)
    end)
  end

  defp by_id(records), do: Map.new(records, &{&1["id"], &1})

  defp fetch(document, id), do: Enum.find(document["functions"], &(&1["id"] == id))

  defp targets(record), do: Enum.map(record["calls"], & &1["target"])

  defp counter_module(document),
    do: Enum.find(document["modules"], &(&1["name"] == "SampleApp.Counter"))
end
