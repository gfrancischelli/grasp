defmodule Grasp.Index.Jobs do
  @moduledoc """
  Turns a call that enqueues an Oban job into a call on the worker that runs it.

  `use Oban.Worker` gives a worker a `new/1` and a `new/2` that build the job changeset,
  and enqueueing reads `Worker.new(args) |> Oban.insert()`. The compiler reports that as a
  call to `Worker.new/1`, a function no source file defines, so on its own it reaches
  nothing the index holds; the work it sets in motion is `Worker.perform/1`. This pass
  redirects the call there, as a call of kind `:enqueue` carrying the worker and the queue
  it runs on, so the enqueueing function reads as a caller of the worker and the site is a
  hop the reader can follow.

  Which modules are workers is what the `oban_worker` entry points say: a call to `new/1`
  or `new/2` on any other module is left as it is. A worker that writes a `new/1` or a
  `new/2` of its own — Oban makes both overridable — is redirected to `perform/1` all the
  same, because the entry point rather than the definition is what names a module a worker.
  A job enqueued some other way — through `Oban.Job.new/2` with a `worker:` option, or a
  changeset built somewhere else and passed to `Oban.insert_all/2` — names no worker at the
  call site and is not followed.
  """

  @doc """
  Redirects every enqueueing call on `records` to the worker's `perform/1`.

  `entries` are entry points in the JSON shape the document holds them in, as
  `Grasp.Index.Builder.entry_point_json/1` writes them; only the `oban_worker` ones are
  read. A call keeps its range and its place in the record's calls, and where the rewrite
  leaves a record holding two calls of the same target, kind and range, one is kept. The
  call the edge stands for is kept under `:via`, so the edge can be undone and drawn again
  against another set of workers.
  """
  @spec resolve([map()], [map()]) :: [map()]
  def resolve(records, entries) do
    workers =
      entries
      |> Enum.filter(&(&1["kind"] == "oban_worker"))
      |> Enum.flat_map(&worker_of/1)
      |> Map.new()

    if workers == %{}, do: records, else: Enum.map(records, &resolve_record(&1, workers))
  end

  # An entry whose target is `Mod.perform/1` names the worker `Mod`; one targeting any
  # other function of a worker — `backoff/1`, `timeout/1` — names none.
  defp worker_of(%{"target" => target} = entry) when is_binary(target) do
    case Regex.run(~r/\A(.+)\.perform\/1\z/, target) do
      [_all, worker] -> [{worker, %{target: target, queue: queue(entry)}}]
      nil -> []
    end
  end

  defp worker_of(_entry), do: []

  defp queue(%{"meta" => %{"queue" => queue}}) when is_binary(queue), do: queue
  defp queue(_entry), do: "default"

  defp resolve_record(%{calls: calls} = record, workers) do
    case Enum.map(calls, &call(&1, workers)) do
      ^calls -> record
      resolved -> %{record | calls: Enum.uniq_by(resolved, &{&1.target, &1.kind, &1.range})}
    end
  end

  # A double stands in for the function it names rather than enqueueing anything, even when
  # that function is a worker's `new/1`.
  defp call(%{kind: :double} = call, _workers), do: call

  # The suffix is read before the regex because on any real project all but a handful of
  # calls fail it, and every call of every record passes through here.
  defp call(%{target: target} = call, workers) do
    with true <- String.ends_with?(target, [".new/1", ".new/2"]),
         [_all, worker] <- Regex.run(~r/\A(.+)\.new\/[12]\z/, target),
         {:ok, %{target: perform, queue: queue}} <- Map.fetch(workers, worker) do
      %{
        target: perform,
        kind: :enqueue,
        range: call.range,
        job: %{worker: worker, queue: queue},
        via: %{target: target, kind: call.kind}
      }
    else
      _not_enqueueing -> call
    end
  end
end
