defmodule GraspWeb.LayoutJsTest do
  @moduledoc """
  Runs the tests of `assets/js/layout.js` under Node's own test runner, so `mix test` covers
  the canvas's pure layout step. Node is not a dependency of the library: without it on the
  path the test is skipped and says why.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../..", __DIR__)

  if System.find_executable("node") do
    test "layout.js passes its node tests" do
      {output, status} =
        System.cmd("node", ["--test", "assets/js/layout.test.mjs"],
          cd: @assets,
          stderr_to_stdout: true
        )

      assert status == 0, "node --test assets/js/layout.test.mjs failed:\n\n" <> output
    end
  else
    @tag skip: "node is not on the path, so assets/js/layout.test.mjs cannot run"
    test "layout.js passes its node tests" do
    end
  end
end
