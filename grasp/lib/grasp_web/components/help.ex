defmodule GraspWeb.Help do
  @moduledoc """
  The keys-and-gestures list: a `<dialog>` naming every gesture and chord the canvas answers
  that the toolbar has no room to show.

  Nothing here is session state — the list is the same for every reader of every session — so
  the dialog is rendered once and marked `phx-update="ignore"`, and the `Help` hook owns it
  from there. That is what lets it be a modal one, opened with `showModal()`: the server never
  patches the `open` attribute the browser writes, so nothing closes it behind the reader's
  back, and Escape and the `::backdrop` come from the platform rather than from markup.
  """

  use GraspWeb, :html

  def help_dialog(assigns) do
    ~H"""
    <dialog id="help" class="help" phx-hook="Help" phx-update="ignore" aria-labelledby="help-title">
      <div class="help__body">
        <div class="help__head">
          <h2 id="help-title">Keys and gestures</h2>
          <button type="button" class="help__close" aria-label="Close">×</button>
        </div>

        <h3>Mouse</h3>
        <dl>
          <dt><kbd>Drag a card's header</kbd></dt>
          <dd>Move the card. Ctrl+drag anywhere on it does the same.</dd>
          <dt><kbd>Alt+drag a card</kbd></dt>
          <dd>Move every card connected to it.</dd>
          <dt><kbd>Drag a frame's title</kbd></dt>
          <dd>Move the whole group. Click the title to rename it.</dd>
          <dt><kbd>Drag a module's label</kbd></dt>
          <dd>Move every card of that module in the flow.</dd>
          <dt><kbd>Drop a card in another frame</kbd></dt>
          <dd>Move it to that group.</dd>
          <dt><kbd>Shift+click a card</kbd></dt>
          <dd>Select it; Shift+click again deselects.</dd>
          <dt><kbd>Drag the background</kbd></dt>
          <dd>
            Pan. Space+drag pans from anywhere, the wheel pans, and ⌘+wheel zooms about the cursor.
          </dd>
          <dt><kbd>Double-click an edge</kbd></dt>
          <dd>Jump to the card at its far end.</dd>
          <dt><kbd>Click a line number</kbd></dt>
          <dd>Comment on that line. Drag along the numbers, or Shift+click, for a range.</dd>
        </dl>

        <h3>Keys</h3>
        <dl>
          <dt>
            <kbd>←</kbd>/<kbd>h</kbd> <kbd>→</kbd>/<kbd>l</kbd> <kbd>↑</kbd>/<kbd>k</kbd> <kbd>↓</kbd>/<kbd>j</kbd>
          </dt>
          <dd>Move focus to caller, callee, previous, next.</dd>
          <dt><kbd>x</kbd></dt>
          <dd>Close the focused card.</dd>
          <dt><kbd>Shift+x</kbd></dt>
          <dd>Close it with everything only it reached.</dd>
          <dt><kbd>c</kbd></dt>
          <dd>Collapse the focused card.</dd>
          <dt><kbd>d</kbd></dt>
          <dd>Show source or diff.</dd>
          <dt><kbd>z</kbd></dt>
          <dd>Fold the unchanged lines.</dd>
          <dt><kbd>s</kbd></dt>
          <dd>Signatures instead of code.</dd>
          <dt><kbd>v</kbd></dt>
          <dd>What the suite ran, and the clauses it never entered.</dd>
          <dt><kbd>m</kbd></dt>
          <dd>Module frames round the cards.</dd>
          <dt><kbd>f</kbd></dt>
          <dd>Fit every card on screen.</dd>
          <dt><kbd>⌘0</kbd></dt>
          <dd>Reset the zoom.</dd>
          <dt><kbd>⌘K</kbd> or <kbd>/</kbd></dt>
          <dd>Open the palette.</dd>
          <dt><kbd>⌘G</kbd></dt>
          <dd>Group the selection.</dd>
          <dt><kbd>⇧⌘G</kbd></dt>
          <dd>Ungroup it.</dd>
          <dt><kbd>Esc</kbd></dt>
          <dd>Clear the selection.</dd>
          <dt><kbd>⌘M</kbd> or <kbd>⌘\</kbd></dt>
          <dd>Show or hide the sidebar.</dd>
          <dt><kbd>⌘I</kbd></dt>
          <dd>Show or hide the chat.</dd>
          <dt><kbd>?</kbd></dt>
          <dd>This list.</dd>
        </dl>

        <h3>Chat</h3>
        <dl>
          <dt><kbd>Enter</kbd></dt>
          <dd>Send.</dd>
          <dt><kbd>Shift+Enter</kbd></dt>
          <dd>Break a line.</dd>
          <dt><kbd>↑</kbd></dt>
          <dd>In an empty box, recall the last prompt.</dd>
        </dl>

        <p class="help__footer">⌘ is Ctrl outside macOS.</p>
      </div>
    </dialog>
    """
  end
end
