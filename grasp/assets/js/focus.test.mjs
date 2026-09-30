import {test} from "node:test"
import assert from "node:assert/strict"
import {releasePointerFocus} from "./focus.js"

// A stand-in for a control: `closest` finds the control itself when the selector names its
// kind, and `blur` hands the document's focus back to the body.
const control = (doc, kind) => {
  const el = {
    kind,
    closest: (selector) => (selector.includes(kind) ? el : null),
    blur: () => {
      doc.activeElement = doc.body
    },
  }
  return el
}

const fixture = (kind = "button") => {
  const doc = {body: {}, activeElement: null}
  const el = control(doc, kind)
  doc.activeElement = el
  return {doc, el}
}

test("a pointer click blurs the button it focused", () => {
  const {doc, el} = fixture()
  assert.equal(releasePointerFocus({detail: 1, target: el}, doc), true)
  assert.equal(doc.activeElement, doc.body)
})

test("a click from the keyboard keeps the focus", () => {
  const {doc, el} = fixture()
  assert.equal(releasePointerFocus({detail: 0, target: el}, doc), false)
  assert.equal(doc.activeElement, el)
})

test("a button that moved the focus elsewhere is left alone", () => {
  const {doc, el} = fixture()
  const prompt = {}
  doc.activeElement = prompt
  assert.equal(releasePointerFocus({detail: 1, target: el}, doc), false)
  assert.equal(doc.activeElement, prompt)
})

test("a summary is released like a button", () => {
  const {doc, el} = fixture("summary")
  assert.equal(releasePointerFocus({detail: 1, target: el}, doc), true)
})

test("a click on something that is not a control does nothing", () => {
  const doc = {body: {}, activeElement: null}
  const input = {closest: () => null}
  doc.activeElement = input
  assert.equal(releasePointerFocus({detail: 1, target: input}, doc), false)
  assert.equal(doc.activeElement, input)
})
