defmodule Grasp.IndexTest do
  use ExUnit.Case, async: true

  alias Grasp.Index

  defp document do
    %{
      "version" => 1,
      "generated_at" => "2026-09-15T10:00:00Z",
      "project" => %{"app" => "my_app", "root" => "/tmp/my_app", "elixirc_paths" => ["lib"]},
      "git" => nil,
      "modules" => [
        %{
          "name" => "MyApp.Wallets",
          "file" => "lib/my_app/wallets.ex",
          "line" => 1,
          "behaviours" => []
        }
      ],
      "entry_points" => [
        %{
          "kind" => "route",
          "label" => "POST /wallets",
          "target" => "MyAppWeb.WalletController.create/2",
          "meta" => %{"verb" => "POST", "path" => "/wallets"}
        },
        %{
          "kind" => "route",
          "label" => "PUT /wallets",
          "target" => "MyAppWeb.WalletController.create/2",
          "meta" => %{"verb" => "PUT", "path" => "/wallets"}
        },
        %{
          "kind" => "oban_worker",
          "label" => "MyApp.CreditWorker",
          "target" => "MyApp.Wallets.credit/2",
          "meta" => %{"queue" => "wallets"}
        }
      ],
      "functions" => [
        function("MyApp.Wallets.credit/3", "MyApp.Wallets", "credit", 3, [2, 3], [
          %{
            "target" => "MyApp.Ledger.post/2",
            "kind" => "remote",
            "range" => %{"start" => [10, 5], "end" => [10, 16]}
          }
        ]),
        Map.put(
          function("MyApp.Wallets.debit/3", "MyApp.Wallets", "debit", 3, [3], []),
          "span",
          %{"start_line" => 5, "end_line" => 6}
        ),
        function(
          "MyAppWeb.WalletController.create/2",
          "MyAppWeb.WalletController",
          "create",
          2,
          [2],
          [
            %{
              "target" => "MyApp.Wallets.credit/2",
              "kind" => "remote",
              "range" => %{"start" => [8, 5], "end" => [8, 19]}
            }
          ],
          [%{"target" => "MyApp.Wallets.debit/3", "kind" => "remote", "line" => 12}]
        ),
        Map.put(
          function("MyApp.Ledger.post/2", "MyApp.Ledger", "post", 2, [2], []),
          "change",
          "modified"
        )
      ]
    }
  end

  defp function(id, module, name, arity, arities, calls, hidden \\ []) do
    %{
      "id" => id,
      "module" => module,
      "name" => name,
      "arity" => arity,
      "arities" => arities,
      "kind" => "def",
      "file" => "lib/x.ex",
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def #{name}",
      "calls" => calls,
      "hidden_calls" => hidden,
      "change" => "unchanged",
      "base_source" => nil,
      "removed" => false
    }
  end

  setup do
    {:ok, index} = Index.from_document(document())
    %{index: index}
  end

  test "fetch_function/2 finds by canonical id and by default-argument arity", %{index: index} do
    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/3")

    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/2")

    assert :error = Index.fetch_function(index, "MyApp.Wallets.credit/9")
  end

  test "callers/2 inverts calls and hidden calls, resolving aliases", %{index: index} do
    assert Index.callers(index, "MyApp.Wallets.credit/3") == [
             "MyAppWeb.WalletController.create/2"
           ]

    assert Index.callers(index, "MyApp.Wallets.debit/3") == ["MyAppWeb.WalletController.create/2"]
    assert Index.callers(index, "MyApp.Ledger.post/2") == ["MyApp.Wallets.credit/3"]
    assert Index.callers(index, "Nobody.calls/0") == []
  end

  test "callees/2 lists resolved targets including hidden calls", %{index: index} do
    assert Index.callees(index, "MyAppWeb.WalletController.create/2") == [
             "MyApp.Wallets.credit/3",
             "MyApp.Wallets.debit/3"
           ]

    assert Index.callees(index, "MyApp.Wallets.credit/2") == ["MyApp.Ledger.post/2"]
  end

  test "search/3 ranks exact, then substring, then subsequence matches", %{index: index} do
    assert ids(Index.search(index, "MyApp.Wallets.debit/3")) == ["MyApp.Wallets.debit/3"]
    assert ids(Index.search(index, "credit")) == ["MyApp.Wallets.credit/3"]
    assert ["MyApp.Wallets.credit/3" | _] = ids(Index.search(index, "walcre"))

    assert ids(Index.search(index, "wallets")) == [
             "MyApp.Wallets.debit/3",
             "MyApp.Wallets.credit/3"
           ]

    assert ids(Index.search(index, "wallet")) == [
             "MyApp.Wallets.debit/3",
             "MyApp.Wallets.credit/3",
             "MyAppWeb.WalletController.create/2"
           ]

    assert Index.search(index, "zzzzzz") == []
    assert Index.search(index, "   ") == []
    assert length(Index.search(index, "a", 2)) == 2
  end

  test "functions_in_module/2 lists a module's functions in source order", %{index: index} do
    assert ids(Index.functions_in_module(index, "MyApp.Wallets")) == [
             "MyApp.Wallets.credit/3",
             "MyApp.Wallets.debit/3"
           ]

    assert Index.functions_in_module(index, "Nope") == []
  end

  test "entry_points_for/2 groups entries by target, resolving alias arities", %{index: index} do
    assert [%{"label" => "POST /wallets"}, %{"label" => "PUT /wallets"}] =
             Index.entry_points_for(index, "MyAppWeb.WalletController.create/2")

    assert [%{"kind" => "oban_worker", "label" => "MyApp.CreditWorker"}] =
             Index.entry_points_for(index, "MyApp.Wallets.credit/3")

    assert Index.entry_points_for(index, "MyApp.Wallets.credit/2") ==
             Index.entry_points_for(index, "MyApp.Wallets.credit/3")

    assert Index.entry_points_for(index, "MyApp.Wallets.debit/3") == []
  end

  test "entry_points/1 drops a record that names no target" do
    document = Map.update!(document(), "entry_points", &["nonsense", %{"kind" => "route"} | &1])

    assert {:ok, index} = Index.from_document(document)
    assert length(Index.entry_points(index)) == 3
    assert Enum.all?(Index.entry_points(index), &is_binary(&1["target"]))
  end

  test "changed_functions/1 returns everything not unchanged", %{index: index} do
    assert ids(Index.changed_functions(index)) == ["MyApp.Ledger.post/2"]
  end

  test "load/1 reads a document from disk", %{index: index} do
    path = tmp_path()
    File.write!(path, Jason.encode!(document()))

    assert {:ok, loaded} = Index.load(path)
    assert Index.functions(loaded) == Index.functions(index)

    assert Index.modules(loaded) == [
             %{
               "name" => "MyApp.Wallets",
               "file" => "lib/my_app/wallets.ex",
               "line" => 1,
               "behaviours" => []
             }
           ]

    assert {:error, _} = Index.load(path <> ".missing")
  end

  test "load/1 reports a document version it cannot read" do
    path = tmp_path()
    File.write!(path, Jason.encode!(%{"version" => 2, "functions" => []}))

    assert Index.load(path) == {:error, {:unsupported_document, 2}}
  end

  test "from_document/1 rejects a document that is not an index" do
    assert Index.from_document(%{}) == {:error, {:unsupported_document, nil}}
  end

  test "load/1 reports a top-level document that is not an object" do
    path = tmp_path()
    File.write!(path, Jason.encode!([]))

    assert Index.load(path) == {:error, {:unsupported_document, nil}}
  end

  test "from_document/1 reports a function record that is not an object" do
    document = Map.update!(document(), "functions", &["not a record" | &1])

    assert {:error, {:invalid_record, _}} = Index.from_document(document)
  end

  test "from_document/1 falls back to arity for a record with no arities" do
    record = document() |> Map.fetch!("functions") |> hd() |> Map.delete("arities")
    document = Map.put(document(), "functions", [record])

    assert {:ok, index} = Index.from_document(document)

    assert {:ok, %{"id" => "MyApp.Wallets.credit/3"}} =
             Index.fetch_function(index, "MyApp.Wallets.credit/3")

    assert :error = Index.fetch_function(index, "MyApp.Wallets.credit/2")
  end

  describe "tests/1" do
    setup do
      {:ok, index} = Index.load("test/fixtures/index.json")
      %{fixture: index}
    end

    test "lists every module of the suite by file: setups, tests by describe, then helpers",
         %{fixture: index} do
      assert [tally, routes, sample_case] = Index.tests(index)

      assert %{module: "SampleApp.TallyTest", file: "test/sample_app/tally_test.exs"} = tally
      assert ids(tally.setups) == ["SampleApp.TallyTest.__ex_unit_setup_0/1"]

      assert [{"handle_call/3", [reply]}, {nil, [init]}] = tally.describes
      assert reply["id"] =~ "replies with the next number"
      assert init["id"] =~ "init keeps the start count"
      assert ids(tally.helpers) == ["SampleApp.TallyTest.init_with/1"]

      assert routes.module == "SampleAppWeb.RoutesTest"
      assert [{nil, [plain, verified]}] = routes.describes
      assert plain["test"]["name"] == "a plain path reaches the controller"
      assert verified["test"]["name"] == "a verified path reaches the controller"

      assert %{module: "SampleApp.SampleCase", describes: [], setups: [_setup]} = sample_case
      assert ids(sample_case.helpers) == ["SampleApp.SampleCase.conn_for/1"]
    end

    test "lists a support module holding no test and no setup, with its helpers" do
      record = %{
        "id" => "MyApp.Factory.build/1",
        "kind" => "def",
        "module" => "MyApp.Factory",
        "name" => "build",
        "arity" => 1,
        "file" => "test/support/factory.ex",
        "span" => %{"start_line" => 2, "end_line" => 2}
      }

      {:ok, index} =
        Index.from_document(%{
          "version" => 1,
          "project" => %{"test_paths" => ["test"]},
          "modules" => [
            %{"name" => "MyApp.Factory", "file" => "test/support/factory.ex"},
            %{"name" => "MyApp.Wallets", "file" => "lib/my_app/wallets.ex"}
          ],
          "functions" => [record]
        })

      assert [%{module: "MyApp.Factory", file: "test/support/factory.ex"} = factory] =
               Index.tests(index)

      assert %{setups: [], describes: []} = factory
      assert ids(factory.helpers) == ["MyApp.Factory.build/1"]
    end

    test "is computed once, when the index is built", %{fixture: index} do
      assert index.tests != []
      assert Index.tests(index) == index.tests
      assert Index.tests(%{index | tests: []}) == []
    end

    test "is empty for an index built without tests", %{index: index} do
      assert Index.tests(index) == []
    end
  end

  test "test_file?/2 reads the project's test paths", %{index: index} do
    {:ok, fixture} = Index.load("test/fixtures/index.json")

    assert Index.test_file?(fixture, "test/sample_app/tally_test.exs")
    assert Index.test_file?(fixture, "test/support/sample_case.ex")
    refute Index.test_file?(fixture, "lib/sample_app/counter.ex")
    refute Index.test_file?(fixture, "testing/x.ex")
    refute Index.test_file?(fixture, nil)
    refute Index.test_file?(index, "test/sample_app/tally_test.exs")
  end

  test "search/3 finds a test by the words of its name, however its id escapes them" do
    record = %{
      "id" => ~S|MyApp.QuoteTest."test says \"hi\""/1|,
      "kind" => "test",
      "module" => "MyApp.QuoteTest",
      "name" => ~S|test says "hi"|,
      "arity" => 1,
      "test" => %{"describe" => nil, "name" => ~S|says "hi"|, "tags" => []}
    }

    {:ok, index} = Index.from_document(%{"version" => 1, "functions" => [record]})

    assert ids(Index.search(index, ~S|says "hi"|)) == [record["id"]]
    assert ids(Index.search(index, ~S|quotetest says "hi"|)) == [record["id"]]
  end

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "grasp-index-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp ids(records), do: Enum.map(records, & &1["id"])
end
