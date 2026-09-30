// `arrange` under Node's own test runner: no browser and no dependency, the boxes and the call
// lines given as the hook would measure them.
import {test} from "node:test"
import assert from "node:assert/strict"
import {arrange} from "./layout.js"

const card = (id, column, extra = {}) => ({
  id,
  column,
  module: extra.module ?? `M${id}`,
  width: extra.width ?? 100,
  height: extra.height ?? 50,
})

const section = (cards, edges = [], extra = {}) => ({group: "1", head: 0, cards, edges, ...extra})

const layout = (sections, extra = {}) =>
  arrange({sections, gapX: 40, gapY: 10, sectionGap: 30, ...extra})

// The cards of one column, top to bottom.
const columnOrder = (positions, ids) =>
  [...ids].sort((a, b) => positions[a].y - positions[b].y)

test("a column starts one gap right of the widest card of the column before it", () => {
  const at = layout([
    section(
      [
        card("a", 0, {width: 120}),
        card("b", 0, {width: 200}),
        card("c", 1, {width: 80}),
        card("d", 2),
      ],
      [
        {from: "a", to: "c", line: null},
        {from: "b", to: "c", line: null},
        {from: "c", to: "d", line: null},
      ],
    ),
  ])

  assert.equal(at.a.x, 0)
  assert.equal(at.b.x, 0)
  assert.equal(at.c.x, 240)
  assert.equal(at.d.x, 360)
})

test("a column starts in the order of the calls that opened its cards", () => {
  // The edges arrive in the order the cards were opened, which is not the order the calls
  // stand in the caller.
  const at = layout([
    section(
      [card("root", 0), card("late", 1), card("early", 1), card("middle", 1)],
      [
        {from: "root", to: "late", line: 40},
        {from: "root", to: "early", line: 5},
        {from: "root", to: "middle", line: 20},
      ],
    ),
  ])

  assert.deepEqual(columnOrder(at, ["late", "early", "middle"]), ["early", "middle", "late"])
})

test("callers are taken in the order of their own rows", () => {
  const at = layout([
    section(
      [card("r", 0), card("p", 1), card("q", 1), card("pp", 2), card("qq", 2)],
      [
        {from: "r", to: "p", line: 5},
        {from: "r", to: "q", line: 30},
        {from: "q", to: "qq", line: 5},
        {from: "p", to: "pp", line: 5},
      ],
    ),
  ])

  assert.deepEqual(columnOrder(at, ["pp", "qq"]), ["pp", "qq"])
})

test("the sweeps uncross a pair the call order leaves crossed", () => {
  // `x` is opened first, so the call order puts it on top, but three cards below `a` call it
  // and only `a` calls `y`: with `x` on top the edges from `b` and `c` cross the one to `y`.
  const at = layout([
    section(
      [card("a", 0), card("b", 0), card("c", 0), card("x", 1), card("y", 1)],
      [
        {from: "a", to: "x", line: null},
        {from: "a", to: "y", line: null},
        {from: "b", to: "x", line: null},
        {from: "c", to: "x", line: null},
      ],
    ),
  ])

  assert.deepEqual(columnOrder(at, ["a", "b", "c"]), ["a", "b", "c"])
  assert.deepEqual(columnOrder(at, ["x", "y"]), ["y", "x"])
})

test("the cards of one module stand together in a column", () => {
  const at = layout([
    section(
      [
        card("r", 0),
        card("s1", 1, {module: "S"}),
        card("t", 1, {module: "T"}),
        card("s2", 1, {module: "S"}),
      ],
      [
        {from: "r", to: "s1", line: 5},
        {from: "r", to: "t", line: 20},
        {from: "r", to: "s2", line: 35},
      ],
    ),
  ])

  assert.deepEqual(columnOrder(at, ["s1", "t", "s2"]), ["s1", "s2", "t"])
})

test("different modules in a column leave room for their frames, one module does not", () => {
  const at = layout(
    [
      section(
        [
          card("r", 0, {module: "R"}),
          card("s1", 1, {module: "S"}),
          card("s2", 1, {module: "S"}),
          card("t", 1, {module: "T"}),
        ],
        [
          {from: "r", to: "s1", line: null},
          {from: "r", to: "s2", line: null},
          {from: "r", to: "t", line: null},
        ],
      ),
    ],
    {moduleHead: 20, modulePad: 6},
  )

  // While the clusters are drawn a column leaves room for the frames on either side of the gap.
  assert.equal(at.s1.x, 100 + 40 + 2 * 6)
  assert.equal(at.s1.y, 20)
  assert.equal(at.s2.y, at.s1.y + 50 + 10)
  assert.equal(at.t.y, at.s2.y + 50 + 6 + 10 + 20)
})

test("a module's blocks in neighbouring columns share a top", () => {
  // `q` of module Q is called from low down in `p`, and `r` of module Q again from `q`; but Q
  // also stands in column 1, so its block in column 2 takes the top of the one in column 1.
  const at = layout([
    section(
      [
        card("p", 0, {module: "P", height: 200}),
        card("o", 1, {module: "O"}),
        card("q", 1, {module: "Q"}),
        card("r", 2, {module: "Q"}),
      ],
      [
        {from: "p", to: "o", line: 20},
        {from: "p", to: "q", line: 150},
        {from: "q", to: "r", line: 40},
      ],
    ),
  ])

  assert.equal(at.r.y, at.q.y)
})

test("a module's cards across two columns come to stand in one band", () => {
  // `k2` is listed first, so the call order puts it on top of its column; it has no edge into
  // column 1, so the sweep gives it its module's row there, and it comes to stand beside `k1`
  // rather than beside `other`.
  const at = layout([
    section(
      [
        card("k2", 2, {module: "K"}),
        card("root", 0, {module: "R"}),
        card("other", 1, {module: "O"}),
        card("k1", 1, {module: "K"}),
        card("o2", 2, {module: "O"}),
        card("far", 3, {module: "F"}),
      ],
      [
        {from: "root", to: "other", line: 5},
        {from: "root", to: "k1", line: 30},
        {from: "other", to: "o2", line: 5},
        {from: "o2", to: "far", line: 5},
        {from: "far", to: "k2", line: 5},
      ],
    ),
  ])

  assert.deepEqual(columnOrder(at, ["other", "k1"]), ["other", "k1"])
  assert.deepEqual(columnOrder(at, ["o2", "k2"]), ["o2", "k2"])
  assert.equal(at.k2.y, at.k1.y)
})

test("components stack in the order of their first card, sections under the frame above", () => {
  const at = layout([
    section(
      [card("a", 0), card("b", 1), card("c", 0, {height: 80}), card("d", 1)],
      [
        {from: "a", to: "b", line: null},
        {from: "c", to: "d", line: null},
      ],
      {group: "1", head: 40, pad: 12},
    ),
    section([card("e", 0), card("f", 1, {height: 90})], [{from: "e", to: "f", line: null}], {
      group: "2",
      head: 40,
      pad: 12,
    }),
  ])

  assert.equal(at.a.y, 40)
  assert.equal(at.b.y, 40)
  // The second component starts a gap under the lowest card of the first.
  assert.equal(at.c.y, 40 + 50 + 10)
  assert.equal(at.d.y, at.c.y)
  // The second section's frame starts a section gap under the first frame's bottom padding,
  // and its cards stand its head below that.
  const firstBottom = at.c.y + 80 + 12
  assert.equal(at.e.y, firstBottom + 30 + 40)
  assert.equal(at.f.x, 140)
})

test("a callee stands at its call's line, or below the card above it when that is lower", () => {
  const at = layout(
    [
      section(
        [card("caller", 0, {height: 300}), card("one", 1), card("two", 1)],
        [
          {from: "caller", to: "one", line: 100},
          {from: "caller", to: "two", line: 120},
        ],
      ),
    ],
    {port: 18},
  )

  assert.equal(at.caller.y, 0)
  assert.equal(at.one.y, 100 - 18)
  assert.equal(at.two.y, at.one.y + 50 + 10)
})

test("an edge back to an earlier column is accepted and aligns nothing", () => {
  const at = layout([
    section(
      [card("template", 0), card("controller", 1)],
      [{from: "controller", to: "template", line: 30}],
    ),
  ])

  assert.equal(at.template.x, 0)
  assert.equal(at.controller.x, 140)
  assert.equal(at.template.y, 0)
  assert.equal(at.controller.y, 0)
})

test("every coordinate is an integer", () => {
  const at = layout(
    [
      section(
        [card("a", 0, {width: 100.4, height: 33.3}), card("b", 1, {height: 20.7}), card("c", 1)],
        [
          {from: "a", to: "b", line: 7.3},
          {from: "a", to: "c", line: 11.9},
        ],
        {head: 12.6},
      ),
    ],
    {gapX: 40.5, gapY: 9.9},
  )

  for (const {x, y} of Object.values(at)) {
    assert.ok(Number.isInteger(x), `x ${x} is not an integer`)
    assert.ok(Number.isInteger(y), `y ${y} is not an integer`)
  }
  assert.ok(at.c.y >= at.b.y + 20.7 + 9.9)
})

// Every rectangle the canvas draws for an arranged section: the frame round each module's
// cards, as the hook draws it, and every card. A module frame holds no card of another module
// and meets no other module's frame, and no two cards overlap.
const assertModulesApart = (input, at) => {
  const head = input.moduleHead ?? 0
  const pad = input.modulePad ?? 0
  for (const {cards} of input.sections) {
    const box = (c) => ({
      left: at[c.id].x,
      top: at[c.id].y,
      right: at[c.id].x + c.width,
      bottom: at[c.id].y + c.height,
    })
    const hit = (a, b) =>
      a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
    const frames = new Map()
    for (const c of cards) {
      if (!c.module) continue
      const b = box(c)
      const f = frames.get(c.module) || {
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity,
      }
      frames.set(c.module, {
        left: Math.min(f.left, b.left - pad),
        top: Math.min(f.top, b.top - head),
        right: Math.max(f.right, b.right + pad),
        bottom: Math.max(f.bottom, b.bottom + pad),
      })
    }
    for (const [module, frame] of frames) {
      for (const c of cards) {
        if (c.module === module) continue
        assert.ok(!hit(frame, box(c)), `card ${c.id} stands inside the frame of ${module}`)
      }
      for (const [other, f] of frames) {
        if (other <= module) continue
        assert.ok(!hit(frame, f), `the frames of ${module} and ${other} meet`)
      }
    }
    for (const [i, a] of cards.entries()) {
      for (const b of cards.slice(i + 1)) {
        assert.ok(!hit(box(a), box(b)), `cards ${a.id} and ${b.id} overlap`)
      }
    }
  }
}

const framed = (sections) => ({
  sections,
  gapX: 48,
  gapY: 16,
  sectionGap: 16,
  moduleHead: 40,
  modulePad: 12,
  port: 18,
})

const tall = (id, column, module, height = 100) => ({id, column, module, width: 200, height})

test("a module that grows down in the next column keeps another module out of its frame", () => {
  const input = framed([
    section(
      [
        tall("ctl", 0, "Web.Ctl", 300),
        tall("reg", 1, "Accounts"),
        tall("mail", 1, "Mailer"),
        tall("h1", 2, "Accounts"),
        tall("h2", 2, "Accounts"),
        tall("h3", 2, "Accounts"),
      ],
      [
        {from: "ctl", to: "reg", line: 40},
        {from: "ctl", to: "mail", line: 200},
        {from: "reg", to: "h1", line: 20},
        {from: "reg", to: "h2", line: 50},
        {from: "reg", to: "h3", line: 80},
      ],
      {head: 60, pad: 28},
    ),
  ])
  const at = arrange(input)

  assertModulesApart(input, at)
  // What is not in the way keeps its call line.
  assert.equal(at.reg.y, at.ctl.y + 40 - 18)
})

test("the cards of one module are one component, so one frame spans nothing else", () => {
  const input = framed([
    section(
      [
        tall("a", 0, "A"),
        tall("ra", 1, "Repo"),
        tall("x", 1, "X"),
        tall("b", 0, "B"),
        tall("rb", 1, "Repo"),
      ],
      [
        {from: "a", to: "ra", line: 10},
        {from: "a", to: "x", line: 60},
        {from: "b", to: "rb", line: 10},
      ],
      {head: 60, pad: 28},
    ),
  ])
  const at = arrange(input)

  assertModulesApart(input, at)
  assert.deepEqual(columnOrder(at, ["ra", "rb", "x"]), ["ra", "rb", "x"])
})

test("no module frame holds another module's card on any of a seeded batch of canvases", () => {
  // A linear congruential generator, so the batch is the same on every run.
  let seed = 20260930
  const random = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  }
  const pick = (n) => Math.floor(random() * n)
  const modules = ["A", "B", "C", "D", ""]

  for (let round = 0; round < 300; round++) {
    const sections = []
    for (let s = 0; s <= pick(2); s++) {
      const count = 2 + pick(11)
      const cards = []
      for (let i = 0; i < count; i++) {
        cards.push({
          id: `s${s}c${i}`,
          column: pick(4),
          module: modules[pick(modules.length)],
          width: 120 + pick(200),
          height: 40 + pick(260),
        })
      }
      const edges = []
      for (let e = 0; e < count + pick(count); e++) {
        const a = cards[pick(count)]
        const b = cards[pick(count)]
        if (a === b) continue
        edges.push({from: a.id, to: b.id, line: random() < 0.2 ? null : pick(a.height)})
      }
      sections.push({group: String(s + 1), head: 60, pad: 28, cards, edges})
    }
    const input = framed(sections)
    const at = arrange(input)
    for (const {x, y} of Object.values(at)) assert.ok(Number.isInteger(x) && Number.isInteger(y))
    assertModulesApart(input, at)
  }
})
