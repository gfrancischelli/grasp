// Which edges a closed frame hides.
//
// A frame's title carries a toggle for the arrows that travel into or out of it: an edge with
// exactly one end among the frame's cards crosses its border, and a reader closing the frame
// hides every such edge while the arrows between its own cards stay. A flow frame is named by
// its group, a module frame by the module inside the group it stands in, which is how the
// hook tells the two kinds of frame apart and how a card names the frames round it.
//
// A card in no group stands in no flow frame, so it has no flow key. A module frame is drawn
// only while the clusters are, so a closed module frame hides nothing while they are off: its
// toggle is not on the canvas to be pressed again.

// The key of the flow frame round a group, or null for the cards in none.
export function flowKey(group) {
  return group === "" || group == null ? null : `flow:${group}`
}

// The key of the module frame round `module`'s cards inside `group`.
export function moduleKey(group, module) {
  return `module:${group ?? ""}|${module}`
}

// Whether an edge from the card `from` to the card `to`, each `{group, module}`, crosses the
// border of a frame in `closed` (a Set of keys), counting module frames only when
// `modulesDrawn`.
export function hiddenByFrame(from, to, closed, modulesDrawn) {
  if (closed.size === 0) return false
  const fromFlow = flowKey(from.group)
  const toFlow = flowKey(to.group)
  if (fromFlow !== toFlow) {
    if ((fromFlow && closed.has(fromFlow)) || (toFlow && closed.has(toFlow))) return true
  }
  if (!modulesDrawn) return false
  const fromModule = moduleKey(from.group, from.module)
  const toModule = moduleKey(to.group, to.module)
  return fromModule !== toModule && (closed.has(fromModule) || closed.has(toModule))
}
