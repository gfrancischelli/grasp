defmodule Grasp.TestPlanTest do
  use ExUnit.Case, async: true

  alias Grasp.TestPlan

  test "request/1 answers the words that ask for a plan" do
    assert TestPlan.request("SampleApp.Greeter.greet/2") ==
             "Plan tests for SampleApp.Greeter.greet/2"

    assert TestPlan.request(:changes) == "Plan tests for the changes"
  end

  test "recipe/0 opens on the words it answers, as the other recipes open" do
    assert TestPlan.recipe() =~
             ~s(When the user asks you to plan tests — "Plan tests for <function id>", ) <>
               ~s(or "Plan tests for the changes":)
  end

  test "recipe/0 reads each function under test with its tests and its coverage" do
    recipe = TestPlan.recipe()

    assert recipe =~ "every function list_changes returns"
    assert recipe =~ "call get_function, tests_for for the tests that reach it, and coverage"
  end

  test "recipe/0 lays out one group per function under test with the tests that reach it" do
    recipe = TestPlan.recipe()

    assert recipe =~
             "Call set_cards with one group per function under test, titled with its id, " <>
               "holding the function and the tests that reach it"

    assert recipe =~ "group_cards"
  end

  test "recipe/0 comments on the gaps coverage reports and on every function no test reaches" do
    assert TestPlan.recipe() =~
             "Call add_comment on every clause and arm coverage reports never entered, " <>
               "and on the first line of every function no test reaches, saying what a test " <>
               "for it would have to exercise"
  end

  test "recipe/0 stops at the plan and writes no test" do
    assert TestPlan.recipe() =~
             "Stop there and write no test. Reply that the plan is on the canvas for review."
  end

  test "recipe/0 writes and runs the tests only when asked afterwards, and not in read mode" do
    recipe = TestPlan.recipe()

    assert recipe =~
             "Asked afterwards to write the tests, write them against that plan, " <>
               "run them with run_tests and read each result with run_status, " <>
               "then read coverage again once a coverage run has finished."

    assert recipe =~ "In read mode you can neither write a test nor start a run"
    assert recipe =~ "leave writing and running them to the reader"
  end
end
