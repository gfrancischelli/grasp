defmodule Grasp.Index.Resolve do
  @moduledoc """
  Derives the edges that come from the project's entry points, and derives them again over
  a record the document already holds.

  Two passes run here, in order: `Grasp.Index.Routes` turns a record's route sites into
  calls on the action or LiveView the router maps each path to, and `Grasp.Index.Jobs`
  redirects a call enqueueing an Oban job onto the worker that runs it. Neither reads the
  source: a route site and an enqueueing call are the inputs, and the routes and workers
  among the entry points are what they are matched against.

  Because the inputs are all either pass needs, the document keeps them — a record carries
  its `"route_sites"`, and an enqueue call carries under `"via"` the call it stands for —
  and `refresh/2` resolves a record from them without reading its file. That is what lets
  an update detect the entry points afresh and resolve every record against them: a route
  or a worker that appears or goes reaches a record whose file nothing recompiled.

  A record with no `"route_sites"` key, or no `"calls"`, comes from a document written
  without the inputs, and `refresh/2` returns it as it is: its route sites are not in the document to be read,
  so re-resolving it would drop the route calls it has and put nothing back. A full build
  is what gives such a document its inputs.
  """

  alias Grasp.Index.{Extract, Jobs, Join, Routes}

  @doc """
  Resolves route sites and enqueueing calls on `records` against `entries`.

  `entries` are entry points in the JSON shape the document holds them in, as
  `Grasp.Index.Builder.entry_point_json/1` writes them. Only `:calls` and `:route_sites`
  are read, so a record carrying those two is enough — which is what `refresh/2` hands
  over; every other key a record has is passed through.
  """
  @spec resolve([map()], [map()]) :: [map()]
  def resolve(records, entries), do: records |> Routes.resolve(entries) |> Jobs.resolve(entries)

  @doc """
  Resolves one record of an index document again, from the inputs the document kept.

  Takes and returns the JSON shape `Grasp.Index.Builder.function_json/1` writes. Every
  derived edge is undone first — a call of kind `"route"` is dropped, an enqueue call
  becomes the call its `"via"` names — so what comes back is decided by `entries` alone
  and resolving twice against the same entry points says the same thing. A call of kind
  `"double"` is kept as it is, with its `"double"` object: the entry points decide nothing
  about it, and only a full build reads the declarations it came from. A record written
  without its `"route_sites"`, or without its `"calls"`, is returned unchanged.
  """
  @spec refresh(map(), [map()]) :: map()
  def refresh(%{"route_sites" => sites, "calls" => record_calls} = record, entries)
      when is_list(sites) and is_list(record_calls) do
    calls =
      record_calls
      |> Enum.reject(&(&1["kind"] == "route"))
      |> Enum.map(&unresolved/1)
      |> Enum.map(&call_record/1)

    [resolved] =
      resolve(
        [%{id: record["id"], calls: calls, route_sites: Enum.map(sites, &route_site_record/1)}],
        entries
      )

    Map.put(record, "calls", Enum.map(resolved.calls, &call_json/1))
  end

  def refresh(record, _entries), do: record

  @doc """
  The JSON shape of one call.

  A call of kind `:route` carries the route it reaches, so a reader is told which one of a
  controller's actions the link goes to without opening the router. A call of kind
  `:enqueue` carries the worker and the queue the job runs on, and under `"via"` the call
  it stands for. A call of kind `:double` carries under `"double"` the Mox mock a test set up
  and the behaviour the mock stands in for, and under `"implementations"` the modules every
  double at its site reaches when the call is the one the site's range holds.
  """
  @spec call_json(Join.call()) :: map()
  def call_json(call) do
    %{
      "target" => call.target,
      "kind" => Atom.to_string(call.kind),
      "range" => %{
        "start" => Tuple.to_list(call.range.start),
        "end" => Tuple.to_list(call.range.end)
      }
    }
    |> put_route(call)
    |> put_job(call)
    |> put_via(call)
    |> put_double(call)
  end

  @doc "One call read back out of a document, in the shape the resolvers work on."
  @spec call_record(map()) :: Join.call()
  def call_record(call) do
    %{
      target: call["target"],
      kind: String.to_existing_atom(call["kind"]),
      range: range_record(call["range"])
    }
    |> take_route(call)
    |> take_job(call)
    |> take_via(call)
    |> take_double(call)
  end

  @doc """
  The JSON shape of one route site.

  A segment the source computes is `:dynamic`, which JSON has no word for and which is
  written as null.
  """
  @spec route_site_json(Extract.route_site()) :: map()
  def route_site_json(site) do
    %{
      "verb" => site.verb,
      "path" => Enum.map(site.path, &segment_json/1),
      "range" => %{
        "start" => Tuple.to_list(site.range.start),
        "end" => Tuple.to_list(site.range.end)
      }
    }
  end

  @doc "One route site read back out of a document."
  @spec route_site_record(map()) :: Extract.route_site()
  def route_site_record(site) do
    %{
      verb: site["verb"],
      path: Enum.map(site["path"] || [], &segment_record/1),
      range: range_record(site["range"])
    }
  end

  # An enqueue edge stands for the call it replaced, which is what the workers are matched
  # against.
  defp unresolved(%{"kind" => "enqueue", "via" => %{"target" => target, "kind" => kind}} = call),
    do: %{"target" => target, "kind" => kind, "range" => call["range"]}

  defp unresolved(call), do: call

  defp put_route(json, %{route: %{verb: verb, path: path}}),
    do: Map.put(json, "route", %{"verb" => verb, "path" => path})

  defp put_route(json, _call), do: json

  defp put_job(json, %{job: %{worker: worker, queue: queue}}),
    do: Map.put(json, "job", %{"worker" => worker, "queue" => queue})

  defp put_job(json, _call), do: json

  defp put_via(json, %{via: %{target: target, kind: kind}}),
    do: Map.put(json, "via", %{"target" => target, "kind" => Atom.to_string(kind)})

  defp put_via(json, _call), do: json

  defp take_route(record, %{"route" => %{"verb" => verb, "path" => path}}),
    do: Map.put(record, :route, %{verb: verb, path: path})

  defp take_route(record, _call), do: record

  defp take_job(record, %{"job" => %{"worker" => worker, "queue" => queue}}),
    do: Map.put(record, :job, %{worker: worker, queue: queue})

  defp take_job(record, _call), do: record

  defp take_via(record, %{"via" => %{"target" => target, "kind" => kind}}),
    do: Map.put(record, :via, %{target: target, kind: String.to_existing_atom(kind)})

  defp take_via(record, _call), do: record

  defp put_double(json, %{double: %{mock: _, behaviour: _} = double}),
    do: Map.put(json, "double", double_json(double))

  defp put_double(json, _call), do: json

  defp take_double(record, %{"double" => %{"mock" => mock, "behaviour" => behaviour} = double}) do
    taken =
      case double do
        %{"implementations" => implementations} when is_list(implementations) ->
          %{mock: mock, behaviour: behaviour, implementations: implementations}

        _double ->
          %{mock: mock, behaviour: behaviour}
      end

    Map.put(record, :double, taken)
  end

  defp take_double(record, _call), do: record

  @doc """
  The JSON shape of a call's `:double`: the mock and the behaviour, and the implementations
  when the call lists them.
  """
  @spec double_json(%{
          required(:mock) => String.t(),
          required(:behaviour) => String.t(),
          optional(:implementations) => [String.t()]
        }) :: map()
  def double_json(%{mock: mock, behaviour: behaviour} = double) do
    json = %{"mock" => mock, "behaviour" => behaviour}

    case double do
      %{implementations: implementations} -> Map.put(json, "implementations", implementations)
      _double -> json
    end
  end

  defp range_record(%{"start" => start, "end" => finish}),
    do: %{start: List.to_tuple(start), end: List.to_tuple(finish)}

  defp segment_json(:dynamic), do: nil
  defp segment_json(segment), do: segment

  defp segment_record(nil), do: :dynamic
  defp segment_record(segment), do: segment
end
