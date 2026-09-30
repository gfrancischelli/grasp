import {test} from "node:test"
import assert from "node:assert/strict"
import {hoverRule, hoveredCard} from "./hover.js"

test("a hovered card marks the call sites and the edges naming it", () => {
  const rule = hoverRule("7")
  assert.match(rule, /\.card \[data-edge-to="7"\]\{[^}]*box-shadow/)
  assert.match(rule, /\.connectors \.edge\[data-to="7"\]\{[^}]*stroke:/)
})

test("no card hovered marks nothing", () => {
  assert.equal(hoverRule(null), "")
})

test("an id that is not a card's marks nothing", () => {
  assert.equal(hoverRule('7"]{}body{'), "")
})

test("the card under a target is read from its id", () => {
  const card = {id: "card-12"}
  const inside = {closest: (selector) => (selector === ".card" ? card : null)}
  assert.equal(hoveredCard(inside), "12")
  assert.equal(hoveredCard({closest: () => null}), null)
  assert.equal(hoveredCard(null), null)
})
