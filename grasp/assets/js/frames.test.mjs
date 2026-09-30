import {test} from "node:test"
import assert from "node:assert/strict"
import {crossesFrame, flowKey, moduleKey, hiddenByFrame} from "./frames.js"

const card = (group, module) => ({group, module})

test("the cards in no group have no flow frame", () => {
  assert.equal(flowKey(""), null)
  assert.equal(flowKey("3"), "flow:3")
  assert.equal(moduleKey("", "Acme.Accounts"), "module:|Acme.Accounts")
})

test("nothing is hidden while every frame is open", () => {
  assert.equal(hiddenByFrame(card("1", "A"), card("2", "B"), new Set(), true), false)
})

test("a closed flow frame hides the edges leaving it and arriving in it", () => {
  const closed = new Set([flowKey("1")])
  assert.equal(hiddenByFrame(card("1", "A"), card("2", "B"), closed, false), true)
  assert.equal(hiddenByFrame(card("2", "B"), card("1", "A"), closed, false), true)
  assert.equal(hiddenByFrame(card("", "B"), card("1", "A"), closed, false), true)
})

test("a closed flow frame keeps the edges between its own cards", () => {
  const closed = new Set([flowKey("1")])
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "B"), closed, false), false)
})

test("a closed flow frame leaves the edges between other frames alone", () => {
  const closed = new Set([flowKey("1")])
  assert.equal(hiddenByFrame(card("2", "A"), card("3", "B"), closed, false), false)
})

test("a closed module frame hides the edges crossing it, inside its flow as well", () => {
  const closed = new Set([moduleKey("1", "A")])
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "B"), closed, true), true)
  assert.equal(hiddenByFrame(card("1", "B"), card("1", "A"), closed, true), true)
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "A"), closed, true), false)
})

test("a module frame is the module inside one flow, not every card of the module", () => {
  const closed = new Set([moduleKey("1", "A")])
  assert.equal(hiddenByFrame(card("2", "A"), card("2", "B"), closed, true), false)
})

test("a closed module frame hides nothing while the clusters are undrawn", () => {
  const closed = new Set([moduleKey("1", "A")])
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "B"), closed, false), false)
})

test("an edge between two flows, or two clusters, crosses a frame", () => {
  assert.equal(crossesFrame(card("1", "A"), card("2", "A"), false), true)
  assert.equal(crossesFrame(card("", "A"), card("2", "A"), false), true)
  assert.equal(crossesFrame(card("1", "A"), card("1", "B"), true), true)
  assert.equal(crossesFrame(card("1", "A"), card("1", "B"), false), false)
  assert.equal(crossesFrame(card("1", "A"), card("1", "A"), true), false)
  assert.equal(crossesFrame(card("", "A"), card("", "A"), true), false)
})

test("every frame closed hides every edge crossing one and keeps the rest", () => {
  const none = new Set()
  assert.equal(hiddenByFrame(card("1", "A"), card("2", "B"), none, true, true), true)
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "B"), none, true, true), true)
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "A"), none, true, true), false)
  assert.equal(hiddenByFrame(card("1", "A"), card("1", "B"), none, false, true), false)
})
