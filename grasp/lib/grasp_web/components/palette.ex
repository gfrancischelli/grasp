defmodule GraspWeb.Palette do
  @moduledoc """
  The Cmd+K function palette: a `<dialog>` with a search input and ranked results.

  Every piece of the palette's state — whether it is open, the query, the results and the
  selected row — lives on the server and is rendered from assigns. The dialog is a plain
  (non-modal) one for that reason: `showModal()` would set an `open` attribute the server
  never renders, and the next patch would strip it, closing the palette as the user types.
  The hook therefore only reports intent (`palette_show`, `palette_hide`, `palette_move`,
  `palette_choose`) and the backdrop is an ordinary sibling element rather than `::backdrop`.

  A result the branch added, modified or removed carries the same change badge the card and
  the sidebar wear, so searching in PR mode says which hits are part of the review, and a
  test or a setup callback wears the badge its card does, so a hit on a test's name reads as
  the test it is. A module is answered by its name beside the functions and wears the
  `module` badge its card does; choosing one opens its module card.
  """

  use GraspWeb, :html

  import GraspWeb.CardComponents, only: [change_badge: 1, test_badge: 1]

  attr :open?, :boolean, required: true
  attr :query, :string, required: true
  attr :results, :list, required: true
  attr :selected, :integer, required: true

  def palette(assigns) do
    ~H"""
    <div :if={@open?} class="palette-backdrop" phx-click="palette_hide"></div>
    <dialog
      id="palette"
      class="palette"
      phx-hook="Palette"
      open={@open?}
      data-open={to_string(@open?)}
    >
      <form
        id="palette-form"
        phx-change="palette_search"
        phx-submit="palette_choose"
        autocomplete="off"
      >
        <input
          type="text"
          name="q"
          value={@query}
          placeholder="Type a function or module name… (Enter opens, Shift+Enter opens under the focused card)"
          phx-debounce="80"
        />
      </form>
      <ul id="palette-results" class="palette__results">
        <li
          :for={{fun, i} <- Enum.with_index(@results)}
          data-id={fun["id"]}
          aria-selected={to_string(i == @selected)}
        >
          <button
            type="button"
            class="palette__item"
            phx-click="palette_open"
            phx-value-id={fun["id"]}
            phx-value-child="false"
          >
            <span class="palette__id">{fun["id"]}</span>
            <.change_badge change={fun["change"]} />
            <.test_badge kind={fun["kind"]} />
            <span :if={fun["kind"] == "module"} class="badge badge--module">module</span>
            <span class="palette__meta">{fun["kind"]} · {fun["file"]}</span>
          </button>
        </li>
      </ul>
    </dialog>
    """
  end
end
