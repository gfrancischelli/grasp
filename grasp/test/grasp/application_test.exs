defmodule Grasp.ApplicationTest do
  # The home test drops the suite-wide comments path to see what the home directory gives,
  # so this module runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "the running tree serves its own endpoint, because the test environment is standalone" do
    assert Application.get_env(:grasp, :standalone) == true

    started = Grasp.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    assert GraspWeb.Endpoint in started
    assert Grasp.IndexStore in started
    assert Grasp.MCP.Server in started
    refute Grasp.Reindexer in started
  end

  test "mounted in a host application Grasp follows its compiles and serves no endpoint" do
    children = Grasp.Application.children(true, false)

    assert {Grasp.IndexStore, []} in children
    assert {Grasp.Comments, []} in children
    assert {Grasp.Runs, []} in children
    assert {Grasp.Reindexer, []} in children
    refute GraspWeb.Endpoint in children
  end

  test "standalone there is no host compile to follow" do
    children = Grasp.Application.children(true, true)

    assert GraspWeb.Endpoint in children
    refute {Grasp.Reindexer, []} in children
  end

  test "home/0 is where the reader's own comments and sessions are kept" do
    home = Grasp.Application.home()

    assert is_binary(home)
    assert home == Application.get_env(:grasp, :home)

    previous = Application.get_env(:grasp, :comments_path)
    Application.put_env(:grasp, :comments_path, nil)
    on_exit(fn -> Application.put_env(:grasp, :comments_path, previous) end)

    # A store started with nothing overriding it writes under the home directory, whatever
    # project root the index names.
    store = start_supervised!({Grasp.Comments, [name: :application_test_comments]})

    assert Grasp.Comments.path(store) == Path.join(home, ".grasp/comments.json")
  end

  test "without Mix there is nothing to start" do
    log = capture_log(fn -> assert Grasp.Application.children(false, true) == [] end)

    assert log =~ "Mix is not running"
  end
end
