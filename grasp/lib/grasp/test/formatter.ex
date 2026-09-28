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
  beside its path and is renamed over it, so a file that exists holds a whole run. A suite
  interrupted by SIGQUIT never finishes; the tests it finished before the signal are written
  when the signal arrives. A run file that cannot be written is reported on stderr, and the
  suite finishes as it would without the formatter.

  A result is a map with string keys, the shape the results document stores:

    * `"status"` — `"passed"`, `"failed"`, `"skipped"`, `"excluded"` or `"invalid"`, from
      the test's `state`;
    * `"time"` — microseconds;
    * `"errors"` — for a failure, one entry per error: its `"kind"` (`"error"`, `"exit"`,
      `"throw"`, or a kind that is not an atom inspected, as `{:EXIT, pid}` is), its
      `"message"` (an assertion's own message, `Exception.message/1` of any other
      exception, the reason inspected otherwise) and its `"stacktrace"` as
      `%{"module", "function", "arity", "file", "line"}` frames, one per module function
      called, the file relative to the project root. An `ExUnit.AssertionError` adds its
      `"expr"` and, when it has them, `"left"` and `"right"` as the CLI formatter prints
      them: values inspected, a pattern written as code;
    * `"reason"` — for a state the formatter cannot read, that state inspected, the status
      being `"invalid"`.
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

  def handle_cast({event, _detail}, state) when event in [:suite_finished, :sigquit] do
    write_run(state)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # A suite interrupted by SIGQUIT never finishes, so the tests finished before the signal
  # are written then; a later write of the same run replaces the file whole. ExUnit stops
  # its formatters when the suite ends, and one that crashes then takes the runner down with
  # it, so a failed write is reported and the formatter carries on.
  defp write_run(%{run_file: run_file, tests: tests}) when is_binary(run_file) do
    run = %{
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      tests: tests
    }

    temporary = run_file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(run_file)),
         :ok <- File.write(temporary, :erlang.term_to_binary(run)),
         :ok <- File.rename(temporary, run_file) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)

        IO.puts(
          :stderr,
          "grasp: could not record this run's results: #{:file.format_error(reason)}"
        )
    end
  end

  defp write_run(_state), do: :ok

  @doc """
  The result of one finished test, as the formatter records it.

  It never raises, so no one test can cost the run its record: a state ExUnit does not
  document, or one the encoding cannot read, is `"invalid"` with the state inspected as its
  `"reason"`.
  """
  @spec result(ExUnit.Test.t()) :: %{String.t() => term()}
  def result(%ExUnit.Test{state: state, time: time}) do
    case state do
      nil ->
        result("passed", time, [])

      {:failed, failures} when is_list(failures) ->
        result("failed", time, Enum.map(failures, &error/1))

      {:skipped, _reason} ->
        result("skipped", time, [])

      {:excluded, _reason} ->
        result("excluded", time, [])

      {:invalid, _module} ->
        result("invalid", time, [])

      _other ->
        unreadable(state, time)
    end
  rescue
    _raised -> unreadable(state, time)
  end

  defp result(status, time, errors), do: %{"status" => status, "time" => time, "errors" => errors}

  defp unreadable(state, time),
    do: %{"status" => "invalid", "time" => time, "errors" => [], "reason" => inspect(state)}

  defp error({kind, reason, stacktrace}) do
    %{
      "kind" => kind_name(kind),
      "message" => message(kind, reason),
      "stacktrace" => Enum.flat_map(List.wrap(stacktrace), &frame/1)
    }
    |> Map.merge(assertion(reason))
  end

  defp error(other), do: %{"kind" => "unknown", "message" => inspect(other), "stacktrace" => []}

  # A test whose process a linked process took down fails with the kind `{:EXIT, pid}`.
  defp kind_name(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_name(kind), do: inspect(kind)

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
