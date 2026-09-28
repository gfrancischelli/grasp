defmodule Grasp.HighlightCacheTest do
  # The cache is a single globally named table, so these cannot run beside a test that clears it.
  use ExUnit.Case, async: false

  alias Grasp.Highlight

  setup do
    :ok = Highlight.ensure_cache()
    on_exit(&Highlight.clear_cache/0)
    :ok
  end

  defp opts, do: [card_id: 1, open_calls: %{}, external?: fn _ -> false end]

  defp record(id) do
    %{
      "id" => id,
      "span" => %{"start_line" => 1, "end_line" => 2},
      "source" => "def f(x) do\n  x |> g() |> h()\nend",
      "calls" => []
    }
  end

  test "a second render of the same record is memoised and identical" do
    record = record("Cached.f/1")

    first = record |> Highlight.render(opts()) |> Phoenix.HTML.safe_to_string()
    assert :ets.lookup(:grasp_highlight_cache, "Cached.f/1") != []

    second = record |> Highlight.render(opts()) |> Phoenix.HTML.safe_to_string()
    assert second == first
  end

  test "a test's assertions are found once and read from the table after" do
    record = %{
      "id" => ~S|Cached.CheckTest."test counts"/1|,
      "kind" => "test",
      "file" => "test/check_test.exs",
      "span" => %{"start_line" => 3, "end_line" => 5},
      "source" => "test \"counts\" do\n  assert count() == 1\nend",
      "calls" => []
    }

    assert [{4..4//1, _html}] = first = Highlight.assertions(record)

    assert :ets.lookup(:grasp_highlight_cache, {:assertions, record["id"]}) == [
             {{:assertions, record["id"]}, first}
           ]

    rewritten = %{record | "source" => "test \"counts\" do\n  :ok\nend"}
    assert Highlight.assertions(rewritten) == first
  end

  test "clear_cache/0 empties the table" do
    record("Cleared.f/1") |> Highlight.render(opts())
    assert :ets.info(:grasp_highlight_cache, :size) > 0

    assert :ok = Highlight.clear_cache()
    assert :ets.info(:grasp_highlight_cache, :size) == 0
  end

  test "ensure_cache/0 is idempotent and keeps what is already memoised" do
    record("Kept.f/1") |> Highlight.render(opts())

    assert :ok = Highlight.ensure_cache()
    assert :ets.lookup(:grasp_highlight_cache, "Kept.f/1") != []
  end
end
