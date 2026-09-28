defmodule GraspWeb.RunsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GraspWeb.RunsPanel

  @finished %{
    id: "r1",
    description: "mix grasp.cover",
    finished_at: ~U[2026-09-28 12:00:00Z],
    exit_status: nil,
    cancelled?: false
  }

  test "a run that ended without an exit status reads finished, not running" do
    html = panel(run: @finished, running: nil)

    assert html =~ ~s(data-status="finished")
    refute html =~ ~s(data-status="running")
  end

  test "the status is announced as it changes and the streaming log is not" do
    html = panel(run: @finished, running: nil)

    assert html =~ ~r/class="runs__status"[^>]*aria-live="polite"/
    assert html =~ ~r/id="runs-log"[^>]*role="log"[^>]*aria-live="off"/
  end

  defp panel(assigns) do
    render_component(&RunsPanel.runs_panel/1, Keyword.merge([open?: true, lines: []], assigns))
  end
end
