defmodule GraspWeb.RunsPanel do
  @moduledoc """
  The runs panel: the test or coverage run under way, or the last one to finish, floating
  over the canvas where the chat panel floats.

  It names the run by its description, says whether it is running, finished, failed or
  cancelled, and shows the run's output, newest at the bottom, with `cancel` while it runs
  and `run coverage` beside it. `Grasp.Runs` is the source of all of it and one run is
  shared by every tab, so a tab opened mid-run shows the lines the run still keeps and the
  ones that follow.

  The output is a LiveView stream capped at the 200 lines a run keeps: a line arriving is
  one insert sent to the page, not the whole log again, and nothing else on the page
  re-renders for it. Each line is cut to `max_line/0` characters, with a `…` after the cut,
  before it is streamed, since a run keeps lines of up to a mebibyte and a page drawing one
  whole would stall on it. The log follows the newest line only while the reader is at the
  bottom of it, as the chat log does: the `Runs` hook pins it there and, when the reader has
  scrolled up, unhides the "latest" pill instead.
  """

  use GraspWeb, :html

  @max_line 4_000

  @doc "How many characters of one output line the panel draws."
  @spec max_line() :: pos_integer()
  def max_line, do: @max_line

  @doc """
  `line` as the panel draws it: bytes that are not UTF-8 replaced, and cut to `max_line/0`
  characters with a `…` after the cut.
  """
  @spec display_line(binary()) :: String.t()
  def display_line(line) when is_binary(line) do
    line = String.replace_invalid(line)

    if byte_size(line) > @max_line and String.length(line) > @max_line,
      do: String.slice(line, 0, @max_line) <> "…",
      else: line
  end

  attr :open?, :boolean, required: true
  attr :run, :map, default: nil, doc: "the run under way or the last one, without its output"
  attr :running, :string, default: nil, doc: "the description of the run under way"
  attr :lines, :any, required: true, doc: "the stream of the run's output lines"

  def runs_panel(assigns) do
    ~H"""
    <aside id="runs" class="runs" phx-hook="Runs" hidden={!@open?} aria-label="Runs">
      <header class="runs__header">
        <span :if={@run} class="runs__description">{@run.description}</span>
        <span :if={!@run} class="runs__description runs__description--none">No run yet</span>
        <span :if={@run} class="runs__status" data-status={status(@run, @running)}>
          {status_label(@run, @running)}
        </span>
      </header>
      <div class="runs__transcript">
        <div id="runs-log" class="runs__log" phx-update="stream" aria-live="polite">
          <p :for={{dom_id, line} <- @lines} id={dom_id} class="runs__line">{line.text}</p>
        </div>
        <button id="runs-jump" type="button" class="runs__jump" hidden>↓ latest</button>
      </div>
      <div class="runs__actions">
        <button :if={@running} type="button" id="runs-cancel" phx-click="run_cancel">
          cancel
        </button>
        <button
          type="button"
          id="runs-coverage"
          phx-click="run_coverage"
          disabled={@running != nil}
          title={running_title(@running, "Run the suite with coverage")}
        >
          run coverage
        </button>
      </div>
    </aside>
    """
  end

  @doc """
  The title a control that starts a run carries: `idle` while nothing runs, and the running
  command's description while one does, since the control is disabled until it finishes.
  """
  @spec running_title(String.t() | nil, String.t()) :: String.t()
  def running_title(nil, idle), do: idle
  def running_title(running, _idle), do: "Running #{running}"

  defp status(%{id: _}, running) when is_binary(running), do: "running"
  defp status(%{cancelled?: true}, _running), do: "cancelled"
  defp status(%{exit_status: 0}, _running), do: "finished"
  defp status(%{exit_status: code}, _running) when is_integer(code), do: "failed"
  defp status(_run, _running), do: "running"

  defp status_label(run, running) do
    case status(run, running) do
      "failed" -> "failed · exit #{run.exit_status}"
      other -> other
    end
  end
end
