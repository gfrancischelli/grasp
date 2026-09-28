defmodule Mix.Tasks.Grasp.TestIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)

  @passing ~s(SampleApp.TallyTest."test init keeps the start count"/1)
  # Tagged and inside a `describe`: its span starts at the `@tag`, a line above the test.
  @tagged ~s(SampleApp.TallyTest."test handle_call/3 replies with the next number"/1)
  # The route tests need an endpoint the fixture's suite never starts.
  @failing ~s(SampleAppWeb.RoutesTest."test a plain path reaches the controller"/1)

  test "records a passing and a failing test, and a later run leaves the failure alone" do
    dir = Path.join(System.tmp_dir!(), "grasp-test-#{System.unique_integer([:positive])}")
    index_path = Path.join(dir, "index.json")
    out = Path.join(dir, "results.json")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {indexed, status} =
      System.cmd("mix", ["grasp.index", "--out", index_path],
        cd: @fixture,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, indexed

    {output, status} = grasp_test([@passing, @failing], index_path, out)
    assert status != 0, output
    assert output =~ "Grasp test results written to #{out} (1 passed, 1 failed"

    {:ok, results} = Grasp.TestResults.decode(File.read!(out))
    {:ok, index} = Grasp.Index.load(index_path)
    {:ok, passing} = Grasp.Index.fetch_function(index, @passing)
    {:ok, failing} = Grasp.Index.fetch_function(index, @failing)

    assert {:fresh, %{"status" => "passed", "run_id" => first_run}} =
             Grasp.TestResults.for_test(results, passing)

    assert {:fresh, %{"status" => "failed", "run_id" => ^first_run, "errors" => [error]}} =
             Grasp.TestResults.for_test(results, failing)

    assert is_binary(error["message"]) and error["message"] != ""

    assert Enum.any?(
             error["stacktrace"],
             &(&1["module"] == "SampleAppWeb.RoutesTest" and
                 &1["file"] == "test/sample_app_web/routes_test.exs" and is_integer(&1["line"]))
           )

    {output, status} = grasp_test([@passing, @tagged], index_path, out)
    assert status == 0, output
    assert output =~ "Grasp test results written to #{out} (2 passed)"

    {:ok, results} = Grasp.TestResults.decode(File.read!(out))

    assert {:fresh, %{"status" => "passed", "run_id" => second_run}} =
             Grasp.TestResults.for_test(results, passing)

    assert second_run != first_run
    {:ok, tagged} = Grasp.Index.fetch_function(index, @tagged)
    assert tagged["span"]["start_line"] < hd(hd(tagged["clauses"]))

    assert {:fresh, %{"status" => "passed", "run_id" => ^second_run}} =
             Grasp.TestResults.for_test(results, tagged)

    assert {:fresh, %{"status" => "failed", "run_id" => ^first_run}} =
             Grasp.TestResults.for_test(results, failing)

    refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, "run-"))
  end

  defp grasp_test(ids, index_path, out) do
    System.cmd("mix", ["grasp.test", "--index", index_path, "--out", out | ids],
      cd: @fixture,
      env: [{"MIX_ENV", "dev"}],
      stderr_to_stdout: true
    )
  end
end
