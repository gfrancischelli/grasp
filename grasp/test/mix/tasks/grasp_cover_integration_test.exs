defmodule Mix.Tasks.Grasp.CoverIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 600_000

  @fixture Path.expand("../../fixtures/sample_app", __DIR__)

  # The fixture's two route tests need an endpoint the suite never starts, so its run exits
  # non-zero; the counter's tests pass, and their lines are what the document must hold.
  test "writes the lines the fixture's suite ran" do
    dir = Path.join(System.tmp_dir!(), "grasp-cover-#{System.unique_integer([:positive])}")
    index = Path.join(dir, "index.json")
    out = Path.join(dir, "coverage.json")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(Path.join(@fixture, "cover"))
    end)

    {indexed, status} =
      System.cmd("mix", ["grasp.index", "--out", index],
        cd: @fixture,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, indexed

    {covered, status} =
      System.cmd("mix", ["grasp.cover", "--index", index, "--out", out],
        cd: @fixture,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, covered
    assert covered =~ "grasp: the test run exited with status"
    assert covered =~ "Grasp coverage written to #{out}"

    {:ok, coverage} = Grasp.Coverage.decode(File.read!(out))
    {:ok, index} = Grasp.Index.load(index)
    {:ok, handle_call} = Grasp.Index.fetch_function(index, "SampleApp.Counter.handle_call/3")

    assert {:fresh, %{lines: %{11 => count}}} =
             Grasp.Coverage.for_function(coverage, handle_call)

    assert count > 0
    assert File.regular?(Path.join(@fixture, "cover/grasp.coverdata"))

    for id <- Map.keys(coverage["functions"]) do
      {:ok, record} = Grasp.Index.fetch_function(index, id)
      assert record["kind"] in ~w(def defp), id
      refute Grasp.Index.test_file?(index, record["file"]), id
    end
  end
end
