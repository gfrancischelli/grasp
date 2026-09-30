// The canvas laid out in layered columns: from the boxes the hook measured, the columns the
// server rendered and the edges between the cards, a position for every card. Nothing here
// reads or writes the document, so the step is tested under `node --test` without a browser,
// and the same input always answers the same positions.
//
// The input is
//
//   {sections: [{group, head, pad, cards: [{id, column, module, width, height}],
//                edges: [{from, to, line}]}],
//    gapX, gapY, sectionGap, moduleHead, modulePad, port}
//
// and the answer `{id: {x, y}}`, integers in the units the boxes were given in.
//
// - `sections` stand top to bottom in the order given, the first one's frame starting at y 0,
//   and each next frame `sectionGap` under the frame above. `head` is the room the section's
//   frame takes above its first card and `pad` the room it takes below its last (both 0 for a
//   section that draws no frame; `pad` defaults to 0).
// - `column` is the card's column within its section, as the server renders it on the node;
//   `module` names the module cluster the card falls into, the empty string for none.
// - An edge runs from a caller to a callee. `line` is the call site's offset from the caller's
//   top, or null where the browser gave the site no box. An edge whose callee does not stand
//   right of its caller — a template standing left of the controller that renders it — joins
//   the two into one component and counts in the sweeps, which are about crossings and
//   crossings have no direction, but never orders the call-site pass or aligns a card to a
//   line: a line points forwards or it is no line to stand at.
// - `gapX` is the gap between columns, `gapY` the gap between two cards of one column.
// - `moduleHead` and `modulePad` are the room a module frame takes above and below its cards,
//   0 when the clusters are not drawn, so that two modules stacked in one column leave their
//   frames a `gapY` apart where two cards of one module stand only `gapY` apart. Both default
//   to 0.
// - `port` is how far below a card's top an edge arrives, so that a callee aligned to a call
//   line takes the line at its port rather than at its top edge. It defaults to 0.
//
// The steps, section by section:
//
// 1. x. Column `c` starts `gapX` right of the widest card of the column before it in the
//    section, so a column is as wide as its widest card and every component of the section
//    shares the same columns.
// 2. Components. The cards joined by edges are one component; each is laid out on its own
//    and they stack in the order of their first card.
// 3. Call-site order. A depth-first walk from the component's sources — the cards no forward
//    edge arrives at, in the order given — takes each caller's callees in the order of their
//    lines, a site with no line after the ones with one. A column starts in the order the walk
//    reached its cards, so a callee stands below another when the call that opened it comes
//    later in its caller, and the callees of a higher caller stand above those of a lower one.
// 4. Sweeps. Four sweeps, left to right, right to left, and again, reorder each column by the
//    mean row of the cards it is joined to in the neighbouring column on the side the sweep
//    comes from. A neighbour of the card's own module counts three times, and a card with no
//    edge into that column takes the mean row of its module's cards there; a card with neither
//    keeps its slot and the others are ordered round it.
// 5. Module blocks. After every ordering the cards of one module in one column are gathered at
//    the place of the first of them, so a module frame never has another module's card inside
//    it.
// 6. y. Columns left to right, each top to bottom. A card stands at the line of the call that
//    opened it where that line is known, the first block of a module takes the top of its
//    module's block in the column before where there is one, so the module frame is one
//    rectangle rather than a staircase; and nothing ever stands higher than the card above it
//    in its column allows — `gapY` under it, with room for the two module frames between them
//    when the two are of different modules.

const SAME_MODULE_WEIGHT = 3
const SWEEPS = ["right", "left", "right", "left"]

export function arrange(input) {
  const {sections, gapX, gapY, sectionGap} = input
  const moduleHead = input.moduleHead ?? 0
  const modulePad = input.modulePad ?? 0
  const port = input.port ?? 0
  const space = {gapY, moduleHead, modulePad, port}

  const positions = {}
  // The top of the next section's frame.
  let top = 0
  for (const section of sections) {
    const bottom = arrangeSection(section, top, gapX, space, positions)
    top = bottom + (section.pad ?? 0) + sectionGap
  }
  return positions
}

// Lays one section out with its frame's top at `top`, writing into `positions`, and answers the
// lowest point its cards and their module frames reach.
function arrangeSection(section, top, gapX, space, positions) {
  const {cards, edges} = section
  const byId = new Map(cards.map((c) => [String(c.id), c]))
  // Edges between two cards of the section, anything else being a call into or out of it that
  // this section's layout has nothing to say about.
  const inside = edges.filter((e) => byId.has(String(e.from)) && byId.has(String(e.to)))
  const from = (e) => byId.get(String(e.from))
  const to = (e) => byId.get(String(e.to))
  const forward = inside.filter((e) => to(e).column > from(e).column)

  // Step 1: a column's left edge from the widest card of every column before it.
  const columns = [...new Set(cards.map((c) => c.column))].sort((a, b) => a - b)
  const left = new Map()
  let x = 0
  for (const column of columns) {
    left.set(column, x)
    const widest = Math.max(...cards.filter((c) => c.column === column).map((c) => c.width))
    x += widest + gapX
  }

  // Undirected neighbours, each once, weighted by whether the two share a module.
  const neighbours = new Map(cards.map((c) => [c, new Map()]))
  for (const e of inside) {
    const a = from(e)
    const b = to(e)
    if (a === b) continue
    const weight = a.module && a.module === b.module ? SAME_MODULE_WEIGHT : 1
    neighbours.get(a).set(b, weight)
    neighbours.get(b).set(a, weight)
  }

  // Step 2: components, in the order of their first card.
  const component = new Map()
  const components = []
  for (const start of cards) {
    if (component.has(start)) continue
    const members = []
    const stack = [start]
    component.set(start, members)
    while (stack.length > 0) {
      const c = stack.pop()
      members.push(c)
      for (const n of neighbours.get(c).keys()) {
        if (component.has(n)) continue
        component.set(n, members)
        stack.push(n)
      }
    }
    components.push(members)
  }

  // Each card's opener: the first forward edge in the order given that arrives at it, which is
  // the call the card was opened from.
  const opener = new Map()
  for (const e of forward) if (!opener.has(to(e))) opener.set(to(e), e)

  let componentTop = top + (section.head ?? 0)
  let bottom = top
  for (const members of components) {
    const reach = arrangeComponent(members, cards, forward, from, to, neighbours, opener, {
      left,
      top: componentTop,
      space,
      positions,
    })
    bottom = Math.max(bottom, reach)
    componentTop = reach + space.gapY
  }
  return bottom
}

// Orders and places the cards of one component, whose frames start at `top`, and answers the
// lowest point its cards and their module frames reach.
function arrangeComponent(members, cards, forward, from, to, neighbours, opener, at) {
  const {left, top, space, positions} = at
  const inComponent = new Set(members)
  // The component's cards in the order the section gave them, which is where the walk starts.
  const given = cards.filter((c) => inComponent.has(c))

  // Step 3: the depth-first walk. A caller's calls are taken by line, a missing line last, and
  // edges of one line in the order given.
  const calls = new Map(given.map((c) => [c, []]))
  forward.forEach((e, i) => {
    if (inComponent.has(from(e))) calls.get(from(e)).push({e, i})
  })
  for (const list of calls.values()) {
    list.sort((a, b) => lineKey(a.e) - lineKey(b.e) || a.i - b.i)
  }
  const reached = new Map()
  const walk = (c) => {
    if (reached.has(c)) return
    reached.set(c, reached.size)
    for (const {e} of calls.get(c)) walk(to(e))
  }
  for (const c of given) if (!opener.has(c)) walk(c)
  for (const c of given) walk(c)

  const columnKeys = [...new Set(given.map((c) => c.column))].sort((a, b) => a - b)
  const order = new Map(
    columnKeys.map((column) => [
      column,
      gatherModules(
        given.filter((c) => c.column === column).sort((a, b) => reached.get(a) - reached.get(b)),
      ),
    ]),
  )

  // Step 4: the sweeps, each reordering a column against the one on the side it comes from.
  for (const direction of SWEEPS) {
    const indices = columnKeys.map((_, i) => i)
    if (direction === "left") indices.reverse()
    for (const i of indices.slice(1)) {
      const beside = columnKeys[direction === "right" ? i - 1 : i + 1]
      const column = columnKeys[i]
      const swept = sweepColumn(order.get(column), order.get(beside), neighbours)
      order.set(column, gatherModules(swept))
    }
  }

  // Step 6: y, column by column, so that every caller a forward edge leaves stands before the
  // callee is placed against its line.
  const placed = new Map()
  let reach = top
  let previousBlocks = new Map()
  for (const column of columnKeys) {
    const blocks = new Map()
    let above = null
    for (const c of order.get(column)) {
      const firstOfBlock = !above || !c.module || above.module !== c.module
      let lowest
      if (above) {
        lowest = placed.get(above).y + above.height + space.gapY
        if (above.module && above.module !== c.module) lowest += space.modulePad
        if (c.module && above.module !== c.module) lowest += space.moduleHead
      } else {
        lowest = top + (c.module ? space.moduleHead : 0)
      }
      let wanted = null
      const shared = firstOfBlock && c.module ? previousBlocks.get(c.module) : undefined
      if (shared !== undefined) {
        wanted = shared
      } else {
        const e = opener.get(c)
        if (e && e.line !== null && e.line !== undefined && placed.has(from(e))) {
          const caller = from(e)
          const line = Math.min(Math.max(e.line, 0), caller.height)
          wanted = placed.get(caller).y + line - space.port
        }
      }
      const y = Math.ceil(wanted === null ? lowest : Math.max(wanted, lowest))
      const position = {x: Math.ceil(left.get(column)), y}
      placed.set(c, position)
      positions[c.id] = position
      if (firstOfBlock && c.module && !blocks.has(c.module)) blocks.set(c.module, y)
      reach = Math.max(reach, y + c.height + (c.module ? space.modulePad : 0))
      above = c
    }
    previousBlocks = blocks
  }
  return reach
}

// A call with a line sorts by it; one without sorts after every call that has one.
function lineKey(e) {
  return e.line === null || e.line === undefined ? Infinity : e.line
}

// One column reordered by the mean row of each card's neighbours in `beside`. A card joined to
// nothing there takes the mean row of its module's cards there, and a card with neither keeps
// its slot: the other cards are sorted into the slots left over, ties keeping their order.
function sweepColumn(column, beside, neighbours) {
  const row = new Map(beside.map((c, i) => [c, i]))
  const keyOf = (c) => {
    let sum = 0
    let weight = 0
    for (const [n, w] of neighbours.get(c)) {
      if (!row.has(n)) continue
      sum += row.get(n) * w
      weight += w
    }
    if (weight > 0) return sum / weight
    if (!c.module) return null
    const own = beside.filter((n) => n.module === c.module)
    if (own.length === 0) return null
    return own.reduce((total, n) => total + row.get(n), 0) / own.length
  }
  const keyed = column.map((c, i) => ({c, i, key: keyOf(c)}))
  const moving = keyed.filter((k) => k.key !== null).sort((a, b) => a.key - b.key || a.i - b.i)
  const result = []
  let next = 0
  for (const k of keyed) result.push(k.key === null ? k.c : moving[next++].c)
  return result
}

// The cards of each module brought together at the place of the first of them, the order
// otherwise kept. A card of no module is a module of its own.
function gatherModules(column) {
  const blocks = []
  const byModule = new Map()
  for (const c of column) {
    if (!c.module) {
      blocks.push([c])
    } else if (byModule.has(c.module)) {
      byModule.get(c.module).push(c)
    } else {
      const block = [c]
      byModule.set(c.module, block)
      blocks.push(block)
    }
  }
  return blocks.flat()
}
