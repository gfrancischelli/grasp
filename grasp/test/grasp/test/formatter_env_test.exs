defmodule Grasp.Test.FormatterEnvTest do
  # The formatter reads its run file from the application environment, which is global.
  use ExUnit.Case, async: false

  alias Grasp.Test.Formatter

  @moduletag :tmp_dir

  test "the run file comes from the application environment when ExUnit names none",
       %{tmp_dir: tmp_dir} do
    run_file = Path.join(tmp_dir, "from-env.bin")
    previous = Application.fetch_env(:grasp, Formatter)
    Application.put_env(:grasp, Formatter, run_file: run_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:grasp, Formatter, value)
        :error -> Application.delete_env(:grasp, Formatter)
      end
    end)

    {:ok, formatter} = Formatter.start_link(seed: 0)
    GenServer.cast(formatter, {:suite_finished, %{run: 1, async: 0, load: nil}})
    GenServer.stop(formatter)

    assert %{tests: tests} = run_file |> File.read!() |> :erlang.binary_to_term()
    assert tests == %{}
  end
end
