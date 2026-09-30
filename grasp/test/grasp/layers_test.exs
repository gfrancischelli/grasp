defmodule Grasp.LayersTest do
  use ExUnit.Case, async: true

  alias Grasp.Index
  alias Grasp.Layers

  defp module(name, behaviours \\ [], file \\ nil) do
    %{
      "name" => name,
      "file" => file || "lib/#{Macro.underscore(name)}.ex",
      "line" => 1,
      "behaviours" => behaviours
    }
  end

  defp function(module, name, arity, kind \\ "def", file \\ nil) do
    %{
      "id" => "#{module}.#{name}/#{arity}",
      "module" => module,
      "name" => name,
      "arity" => arity,
      "kind" => kind,
      "file" => file || "lib/#{Macro.underscore(module)}.ex",
      "span" => %{"start_line" => 1, "end_line" => 2},
      "calls" => []
    }
  end

  defp index do
    modules = [
      module("Acme"),
      module("Acme.Accounts"),
      module("Acme.Accounts.User"),
      module("Acme.Accounts.Cache", ["GenServer"]),
      module("Acme.Billing.Invoice"),
      module("Acme.Billing.Invoice.Line"),
      module("Acme.Api"),
      module("Acme.Mailer", ["Oban.Worker"]),
      module("AcmeWeb.UserController"),
      module("AcmeWeb.ProfileController", ["Phoenix.Component"]),
      module("AcmeWeb.HomeLive", ["Phoenix.LiveView"]),
      module("AcmeWeb.Dashboard", ["Phoenix.LiveView"]),
      module("AcmeWeb.PageHTML"),
      module("AcmeWeb.CoreComponents"),
      module("AcmeWeb.Router", ["Plug"]),
      module("AcmeWeb.Endpoint"),
      module("Acme.AccountsTest", [], "test/acme/accounts_test.exs")
    ]

    functions = [
      function("Acme.Accounts", "get", 1),
      function("Acme.Accounts", "hash", 1, "defp"),
      function("Acme.Accounts.User", "changeset", 2),
      function("Acme.Accounts.Cache", "handle_call", 3),
      function("Acme.Billing.Invoice", "total", 1),
      function("Acme.Billing.Invoice.Line", "amount", 1),
      function("Acme.Api", "handle", 1),
      function("Acme.Mailer", "perform", 1),
      function("AcmeWeb.UserController", "show", 2),
      function("AcmeWeb.ProfileController", "avatar", 1),
      function("AcmeWeb.HomeLive", "mount", 3),
      function("AcmeWeb.PageHTML", "home", 1, "template"),
      function("AcmeWeb.Pages", "about", 1, "template"),
      function("AcmeWeb.CoreComponents", "button", 1),
      function("AcmeWeb.Router", "call", 2),
      function("AcmeWeb.Endpoint", "init", 1),
      function("Acme.AccountsTest", "\"test gets\"", 1, "test", "test/acme/accounts_test.exs"),
      function(
        "Acme.AccountsTest",
        "__ex_unit_setup_0",
        1,
        "setup",
        "test/acme/accounts_test.exs"
      ),
      function("Acme.AccountsTest", "fixture", 0, "def", "test/acme/accounts_test.exs"),
      function("Acme.Accounts", "\"test inline\"", 1, "test"),
      function("Other.Thing", "run", 0)
      |> Map.put("arities", [0, 1])
    ]

    {:ok, index} =
      Index.from_document(%{
        "version" => 1,
        "project" => %{"app" => "acme", "test_paths" => ["test"]},
        "modules" => modules,
        "functions" => functions,
        "entry_points" => [%{"kind" => "cli", "label" => "api", "target" => "Acme.Api.handle/1"}]
      })

    index
  end

  defp layer_of(index, id) do
    {:ok, record} = Index.fetch_record(index, id)
    Layers.layer(index, record)
  end

  describe "layer/2" do
    setup do
      %{index: index()}
    end

    test "a record of the test suite is test before anything else", %{index: index} do
      assert layer_of(index, ~s(Acme.AccountsTest."test gets"/1)) == :test
      assert layer_of(index, "Acme.AccountsTest.__ex_unit_setup_0/1") == :test
      assert layer_of(index, "Acme.AccountsTest.fixture/0") == :test
      assert layer_of(index, "Acme.AccountsTest") == :test
      assert layer_of(index, ~s(Acme.Accounts."test inline"/1)) == :test
    end

    test "templates, components, LiveViews and HTML modules are html", %{index: index} do
      assert layer_of(index, "AcmeWeb.PageHTML.home/1") == :html
      assert layer_of(index, "AcmeWeb.Pages.about/1") == :html
      assert layer_of(index, "AcmeWeb.HomeLive.mount/3") == :html
      assert layer_of(index, "AcmeWeb.CoreComponents.button/1") == :html
      assert layer_of(index, "AcmeWeb.ProfileController.avatar/1") == :html
      assert layer_of(index, "AcmeWeb.Dashboard") == :html
    end

    test "what receives calls from outside the application is interfaces", %{index: index} do
      assert layer_of(index, "AcmeWeb.UserController.show/2") == :interfaces
      assert layer_of(index, "AcmeWeb.Router.call/2") == :interfaces
      assert layer_of(index, "AcmeWeb.Endpoint.init/1") == :interfaces
      assert layer_of(index, "Acme.Mailer.perform/1") == :interfaces
      assert layer_of(index, "Acme.Accounts.Cache.handle_call/3") == :interfaces
      assert layer_of(index, "Acme.Api.handle/1") == :interfaces
      assert layer_of(index, "AcmeWeb.UserController") == :interfaces
    end

    test "a module nothing indexed stands above but the root is core", %{index: index} do
      assert layer_of(index, "Acme.Accounts.get/1") == :core
      assert layer_of(index, "Acme.Accounts.hash/1") == :core
      assert layer_of(index, "Acme.Accounts") == :core
      assert layer_of(index, "Acme") == :core
      assert layer_of(index, "Acme.Billing.Invoice.total/1") == :core
      assert layer_of(index, "Other.Thing.run/0") == :core
    end

    test "a module nested under an indexed module other than the root is private", %{
      index: index
    } do
      assert layer_of(index, "Acme.Accounts.User.changeset/2") == :private
      assert layer_of(index, "Acme.Accounts.User") == :private
      assert layer_of(index, "Acme.Billing.Invoice.Line.amount/1") == :private
    end

    test "a card with no record is external", %{index: index} do
      assert Layers.layer(index, nil) == :external
    end
  end

  test "rank/1 orders the layers from the outside in" do
    assert Enum.map([:test, :html, :interfaces, :core, :private, :external], &Layers.rank/1) ==
             [0, 1, 2, 3, 4, 5]
  end

  test "Index.layer/2 answers every record the index holds, and external for the rest" do
    index = index()

    assert Index.layer(index, "Acme.Accounts.get/1") == :core
    assert Index.layer(index, "Other.Thing.run/1") == :core
    assert Index.layer(index, "Acme.Accounts.User") == :private
    assert Index.layer(index, ~s(Acme.AccountsTest."test gets"/1)) == :test
    assert Index.layer(index, "AcmeWeb.PageHTML.home/1") == :html
    assert Index.layer(index, "Enum.map/2") == :external
    assert Index.layer(index, "Nowhere") == :external
  end
end
