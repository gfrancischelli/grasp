defmodule Grasp.Layers do
  @moduledoc """
  The architectural layer a card stands in, read from its record and the index around it.

  An application reads from the outside in, and the layers follow that order: the test suite
  that drives it, the markup a user sees, the interfaces that receive a call from outside,
  the core that decides and the private modules the core is built from, with whatever the
  index does not define last. `layer/2` answers the first of these rules that matches:

    * `:test` — a record `Grasp.Index.test_side?/2` answers true for: a test, a setup, or
      anything written in a test file, a module record included.
    * `:html` — a template, or a module whose behaviours include `Phoenix.LiveView`,
      `Phoenix.LiveComponent` or `Phoenix.Component`, or whose last name segment ends in
      `HTML`, `Live` or `Components`.
    * `:interfaces` — a module whose behaviours include `Phoenix.Controller`,
      `Phoenix.Router`, `Plug`, `Oban.Worker`, `GenServer`, `Supervisor` or `Application`, a
      module named by the module part of an entry point's target, a module whose last
      segment ends in `Controller`, and any module whose first segment ends in `Web`.
    * `:core` — a module no indexed module stands between and its root namespace, the first
      segment of its name: `Acme.Accounts.Policy` is core when the index holds no
      `Acme.Accounts`.
    * `:private` — a module nested under an indexed module other than its root one.
    * `:external` — a card with no record.

  A function takes its module's layer whatever its kind, so a `defp` stands with its module,
  and a module record takes the layer of its own name. `layers/1` answers every record of an
  index at once, reading each module's layer once, which is how `Grasp.Index` holds them.
  """

  alias Grasp.Index

  @type layer :: :test | :html | :interfaces | :core | :private | :external

  @layers [:test, :html, :interfaces, :core, :private, :external]

  @html_behaviours ~w(Phoenix.LiveView Phoenix.LiveComponent Phoenix.Component)
  @interface_behaviours ~w(Phoenix.Controller Phoenix.Router Plug Oban.Worker GenServer Supervisor Application)

  @doc "The layer `record` stands in, a function, module or test record; `nil` is `:external`."
  @spec layer(Index.t(), map() | nil) :: layer()
  def layer(%Index{} = index, record) do
    entry_modules = entry_modules(index)
    layer(index, record, &module_layer(index, &1, entry_modules))
  end

  @doc """
  The layer of every record `index` holds, keyed by function id and by module name: each
  function, test and setup, and each module record.
  """
  @spec layers(Index.t()) :: %{String.t() => layer()}
  def layers(%Index{} = index) do
    entry_modules = entry_modules(index)

    known =
      Map.new(index.modules_by_name, fn {name, _record} ->
        {name, module_layer(index, name, entry_modules)}
      end)

    module_layer = fn name ->
      Map.get_lazy(known, name, fn -> module_layer(index, name, entry_modules) end)
    end

    Enum.concat(index.functions, index.modules_by_name)
    |> Map.new(fn {key, record} -> {key, layer(index, record, module_layer)} end)
  end

  @doc "The layer's place from the outside in: `:test` is 0 and `:external` 5."
  @spec rank(layer()) :: 0..5
  def rank(layer) when layer in @layers, do: Enum.find_index(@layers, &(&1 == layer))

  defp layer(_index, nil, _module_layer), do: :external

  defp layer(index, record, module_layer) do
    cond do
      Index.test_side?(index, record) -> :test
      record["kind"] == "template" -> :html
      record["kind"] == "module" -> module_layer.(record["name"])
      true -> module_layer.(record["module"])
    end
  end

  defp module_layer(_index, name, _entry_modules) when not is_binary(name), do: :core

  defp module_layer(index, name, entry_modules) do
    segments = String.split(name, ".")
    last = List.last(segments)

    behaviours =
      case Index.fetch_module(index, name) do
        {:ok, %{"behaviours" => behaviours}} when is_list(behaviours) -> behaviours
        _none -> []
      end

    cond do
      Enum.any?(behaviours, &(&1 in @html_behaviours)) or
          String.ends_with?(last, ["HTML", "Live", "Components"]) ->
        :html

      Enum.any?(behaviours, &(&1 in @interface_behaviours)) or
        MapSet.member?(entry_modules, name) or String.ends_with?(last, "Controller") or
          String.ends_with?(hd(segments), "Web") ->
        :interfaces

      nested?(index, segments) ->
        :private

      true ->
        :core
    end
  end

  # The modules standing between the root namespace and the module itself: for
  # `Acme.A.B.C` those are `Acme.A` and `Acme.A.B`.
  defp nested?(index, segments) do
    Enum.any?(2..(length(segments) - 1)//1, fn size ->
      name = segments |> Enum.take(size) |> Enum.join(".")
      match?({:ok, _record}, Index.fetch_module(index, name))
    end)
  end

  defp entry_modules(index) do
    for %{"target" => target} <- Index.entry_points(index),
        module = target_module(index, target),
        into: MapSet.new(),
        do: module
  end

  defp target_module(index, target) do
    case Index.fetch_function(index, target) do
      {:ok, %{"module" => module}} when is_binary(module) ->
        module

      _none ->
        case Regex.run(~r/\A(.+)\.[^.]+\/\d+\z/, target) do
          [_target, module] -> module
          nil -> nil
        end
    end
  end
end
