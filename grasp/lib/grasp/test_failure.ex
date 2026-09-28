defmodule Grasp.TestFailure do
  @moduledoc """
  How one error of a failed test reads against the index: the line of the test it belongs
  under, and its stacktrace as the chain of indexed functions it failed down.

  An error is one of `Grasp.Test.Formatter`'s, its `"stacktrace"` a list of
  `%{"module", "function", "arity", "file", "line"}` frames, deepest first. The test's own
  frame is the first whose module is the test record's module and whose function is its
  compiled name. The frames above it — the calls the test made — are walked outwards from
  it, so the chain runs from the test to the deepest frame, and each frame whose
  `{module, function, arity}` names an indexed function (through the index's
  default-argument aliases) is a step of it. A frame of a dependency, of the standard
  library or of any function the index does not hold is no step, and neither is a frame of
  the function the step before it already names, as a recursive call repeats one. A test
  with no frame of its own walks the whole stacktrace.

  A step records the call target its caller writes for it, which is the edge the records
  hold, or nil when the caller holds no call to it: the failure passed through code outside
  the index between the two, or through a call the tracer never saw.

  The document is data a run wrote, so nothing here trusts its shape: a frame missing a
  binary module or function or an integer arity names nothing, and no atom is created for
  any name it holds.
  """

  alias Grasp.Index
  alias Grasp.Index.Join
  alias Grasp.Links

  @typedoc """
  One frame of an error's stacktrace, deepest first, as a failure panel lists it.

  `label` is `Module.function/arity`; `id` the indexed function's id, nil for a frame
  outside the index; `own?` marks the test's own frame; `step?` marks a frame the chain
  opens; `via` is, for a step, the call target its caller writes for it, nil when the caller
  holds no such call; `skipped?` marks a step whose caller is reached through at least one
  frame outside the index.
  """
  @type frame :: %{
          label: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          id: String.t() | nil,
          own?: boolean(),
          step?: boolean(),
          via: String.t() | nil,
          skipped?: boolean()
        }

  @typedoc "One card of the chain: the function, the call target opening it, and its line."
  @type step :: %{id: String.t(), via: String.t() | nil, line: pos_integer() | nil}

  @doc """
  The line of `record`, a test, that `error` belongs under: the line of the test's own frame
  when it names one within the test's span, the test's first line otherwise.
  """
  @spec line(Index.function_record(), map()) :: pos_integer() | nil
  def line(record, error) do
    span = record["span"] || %{}
    first = span["start_line"]
    last = span["end_line"] || first

    own =
      error
      |> raw_frames()
      |> Enum.find(&own_frame?(record, &1))

    case own && own["line"] do
      line when is_integer(line) and is_integer(first) and line >= first and line <= last ->
        line

      _elsewhere ->
        first
    end
  end

  @doc """
  `error`'s stacktrace read against `index` for `record`, the test that failed: every frame,
  deepest first, each marked as `t:frame/0` says.
  """
  @spec trace(Index.t(), Index.function_record(), map()) :: [frame()]
  def trace(%Index{} = index, record, error) do
    frames = error |> raw_frames() |> Enum.map(&read_frame(index, record, &1))

    {inner, outer} =
      case Enum.find_index(frames, & &1.own?) do
        nil -> {frames, []}
        own -> Enum.split(frames, own)
      end

    {walked, _last} =
      inner
      |> Enum.reverse()
      |> Enum.map_reduce({record["id"], false}, fn frame, {caller, skipped?} ->
        cond do
          frame.id == nil ->
            {frame, {caller, true}}

          frame.id == caller ->
            {frame, {caller, skipped?}}

          true ->
            via = Links.call_target(index, caller, frame.id)
            {%{frame | step?: true, via: via, skipped?: skipped?}, {frame.id, false}}
        end
      end)

    Enum.reverse(walked) ++ outer
  end

  @doc """
  The chain `open failure` lays out for `error`: the steps of its trace from the test
  outwards, deepest last. Empty when no frame above the test's own is indexed.
  """
  @spec chain(Index.t(), Index.function_record(), map()) :: [step()]
  def chain(%Index{} = index, record, error) do
    index
    |> trace(record, error)
    |> Enum.filter(& &1.step?)
    |> Enum.reverse()
    |> Enum.map(&%{id: &1.id, via: &1.via, line: &1.line})
  end

  defp raw_frames(%{"stacktrace" => frames}) when is_list(frames),
    do: Enum.filter(frames, &is_map/1)

  defp raw_frames(_error), do: []

  defp own_frame?(record, frame) do
    named?(frame) and frame["module"] == record["module"] and
      frame["function"] == to_string(record["name"])
  end

  defp named?(%{"module" => module, "function" => function, "arity" => arity}),
    do: is_binary(module) and is_binary(function) and is_integer(arity) and arity >= 0

  defp named?(_frame), do: false

  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  defp read_frame(index, record, frame) do
    {label, id} =
      if named?(frame) do
        label = Join.function_id(frame["module"], frame["function"], frame["arity"])

        case Index.fetch_function(index, label) do
          {:ok, indexed} -> {label, indexed["id"]}
          :error -> {label, nil}
        end
      else
        {"#{text(frame["module"])}.#{text(frame["function"])}", nil}
      end

    %{
      label: label,
      file: if(is_binary(frame["file"]), do: frame["file"]),
      line: if(is_integer(frame["line"]) and frame["line"] > 0, do: frame["line"]),
      id: id,
      own?: own_frame?(record, frame),
      step?: false,
      via: nil,
      skipped?: false
    }
  end
end
