defmodule Grasp.Test.Formatter do
  @moduledoc """
  An ExUnit formatter that records each test's result for `mix grasp.test`.

  It runs in the host's test VM, loaded from Grasp's dev build by `priv/test_run.exs`, where
  nothing but Grasp's own modules and Elixir's are certain to be on the code path. It
  therefore calls no dependency: it encodes each result with the standard library and, when
  the suite finishes, writes this run's results to the file named by the `:run_file` key of
  the `:grasp, Grasp.Test.Formatter` application environment, in the external term format:

      %{
        finished_at: "2026-09-28T12:00:00Z",
        tests: %{"SampleApp.TallyTest.\\"test init keeps the start count\\"/1" => result}
      }

  `mix grasp.test` reads that file in its own session and merges it into the results
  document (see `Grasp.TestResults`), adding what only the index knows. The file lands
  beside its path and is renamed over it, so a file that exists is a finished run.

  A result is a map with string keys, the shape the results document stores:

    * `"status"` — `"passed"`, `"failed"`, `"skipped"`, `"excluded"` or `"invalid"`, from
      the test's `state`;
    * `"time"` — microseconds;
    * `"errors"` — for a failure, one entry per error: its `"kind"`, its `"message"` (an
      assertion's own message, `Exception.message/1` of any other exception, the reason
      inspected otherwise) and its `"stacktrace"` as
      `%{"module", "function", "arity", "file", "line"}` frames, one per module function
      called, the file relative to the project root. An `ExUnit.AssertionError` adds its `"expr"` and, when
      it has them, `"left"` and `"right"` as the CLI formatter prints them: values
      inspected, a pattern written as code.
  """

  use GenServer

  alias Grasp.Index.Join

  @no_value ExUnit.AssertionError.no_value()
  @inspect_opts [pretty: true, width: 80]

  @doc """
  Starts the formatter. ExUnit passes its configuration as `opts`; a `:run_file` in it
  takes precedence over the application environment's.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    run_file =
      Keyword.get_lazy(opts, :run_file, fn ->
        :grasp |> Application.get_env(__MODULE__, []) |> Keyword.get(:run_file)
      end)

    {:ok, %{run_file: run_file, tests: %{}}}
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, put_in(state.tests[Join.function_id(test.module, test.name, 1)], result(test))}
  end

  def handle_cast({:suite_finished, _times}, %{run_file: run_file} = state)
      when is_binary(run_file) do
    run = %{
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      tests: state.tests
    }

    temporary = run_file <> ".tmp"
    File.mkdir_p!(Path.dirname(run_file))
    File.write!(temporary, :erlang.term_to_binary(run))
    File.rename!(temporary, run_file)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  The result of one finished test, as the formatter records it.
  """
  @spec result(ExUnit.Test.t()) :: %{String.t() => term()}
  def result(%ExUnit.Test{state: state, time: time}) do
    {status, errors} =
      case state do
        nil -> {"passed", []}
        {:failed, failures} -> {"failed", Enum.map(List.wrap(failures), &error/1)}
        {:skipped, _reason} -> {"skipped", []}
        {:excluded, _reason} -> {"excluded", []}
        {:invalid, _module} -> {"invalid", []}
      end

    %{"status" => status, "time" => time, "errors" => errors}
  end

  defp error({kind, reason, stacktrace}) do
    %{
      "kind" => Atom.to_string(kind),
      "message" => message(kind, reason),
      "stacktrace" => Enum.flat_map(List.wrap(stacktrace), &frame/1)
    }
    |> Map.merge(assertion(reason))
  end

  defp message(:error, %ExUnit.AssertionError{message: message}) when is_binary(message),
    do: message

  defp message(:error, %{__exception__: true} = exception) do
    Exception.message(exception)
  rescue
    _raised -> inspect(exception, @inspect_opts)
  end

  defp message(_kind, reason), do: inspect(reason, @inspect_opts)

  defp assertion(%ExUnit.AssertionError{} = error) do
    [
      {"expr", error.expr, &Macro.to_string/1},
      {"left", error.left, left_format(error.context)},
      {"right", error.right, &inspect(&1, @inspect_opts)}
    ]
    |> Enum.reject(fn {_key, value, _format} -> value == @no_value end)
    |> Map.new(fn {key, value, format} -> {key, format.(value)} end)
  end

  defp assertion(_reason), do: %{}

  # An assertion whose context is a plain operator compares two values; any other — a match
  # or a receive — holds a pattern on the left, which the CLI formatter prints as code.
  defp left_format(context) when is_atom(context), do: &inspect(&1, @inspect_opts)
  defp left_format(_context), do: &Macro.to_string/1

  defp frame({module, function, arity_or_args, location}) when is_atom(module) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args

    file =
      case Keyword.get(location, :file) do
        nil -> nil
        file -> file |> to_string() |> Path.relative_to_cwd()
      end

    [
      %{
        "module" => inspect(module),
        "function" => Atom.to_string(function),
        "arity" => arity,
        "file" => file,
        "line" => Keyword.get(location, :line)
      }
    ]
  end

  defp frame(_entry), do: []
end
