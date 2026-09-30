defmodule GraspWeb.LayoutJsTest do
  @moduledoc """
  Runs the tests of the pure modules under `assets/js` — the canvas's layout step and the
  focus a clicked button gives back — under Node's own test runner, so `mix test` covers
  them. Node is not a dependency of the library: without it on the path the test is skipped
  and says why.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../..", __DIR__)
  @files ["assets/js/layout.test.mjs", "assets/js/focus.test.mjs"]

  if System.find_executable("node") do
    test "the pure modules pass their node tests" do
      {output, status} =
        System.cmd("node", ["--test" | @files],
          cd: @assets,
          stderr_to_stdout: true
        )

      assert status == 0, "node --test failed:\n\n" <> output
    end
  else
    @tag skip: "node is not on the path, so the tests under assets/js cannot run"
    test "the pure modules pass their node tests" do
    end
  end
end
