// The rule that marks where a hovered card is called from.
//
// A card on the canvas is reached from one or more call sites in the cards that call it, each
// a span naming the card in `data-edge-to`, and from the edges drawn out of them, each naming it
// in `data-to`. Hovering a card lights every one of them up, so the reader sees at a glance
// which line of which caller the card stands for.
//
// The marks are one stylesheet rule the hook rewrites rather than a class put on each span: the
// spans are the server's, and a patch landing while the pointer rests on a card would wipe a
// class the server never rendered, where a rule keyed on the card's id holds across it.

// The CSS for a hovered card id, or the empty string for none. A card id is an integer; any
// other value marks nothing, which keeps whatever it holds out of the stylesheet.
export function hoverRule(id) {
  if (id == null || !/^\d+$/.test(String(id))) return ""
  const to = String(id)
  return (
    `.card [data-edge-to="${to}"]{box-shadow:0 0 0 2px var(--accent);` +
    `background:var(--accent-soft);border-radius:2px}` +
    `.connectors .edge[data-to="${to}"]{stroke:var(--accent);stroke-width:3}`
  )
}

// The id of the card under an event's target, or null off every card.
export function hoveredCard(target) {
  const card = target?.closest?.(".card")
  if (!card || !card.id?.startsWith("card-")) return null
  return card.id.slice("card-".length)
}
