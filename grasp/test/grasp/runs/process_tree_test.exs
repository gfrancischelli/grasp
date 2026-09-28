defmodule Grasp.Runs.ProcessTreeTest do
  use ExUnit.Case, async: true

  alias Grasp.Runs.ProcessTree

  @table [{10, 1}, {11, 10}, {12, 11}, {13, 10}, {20, 1}, {21, 20}]

  test "the tree of a pid is the pid and everything below it" do
    assert ProcessTree.tree(10, nil, @table) == MapSet.new([10, 11, 12, 13])
    assert ProcessTree.tree(10, 1, @table) == MapSet.new([10, 11, 12, 13])
  end

  test "a pid the table does not list, or lists under another parent, has no tree" do
    assert ProcessTree.tree(30, nil, @table) == MapSet.new()
    assert ProcessTree.tree(10, 2, @table) == MapSet.new()
  end

  # The pids are made up, so these kills must signal nothing for the tests to be safe; a
  # reader that fails the test on a second reading shows no STOP round began.
  test "a kill of a pid not listed under its parent signals nothing" do
    table = fn -> {:ok, @table} end

    assert ProcessTree.kill(30, table: table) == []
    assert ProcessTree.kill(10, parent: 2, table: table) == []
  end

  test "a table that cannot be read at all signals nothing" do
    assert ProcessTree.kill(10, table: fn -> {:error, :unreadable} end) == []
  end

  test "the table lists this VM under its parent" do
    assert {:ok, table} = ProcessTree.read_table()
    pid = String.to_integer(System.pid())

    assert {^pid, ppid} = List.keyfind(table, pid, 0)
    assert ProcessTree.parent(pid) == ppid
  end
end
