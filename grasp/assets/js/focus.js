// A button a pointer clicked gives its focus back.
//
// A browser leaves focus on a button after a click, and a focused button takes Space and Enter
// as another press of itself. The canvas claims Space for panning and the toolbar's buttons
// have single-key shortcuts of their own, so a button left focused by the mouse fires again
// the next time the reader pans or presses a key. A click the keyboard made (Space or Enter on
// a focused button, which the browser reports with `detail` 0) keeps its focus, so tabbing
// through the toolbar still works.
//
// The listener runs on the document after the button's own handlers, so a button that moved
// focus somewhere on purpose — the chat toggle focusing the prompt — is left alone: the
// button is blurred only while it still holds the focus.

const RELEASED = "button, summary, [role='button']"

// Blurs the control `event` clicked when a pointer clicked it and it still holds the focus.
// Answers whether it blurred one.
export function releasePointerFocus(event, doc = document) {
  if (!event || event.detail === 0) return false
  const control = event.target?.closest?.(RELEASED)
  if (!control || doc.activeElement !== control) return false
  control.blur()
  return true
}

// Installs `releasePointerFocus` on the document for every click.
export function installPointerFocusRelease(doc = document) {
  doc.addEventListener("click", (event) => releasePointerFocus(event, doc))
}
