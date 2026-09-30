defmodule Grasp.Session.ForestColumnsTest do
  use ExUnit.Case, async: true

  alias Grasp.Session.Forest

  # A function's layer is named by the first segment of its id, so the cards read as what
  # they stand for.
  @layers %{
    "Test" => :test,
    "Html" => :html,
    "Iface" => :interfaces,
    "Core" => :core,
    "Private" => :private,
    "Ext" => :external
  }

  defp layer_of(function_id),
    do: Map.fetch!(@layers, function_id |> String.split(".") |> hd())

  defp columns(forest), do: Forest.columns_of(forest, &layer_of/1)

  test "each layer starts one column past the last column of the layers before it" do
    {forest, t} = Forest.open_root(Forest.new(), "Test.t/0")
    {forest, h} = Forest.open_root(forest, "Html.h/0")
    {forest, i} = Forest.open_child(forest, h, "Iface.i/0")
    {forest, ^i} = Forest.open_child(forest, t, "Iface.i/0")
    {forest, c1} = Forest.open_child(forest, i, "Core.c1/0")
    {forest, c2} = Forest.open_child(forest, c1, "Core.c2/0")
    {forest, p1} = Forest.open_child(forest, c2, "Private.p1/0")
    {forest, p2} = Forest.open_child(forest, c1, "Private.p2/0")
    {forest, e} = Forest.open_child(forest, c1, "Ext.e/0")

    assert columns(forest) == %{
             t => 0,
             h => 1,
             i => 2,
             c1 => 3,
             c2 => 4,
             p1 => 5,
             p2 => 5,
             e => 6
           }
  end

  test "a layer with no card in the section takes no column" do
    {forest, i} = Forest.open_root(Forest.new(), "Iface.i/0")
    {forest, c} = Forest.open_child(forest, i, "Core.c/0")
    {forest, source} = Forest.open_root(forest, "Core.source/0")
    {forest, p} = Forest.open_root(forest, "Private.p/0")

    assert columns(forest) == %{i => 0, c => 1, source => 1, p => 2}
  end

  test "a core chain spreads right inside its band" do
    {forest, c1} = Forest.open_root(Forest.new(), "Core.c1/0")
    {forest, c2} = Forest.open_child(forest, c1, "Core.c2/0")
    {forest, c3} = Forest.open_child(forest, c2, "Core.c3/0")
    {forest, ^c3} = Forest.open_child(forest, c1, "Core.c3/0")

    assert columns(forest) == %{c1 => 0, c2 => 1, c3 => 2}
  end

  test "the edge that closes a cycle sets no column" do
    {forest, a} = Forest.open_root(Forest.new(), "Core.a/0")
    {forest, b} = Forest.open_child(forest, a, "Core.b/0")
    {forest, ^a} = Forest.open_child(forest, b, "Core.a/0")
    {forest, ^b} = Forest.open_child(forest, b, "Core.b/0")

    assert columns(forest) == %{a => 0, b => 1}
  end

  test "a card of an earlier layer stands at its own floor whatever calls it" do
    {forest, i} = Forest.open_root(Forest.new(), "Iface.i/0")
    {forest, h} = Forest.open_child(forest, i, "Html.h/0")
    {forest, c} = Forest.open_child(forest, i, "Core.c/0")

    assert columns(forest) == %{h => 0, i => 1, c => 2}
  end

  test "every section is laid out on its own, a card reached from another at its floor" do
    {forest, i} = Forest.open_root(Forest.new(), "Iface.i/0")
    {forest, c} = Forest.open_child(forest, i, "Core.c/0")
    {forest, p} = Forest.open_child(forest, c, "Private.p/0")
    {forest, h} = Forest.open_root(forest, "Html.h/0")
    {forest, c2} = Forest.open_child(forest, h, "Core.c2/0")
    {forest, _group} = Forest.group_cards(forest, "Flow", [p, h, c2])

    assert columns(forest) == %{i => 0, c => 1, h => 0, c2 => 1, p => 2}

    assert Forest.layered_columns_of(forest, Forest.sections(forest), &layer_of/1) ==
             columns(forest)
  end

  test "a hidden card has no column, and columns_of/1 keeps the call depth" do
    {forest, h} = Forest.open_root(Forest.new(), "Html.h/0")
    {forest, c} = Forest.open_child(forest, h, "Core.c/0")
    {forest, p} = Forest.open_child(forest, c, "Private.p/0")
    {forest, c2} = Forest.open_root(forest, "Core.c2/0")

    assert Forest.columns_of(forest) == %{h => 0, c => 1, p => 2, c2 => 0}
    assert columns(forest) == %{h => 0, c => 1, p => 2, c2 => 1}

    assert forest |> Forest.toggle_collapse(c) |> columns() == %{h => 0, c => 1, c2 => 1}
  end
end
