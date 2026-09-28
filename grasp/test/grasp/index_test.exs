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

  describe "tests_for/3" do
    test "answers a test calling the function directly at one hop" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "credits"), hops: 1}
             ]
    end

    test "reaches through a helper of the test module at two hops" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.WalletsTest.credit_one/0", "MyApp.WalletsTest", [
            "MyApp.Wallets.credit/2"
          ]),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.WalletsTest.credit_one/0"])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "credits"), hops: 2}
             ]
    end

    test "reaches through a route call to the controller action" do
      route = %{"target" => "MyAppWeb.WalletController.create/2", "kind" => "route"}

      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyAppWeb.WalletController.create/2", "MyAppWeb.WalletController", [
            "MyApp.Wallets.credit/2"
          ]),
          "MyAppWeb.WalletControllerTest"
          |> test_record("posts", [])
          |> Map.put("calls", [route])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyAppWeb.WalletControllerTest", "posts"), hops: 2}
             ]
    end

    test "counts a setup for every test of its module at the setup's hop" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          setup_record("MyApp.WalletsTest", ["MyApp.Wallets.credit/2"]),
          test_record("MyApp.WalletsTest", "a", []),
          test_record("MyApp.WalletsTest", "b", []),
          test_record("MyApp.OtherTest", "c", [])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "a"), hops: 1},
               %{test: test_id("MyApp.WalletsTest", "b"), hops: 1}
             ]
    end

    test "keeps a test met directly nearer than the setup of its module" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.WalletsTest.seed/0", "MyApp.WalletsTest", ["MyApp.Wallets.credit/2"]),
          setup_record("MyApp.WalletsTest", ["MyApp.WalletsTest.seed/0"]),
          test_record("MyApp.WalletsTest", "a", ["MyApp.Wallets.credit/2"]),
          test_record("MyApp.WalletsTest", "b", [])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "a"), hops: 1},
               %{test: test_id("MyApp.WalletsTest", "b"), hops: 2}
             ]
    end

    test "keeps the nearest distance when two paths reach a test" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.A.one/0", "MyApp.A", ["MyApp.Wallets.credit/2"]),
          record("MyApp.A.two/0", "MyApp.A", ["MyApp.A.one/0"]),
          test_record("MyApp.WalletsTest", "a", ["MyApp.A.two/0", "MyApp.A.one/0"])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "a"), hops: 2}
             ]
    end

    test "stops after max_hops, four by default" do
      chain =
        for n <- 1..4 do
          record("MyApp.C.f#{n}/0", "MyApp.C", ["MyApp.C.f#{n - 1}/0"])
        end

      index =
        reach_index(
          [record("MyApp.C.f0/0", "MyApp.C", [])] ++
            chain ++
            [
              test_record("MyApp.CTest", "far", ["MyApp.C.f4/0"]),
              test_record("MyApp.CTest", "near", ["MyApp.C.f1/0"])
            ]
        )

      assert Index.tests_for(index, "MyApp.C.f0/0") == [
               %{test: test_id("MyApp.CTest", "near"), hops: 2}
             ]

      assert Index.tests_for(index, "MyApp.C.f0/0", 5) == [
               %{test: test_id("MyApp.CTest", "near"), hops: 2},
               %{test: test_id("MyApp.CTest", "far"), hops: 5}
             ]

      assert Index.tests_for(index, "MyApp.C.f0/0", 2) == [
               %{test: test_id("MyApp.CTest", "near"), hops: 2}
             ]

      assert Index.tests_for(index, "MyApp.C.f0/0", 1) == []
    end

    test "terminates on a cycle" do
      index =
        reach_index([
          record("MyApp.A.a/0", "MyApp.A", ["MyApp.A.b/0"]),
          record("MyApp.A.b/0", "MyApp.A", ["MyApp.A.a/0"]),
          test_record("MyApp.ATest", "a", ["MyApp.A.b/0"])
        ])

      assert Index.tests_for(index, "MyApp.A.a/0", 10) == [
               %{test: test_id("MyApp.ATest", "a"), hops: 2}
             ]
    end

    test "resolves a default-argument arity to its definition" do
      index =
        reach_index([
          Map.put(record("MyApp.Wallets.credit/3"), "arities", [2, 3]),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"])
        ])

      expected = [%{test: test_id("MyApp.WalletsTest", "credits"), hops: 1}]
      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == expected
      assert Index.tests_for(index, "MyApp.Wallets.credit/3") == expected
    end

    test "sorts by hops, then by test id" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.H.h/0", "MyApp.H", ["MyApp.Wallets.credit/2"]),
          test_record("MyApp.WalletsTest", "a", ["MyApp.H.h/0"]),
          test_record("MyApp.WalletsTest", "c", ["MyApp.Wallets.credit/2"]),
          test_record("MyApp.WalletsTest", "b", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.credit/2") == [
               %{test: test_id("MyApp.WalletsTest", "b"), hops: 1},
               %{test: test_id("MyApp.WalletsTest", "c"), hops: 1},
               %{test: test_id("MyApp.WalletsTest", "a"), hops: 2}
             ]
    end

    test "answers nothing for an unreached function, an unknown id or a test" do
      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.Wallets.debit/2"),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.tests_for(index, "MyApp.Wallets.debit/2") == []
      assert Index.tests_for(index, "MyApp.Nope.none/0") == []
      assert Index.tests_for(index, test_id("MyApp.WalletsTest", "credits")) == []
    end

    test "finds the fixture's tests reaching a function" do
      {:ok, index} = Index.load("test/fixtures/index.json")

      assert [%{test: direct, hops: 1}] =
               Index.tests_for(index, "SampleApp.Counter.handle_call/3")

      assert direct =~ "replies with the next number"

      assert [%{test: helper, hops: 2}] = Index.tests_for(index, "SampleApp.Counter.init/1")
      assert helper =~ "init keeps the start count"
    end
  end

  describe "untested_changes/1" do
    test "is the added and modified application functions no test reaches, sorted by id" do
      index =
        reach_index([
          changed(record("MyApp.Wallets.debit/2"), "modified"),
          changed(record("MyApp.Wallets.credit/2"), "added"),
          changed(record("MyApp.Wallets.audit/1"), "added"),
          changed(record("MyApp.Wallets.close/1"), "unchanged"),
          record("MyApp.Wallets.open/1"),
          changed(
            test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"]),
            "added"
          )
        ])

      assert ids(Index.untested_changes(index)) == [
               "MyApp.Wallets.audit/1",
               "MyApp.Wallets.debit/2"
             ]
    end

    test "leaves out removed functions, tests, setups and functions under the test paths" do
      helper =
        "MyApp.Factory.build/1"
        |> record("MyApp.Factory")
        |> Map.put("file", "test/support/factory.ex")
        |> changed("added")

      removed =
        "MyApp.Wallets.gone/0"
        |> record()
        |> Map.put("removed", true)
        |> changed("removed")

      {:ok, index} =
        Index.from_document(%{
          "version" => 1,
          "project" => %{"test_paths" => ["test"]},
          "functions" => [
            helper,
            removed,
            changed(record("MyApp.Wallets.lone/0"), "modified"),
            changed(test_record("MyApp.WalletsTest", "credits", []), "added"),
            changed(setup_record("MyApp.WalletsTest", []), "added")
          ]
        })

      assert ids(Index.untested_changes(index)) == ["MyApp.Wallets.lone/0"]
    end

    test "counts a function reached only past the default bound as untested" do
      chain =
        for n <- 0..4 do
          calls = if n == 0, do: [], else: ["MyApp.C.f#{n - 1}/0"]
          changed(record("MyApp.C.f#{n}/0", "MyApp.C", calls), "modified")
        end

      index = reach_index(chain ++ [test_record("MyApp.CTest", "far", ["MyApp.C.f4/0"])])

      assert ids(Index.untested_changes(index)) == ["MyApp.C.f0/0"]
    end

    test "answers nothing for an index built without a base ref" do
      index =
        reach_index([
          record("MyApp.Wallets.debit/2"),
          test_record("MyApp.WalletsTest", "credits", [])
        ])

      assert Index.untested_changes(index) == []
    end

    test "is the fixture's added function no test reaches" do
      {:ok, index} = Index.load("test/fixtures/index.json")

      assert ids(Index.untested_changes(index)) == ["SampleApp.Greeter.Nested.hello/0"]
    end
  end

  describe "path_back/4" do
    test "is the function and the test when the test calls it" do
      test = test_id("MyApp.WalletsTest", "credits")

      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.path_back(index, test, "MyApp.Wallets.credit/2") ==
               ["MyApp.Wallets.credit/2", test]
    end

    test "runs through the records between, each calling the one before it" do
      test = test_id("MyApp.WalletsTest", "a")

      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.A.one/0", "MyApp.A", ["MyApp.Wallets.credit/2"]),
          record("MyApp.A.two/0", "MyApp.A", ["MyApp.A.one/0"]),
          test_record("MyApp.WalletsTest", "a", ["MyApp.A.two/0", "MyApp.A.one/0"])
        ])

      assert Index.path_back(index, test, "MyApp.Wallets.credit/2") ==
               ["MyApp.Wallets.credit/2", "MyApp.A.one/0", test]
    end

    test "ends at the setup when the test reaches the function through it" do
      setup = "MyApp.WalletsTest.__ex_unit_setup_0/1"

      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          record("MyApp.WalletsTest.seed/0", "MyApp.WalletsTest", ["MyApp.Wallets.credit/2"]),
          setup_record("MyApp.WalletsTest", ["MyApp.WalletsTest.seed/0"]),
          test_record("MyApp.WalletsTest", "b", []),
          test_record("MyApp.OtherTest", "c", [])
        ])

      assert Index.path_back(index, test_id("MyApp.WalletsTest", "b"), "MyApp.Wallets.credit/2") ==
               ["MyApp.Wallets.credit/2", "MyApp.WalletsTest.seed/0", setup]

      assert Index.path_back(index, test_id("MyApp.OtherTest", "c"), "MyApp.Wallets.credit/2") ==
               []
    end

    test "prefers the test to a setup met at the same hop" do
      test = test_id("MyApp.WalletsTest", "a")

      index =
        reach_index([
          record("MyApp.Wallets.credit/2"),
          setup_record("MyApp.WalletsTest", ["MyApp.Wallets.credit/2"]),
          test_record("MyApp.WalletsTest", "a", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.path_back(index, test, "MyApp.Wallets.credit/2") ==
               ["MyApp.Wallets.credit/2", test]
    end

    test "is as long as tests_for says, and stops after max_hops" do
      chain =
        for n <- 1..4, do: record("MyApp.C.f#{n}/0", "MyApp.C", ["MyApp.C.f#{n - 1}/0"])

      far = test_id("MyApp.CTest", "far")

      index =
        reach_index(
          [record("MyApp.C.f0/0", "MyApp.C", [])] ++
            chain ++ [test_record("MyApp.CTest", "far", ["MyApp.C.f4/0"])]
        )

      assert Index.path_back(index, far, "MyApp.C.f0/0") == []

      assert Index.path_back(index, far, "MyApp.C.f0/0", 5) ==
               [
                 "MyApp.C.f0/0",
                 "MyApp.C.f1/0",
                 "MyApp.C.f2/0",
                 "MyApp.C.f3/0",
                 "MyApp.C.f4/0",
                 far
               ]

      assert [%{hops: 5}] = Index.tests_for(index, "MyApp.C.f0/0", 5)
    end

    test "terminates on a cycle and answers nothing for an unknown id or a non-test" do
      test = test_id("MyApp.ATest", "a")

      index =
        reach_index([
          record("MyApp.A.a/0", "MyApp.A", ["MyApp.A.b/0"]),
          record("MyApp.A.b/0", "MyApp.A", ["MyApp.A.a/0"]),
          test_record("MyApp.ATest", "a", [])
        ])

      assert Index.path_back(index, test, "MyApp.A.a/0", 10) == []
      assert Index.path_back(index, test, "MyApp.Nope.none/0") == []
      assert Index.path_back(index, "MyApp.A.b/0", "MyApp.A.a/0") == []
    end

    test "resolves a default-argument arity to its definition" do
      test = test_id("MyApp.WalletsTest", "credits")

      index =
        reach_index([
          Map.put(record("MyApp.Wallets.credit/3"), "arities", [2, 3]),
          test_record("MyApp.WalletsTest", "credits", ["MyApp.Wallets.credit/2"])
        ])

      assert Index.path_back(index, test, "MyApp.Wallets.credit/2") ==
               ["MyApp.Wallets.credit/3", test]
    end
  end

  test "every index built carries a generation of its own" do
    {:ok, one} = Index.load("test/fixtures/index.json")
    {:ok, two} = Index.load("test/fixtures/index.json")

    assert is_integer(one.generation)
    assert one.generation != two.generation
  end

  defp reach_index(records) do
    {:ok, index} = Index.from_document(%{"version" => 1, "functions" => records})
    index
  end

  defp record(id, module \\ "MyApp.Wallets", calls \\ []) do
    [name, arity] = id |> String.replace_prefix(module <> ".", "") |> String.split("/")

    %{
      "id" => id,
      "kind" => "def",
      "module" => module,
      "name" => name,
      "arity" => String.to_integer(arity),
      "calls" => Enum.map(calls, &%{"target" => &1, "kind" => "remote"})
    }
  end

  defp test_record(module, name, calls) do
    %{
      "id" => test_id(module, name),
      "kind" => "test",
      "module" => module,
      "name" => "test #{name}",
      "arity" => 1,
      "test" => %{"describe" => nil, "name" => name, "tags" => []},
      "calls" => Enum.map(calls, &%{"target" => &1, "kind" => "remote"})
    }
  end

  defp setup_record(module, calls) do
    %{
      "id" => "#{module}.__ex_unit_setup_0/1",
      "kind" => "setup",
      "module" => module,
      "name" => "__ex_unit_setup_0",
      "arity" => 1,
      "calls" => Enum.map(calls, &%{"target" => &1, "kind" => "remote"})
    }
  end

  defp changed(record, change), do: Map.put(record, "change", change)

  defp test_id(module, name), do: ~s|#{module}."test #{name}"/1|

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "grasp-index-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp ids(records), do: Enum.map(records, & &1["id"])
end
