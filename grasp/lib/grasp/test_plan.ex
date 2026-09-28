defmodule Grasp.TestPlan do
  @moduledoc """
  The recipe an agent follows to plan tests on the canvas, and the words that ask for it.

  A plan is made for a target: one function, or the functions the review changed. The agent
  reads each function under test with the tests that reach it and what the suite ran of it,
  lays out one group per function holding the function and its tests, comments on every
  clause and arm no test entered and on every function no test reaches, and stops, leaving
  the plan on the canvas for the reader to review before a test is written. Writing and
  running the tests is a second request, made against that plan.

  The chat agent carries the recipe in its system prompt and the MCP prompt `plan_tests`
  hands it to any client, so both answer the same words the same way.
  """

  @typedoc "What a plan is made for: a function id, or `:changes` for the review's changes."
  @type target :: String.t() | :changes

  @doc """
  The instructions for planning tests, naming the grasp tools by their MCP names.

  The same text holds in both chat modes: its last step says what read mode leaves to the
  reader, since read mode cannot write a file or start a run.
  """
  @spec recipe() :: String.t()
  def recipe do
    """
    When the user asks you to plan tests — "#{request("<function id>")}", or "#{request(:changes)}":
    1. Find the functions under test: the function named, or for the changes, every changed application function list_changes returns — not the tests and setups — beginning with those untested_changes names, since no test reaches them. For each, call get_function, tests_for for the tests that reach it, and coverage for the lines, clauses and arms the suite never ran. When coverage answers `none`, say that `mix grasp.cover` writes it and plan from the tests alone.
    2. Call set_cards with one group per function under test, titled with its id, holding the function and the tests that reach it; group_cards frames cards already open the same way.
    3. Call add_comment on every clause and arm coverage reports never entered, and on the first line of every function no test reaches, saying what a test for it would have to exercise: the input, the path it takes and what to assert.
    4. Stop there and write no test. Reply that the plan is on the canvas for review.
    5. Asked afterwards to write the tests, write them against that plan, run them with run_tests and read each result with run_status, then read coverage again once a coverage run has finished. In read mode you can neither write a test nor start a run: say so, and leave writing and running them to the reader, from the viewer's runs panel or after switching the chat to edit mode.
    """
    |> String.trim_trailing()
  end

  @doc """
  The words that ask for a plan of `target`: `"Plan tests for <function id>"`, or
  `"Plan tests for the changes"` for `:changes`.
  """
  @spec request(target()) :: String.t()
  def request(:changes), do: "Plan tests for the changes"
  def request(function_id) when is_binary(function_id), do: "Plan tests for #{function_id}"
end
