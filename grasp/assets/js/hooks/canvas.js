// The card canvas: pan, zoom, card dragging and the SVG edges that run from a call site to
// the card it calls.
//
// The view is {x, y, scale} and is written to a single stylesheet rule rather than to
// #stage's style attribute, because #stage is rendered by the server and a LiveView patch
// would wipe an inline transform mid-gesture. Drag is the one exception: a dragged node
// carries an inline translate so the move is seen at once, and updated() clears it as
// soon as the server has rendered the position it was pushed.
//
// The canvas is a whiteboard: every card sits at a position of its own, in stage pixels from
// the stage's corner, and a card is moved by a hand or by a card above it growing into it: a
// card that grows pushes what it would cover down by the amount it grew, and gives that room
// back when it shrinks, so long as the cards it pushed are still where the push left them. A
// card the server has no position for is rendered at the origin and held back from sight until
// this hook has measured it and said where it goes — the browser is the only thing that knows
// how large a card came out, so placement is the hook's alone. A pass places every such card
// beside the card it was opened from and pushes the lot in one `place_cards`; the server fills
// a position only where there is none, so a card already placed is never moved by a pass.
//
// Positions may be negative: a caller opened to the left of a card at the stage's corner lands
// left of it. Nothing shifts to make room — the stage is not clipped and the pan reaches
// wherever the cards are, so negative coordinates are shown by panning to them, and `fit()`
// measures the boxes rather than the stage.
//
// Edge paths live inside a phx-update="ignore" <svg>, so the hook owns them and the server
// never renders one. The server does render that svg's <defs>, because an arrowhead marker
// has to be in the document before a path can point at it. The zoom readout is ignored by
// patches for the same reason the edges are: the hook writes it on every view change.
//
// A group's frame is drawn by the hook too, into another ignored layer. The cards inside a
// section are dragged about freely, so the frame is measured from where they ended up rather
// than being the section's own box, and the section's header is moved to sit above it.
//
// Signature mode is a mode the reader turns on, from the toolbar or with `s`: the hook puts
// `grasp-signatures` on <body> and the rules in app.css cut every card down to its header and
// the one line that names it. The zoom decides nothing about it, so a canvas stays as it is
// read wherever it is panned or zoomed to.
//
// A frame's title is a handle too: Ctrl+drag on it moves every card of that group at once.
//
// Inside a frame the cards of one module are framed together again, with the module's name
// over them. A cluster is derived from the cards on the canvas and stored nowhere: the same
// module open in two flows is two clusters, one per flow. Its label is the handle the cluster
// is dragged by, and a drop is still decided by the flow frames alone, so a module frame
// changes no membership. The `modules` toggle and the `m` key turn the clusters off.
//
// A card is dragged by its header, or from anywhere on it with Ctrl held; holding Space turns
// the whole canvas, cards included, into a pan surface. A card dropped anywhere inside another
// group's frame joins that group — the drop is decided against the rectangles the hook drew —
// and Shift+click picks cards out into the selection ⌘G frames: the two halves of grouping by
// hand.

const MIN_SCALE = 0.05
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 4
const MARGIN = 24
// Half a card header near 1:1, so an edge arrives at the callee's title rather than at
// its corner; in signature mode the header is a thin strip and the port lands just under it.
const PORT_Y = 18
// A Ctrl-drag's release is still a context-menu gesture; long enough to cover the menu the
// browser opens just after the drag has ended.
const CTRL_MENU_GRACE = 300
// The frame's padding round the cards it holds — wide enough that a card reads as standing
// inside the frame rather than against its border — and the gap between the frame and the
// header above it. The header's bottom margin is counter-scaled, so the gap is a screen
// measurement, divided by the scale wherever a frame is worked out in stage units: the two
// agree at every zoom, and a section nobody has dragged keeps its header exactly where the
// layout put it.
const FRAME_PAD = 28
const FRAME_TITLE_GAP = 8
// The same two lengths for a module frame, which sits inside a flow's: less padding, so a
// cluster reads as a division of the frame round it rather than as a frame of its own, and a
// tighter gap under a label that is smaller than a flow's title.
const MODULE_PAD = 12
const MODULE_TITLE_GAP = 4
// The gaps a placement pass leaves: GAP_X between a card and the one it was opened from,
// GAP_Y between a card and whatever it would otherwise have landed on.
const GAP_X = 48
const GAP_Y = 16
// How many pushes a card remembers, newest first, for a shrink to undo.
const PUSH_MEMORY = 32
// Room round the block the cards cover, which the stage claims as its own size: a floor for
// the layers stretched across it and something for the resize observer to see. It is also the
// containing block the nodes are positioned in, which is why a node takes an intrinsic width —
// an automatic one would be cut short by the room left at the node's own position.
const STAGE_PAD = 48

// The edge layer is built as one string of markup, so anything interpolated into an attribute
// is escaped first. A function id is the server's, not a visitor's, but it is still data: a
// module named with a quoted atom can hold a quote, and one quote ends the attribute and puts
// whatever follows it into the markup as though it were mine.
const attr = (value) =>
  String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")

const Canvas = {
  mounted() {
    this.stage = this.el.querySelector("#stage")
    this.svg = this.el.querySelector("#connectors")
    this.zoomLevel = this.el.querySelector("#zoom-level")
    this.view = {x: MARGIN, y: MARGIN, scale: 1}
    this.signatures = false
    // Clusters are drawn until the reader turns them off, which is what the toolbar button
    // renders pressed.
    this.modules = true
    document.body.classList.toggle("grasp-modules", this.modules)
    this.frames = []
    this.lastReveal = null
    this.extent = {width: 0, height: 0}
    // The cards a pass has asked the server to place, each with the box it was given and the
    // pass that asked. A card still unplaced once the answer has had time to arrive was
    // refused, and asking again would be a pass per answer for ever; until then the box stands
    // in for the position the next render will carry, so a card placed a moment later is
    // placed against it rather than on top of it.
    this.attempted = new Map()
    this.passes = 0
    this.pendingReveal = null
    // applyView() redraws whenever the scale differs from the one the frames were drawn at,
    // and the draw that ends mount covers the first frame; seeding the scale keeps that first
    // frame from being drawn twice.
    this.drawnScale = this.view.scale
    // The height of a module's label in screen pixels, one number for every zoom.
    this.labelPx = 0
    // The scale the rule on #stage carries, and whether the heights about to be reported are
    // the same cards measured again rather than cards that grew.
    this.styledScale = this.view.scale
    this.remeasure = false
    this.remeasureFrame = null
    this.style =
      document.getElementById("grasp-canvas-style") ||
      document.head.appendChild(
        Object.assign(document.createElement("style"), {id: "grasp-canvas-style"}),
      )
    this.applyView()

    this.onWheel = (e) => this.wheel(e)
    this.onPointerDown = (e) => this.pointerDown(e)
    this.onPointerMove = (e) => this.pointerMove(e)
    this.onPointerUp = (e) => this.pointerUp(e)
    this.onPointerCancel = (e) => this.pointerCancel(e)
    this.onClickCapture = (e) => this.clickCapture(e)
    this.onDoubleClick = (e) => this.doubleClick(e)
    this.onContextMenu = (e) => this.contextMenu(e)
    this.onKeyDown = (e) => this.spaceDown(e)
    this.onKeyUp = (e) => this.spaceUp(e)
    this.onZoomReset = () => this.resetZoom()
    this.onToggleSignatures = () => this.toggleSignatures()
    this.onToggleModules = () => this.toggleModules()
    this.onZoomFit = () => this.fit()
    this.onSpaceRelease = () => this.releaseSpace()
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerCancel)
    this.el.addEventListener("click", this.onClickCapture, true)
    this.el.addEventListener("dblclick", this.onDoubleClick)
    this.el.addEventListener("contextmenu", this.onContextMenu)
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    window.addEventListener("grasp:zoom-reset", this.onZoomReset)
    window.addEventListener("grasp:toggle-signatures", this.onToggleSignatures)
    window.addEventListener("grasp:toggle-modules", this.onToggleModules)
    window.addEventListener("grasp:zoom-fit", this.onZoomFit)
    // A hold that ends while the page is in the background never delivers its keyup, which
    // would leave the canvas panning on the next press.
    window.addEventListener("blur", this.onSpaceRelease)
    document.addEventListener("visibilitychange", this.onSpaceRelease)

    this.resizeObserver = new ResizeObserver(() => this.draw())
    this.resizeObserver.observe(this.stage)
    // A card grows where it stands — a thread opened or written, a diff turned on, a collapse
    // undone — and what it grows over is pushed down by the growth. The heights are what the
    // next report is measured against; the pushes are kept per grown card, newest last.
    this.cardHeights = new Map()
    this.pushes = new Map()
    this.cardObserver = new ResizeObserver((entries) => this.cardResized(entries))
    this.observeCards()
    // Every session mutation pushes the focus, a move_card included, so revealing on each
    // one would pan away from the card just dropped; only a change of focus is a reveal.
    // A highlight arrives on the card that already has focus, so the card's highlight key
    // is part of what counts as a change — without it the first highlight pans and every
    // later one on the same card does not.
    this.handleEvent("focus", ({id}) => {
      const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || ""
      if (`${id}:${key}` === this.lastReveal) return
      // A card waiting to be placed is drawn at the stage's corner, and the focus on a card
      // just opened arrives before the render that puts it anywhere. Panning to it now would
      // pan to a corner it is about to leave, so the reveal waits for the position and
      // nothing counts as revealed until it happens.
      const node = document.getElementById(`node-${id}`)
      if (!node || node.hasAttribute("data-unplaced")) {
        this.pendingReveal = id
        return
      }
      this.lastReveal = `${id}:${key}`
      this.revealCard(id)
    })
    this.placeCards()
    this.draw()
  },

  updated() {
    // The server has rendered the positions; drop any inline translate left by a drag.
    this.el
      .querySelectorAll(".node[style*='translate']")
      .forEach((node) => (node.style.translate = ""))
    this.observeCards()
    this.placeCards()
    this.draw()
    this.revealPending()
  },

  // The reveal a focus put off because its card had nowhere to be panned to. The render that
  // carries the position is the first moment there is: a card closed before it arrives is a
  // reveal to drop.
  revealPending() {
    const id = this.pendingReveal
    if (id === null) return
    const node = document.getElementById(`node-${id}`)
    if (node && node.hasAttribute("data-unplaced")) return
    this.pendingReveal = null
    if (!node) return
    const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || ""
    this.lastReveal = `${id}:${key}`
    this.revealCard(id)
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.onWheel)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerCancel)
    this.el.removeEventListener("click", this.onClickCapture, true)
    this.el.removeEventListener("dblclick", this.onDoubleClick)
    this.el.removeEventListener("contextmenu", this.onContextMenu)
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("grasp:zoom-reset", this.onZoomReset)
    window.removeEventListener("grasp:toggle-signatures", this.onToggleSignatures)
    window.removeEventListener("grasp:toggle-modules", this.onToggleModules)
    window.removeEventListener("grasp:zoom-fit", this.onZoomFit)
    window.removeEventListener("blur", this.onSpaceRelease)
    document.removeEventListener("visibilitychange", this.onSpaceRelease)
    document.body.classList.remove("grasp-space")
    document.body.classList.remove("grasp-dragging")
    document.body.classList.remove("grasp-signatures")
    document.body.classList.remove("grasp-modules")
    this.resizeObserver.disconnect()
    this.cardObserver.disconnect()
    if (this.remeasureFrame !== null) cancelAnimationFrame(this.remeasureFrame)
    this.style.remove()
  },

  // The translate is rounded to whole screen pixels: a fractional composited offset resamples
  // the rasterised card text and blurs it. this.view stays fractional so small deltas accumulate.
  applyView() {
    const {scale} = this.view
    this.writeStyle()
    // The scale is published as a custom property so a counter-scaled rule can divide by it
    // and hold a label at one size on screen. Those labels take a different box in stage units
    // at every scale, so a frame drawn round them is only right for the scale it was drawn at;
    // a pan leaves every box where it was and needs no redraw.
    if (this.drawnScale !== scale) this.draw()
    if (this.zoomLevel) this.zoomLevel.textContent = `${Math.round(scale * 100)}%`
  },

  // The one rule the hook owns on #stage: the view, the zoom the counter-scaled rules divide
  // by, and the size the stage claims. Every card is positioned absolutely, so the stage has
  // no size of its own and the layers stretched across it — the frames, the edges — would
  // have none either; the extent the last draw measured is what gives them one.
  writeStyle() {
    const {x, y, scale} = this.view
    const {width, height} = this.extent
    // A signature card is sized from --zoom, so its stage-unit height is a different number at
    // every scale; the heights that follow a zoom step are that card measured again.
    if (this.signatures && this.styledScale !== scale) this.markRemeasure()
    this.styledScale = scale
    this.style.textContent =
      `#stage{transform:translate(${Math.round(x)}px,${Math.round(y)}px) scale(${scale});` +
      `--zoom:${scale};min-width:${width}px;min-height:${height}px}`
  },

  // A view or mode change is a re-measure for the frame it lands in: every height reported
  // through that frame is the same cards measured again rather than a card that grew. The
  // observer delivers after the frame's animation-frame callbacks, and one change reaches it
  // in as many deliveries as the card depths it touches, so the flag is dropped from the frame
  // after the one that raised it — past every delivery of the change, and ahead of the first
  // height a growth of the reader's own could report.
  markRemeasure() {
    this.remeasure = true
    if (this.remeasureFrame !== null) cancelAnimationFrame(this.remeasureFrame)
    this.remeasureFrame = requestAnimationFrame(() => {
      this.remeasureFrame = requestAnimationFrame(() => {
        this.remeasureFrame = null
        this.remeasure = false
      })
    })
  },

  // Back to 1:1 about the centre of the canvas, so whatever you were looking at stays put.
  resetZoom() {
    this.zoomBy(1 / this.view.scale)
  },

  // Space is a page-scroll key as well as the pan modifier, and the class it sets lives on
  // <body>, which the server never renders, so a patch mid-gesture cannot drop it.
  spaceDown(e) {
    if (e.key !== " ") return
    if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return
    // Space is how a focused button or link is pressed from the keyboard; taking it there
    // would make the toolbar and the card controls unreachable without a pointer.
    if (e.target.closest?.("button, a")) return
    if (document.getElementById("palette")?.dataset.open === "true") return
    e.preventDefault()
    this.spaceHeld = true
    document.body.classList.add("grasp-space")
  },

  spaceUp(e) {
    if (e.key !== " ") return
    this.releaseSpace()
  },

  // Also the teardown for a hold the page never sees the end of, so it is unconditional: a
  // page coming back to the foreground has no key down, and a held Space re-arms on repeat.
  releaseSpace() {
    this.spaceHeld = false
    document.body.classList.remove("grasp-space")
  },

  // On macOS Ctrl+press is the context-menu gesture, so without this the menu opens over the
  // card the press is dragging, and again on the release that drops it.
  contextMenu(e) {
    if (this.drag?.ctrl || Date.now() - (this.ctrlDragEndedAt || 0) < CTRL_MENU_GRACE) {
      e.preventDefault()
    }
  },

  // A drag ends in a click on whatever was under the pointer, which on a card header is
  // the focus_card binding; that click is the tail of the gesture, not a new one.
  clickCapture(e) {
    if (this.suppressClick) {
      e.stopPropagation()
      e.preventDefault()
      this.suppressClick = false
      return
    }
    // Shift+click a card picks it out instead of focusing it. A control or a call site keeps
    // what it already does, so Shift+clicking a call still opens the callee, and the body is
    // the comment gutter's: Shift there stretches the range being written, and a drag along
    // the line numbers reports its click against the body rather than against either number.
    // The capture phase is where the card's own phx-click has to be taken before it fires.
    const card = e.shiftKey && e.target.closest(".card")
    if (card && !e.target.closest("button, a, input, .call, .also, .card__body")) {
      e.stopPropagation()
      e.preventDefault()
      this.pushEvent("toggle_select", {card: card.id.replace("card-", "")})
      return
    }
    const control = e.target.closest(
      "#zoom-in, #zoom-out, #zoom-fit, #zoom-level, #toggle-signatures, #toggle-modules",
    )
    if (!control) return
    // The zoom buttons and the signature toggle are the hook's alone, so nothing should reach
    // the server. They also give focus back: left holding it, they would swallow the Space
    // that pans the canvas.
    e.stopPropagation()
    e.preventDefault()
    control.blur()
    if (control.id === "zoom-in") this.zoomBy(1.2)
    else if (control.id === "zoom-out") this.zoomBy(1 / 1.2)
    else if (control.id === "zoom-level") this.resetZoom()
    else if (control.id === "toggle-signatures") this.toggleSignatures()
    else if (control.id === "toggle-modules") this.toggleModules()
    else this.fit()
  },

  // Signature mode. The class lives on <body>, which the server never renders, so a patch
  // cannot drop it; the button carries phx-update="ignore" for the same reason, the state it
  // shows being the hook's. Every card changes size with the mode, so every frame and every
  // edge now ends somewhere else, which only a redraw can say.
  toggleSignatures() {
    this.signatures = !this.signatures
    // Every card takes a new height with the mode, which is the reader changing what a card
    // shows rather than any card growing.
    this.markRemeasure()
    document.body.classList.toggle("grasp-signatures", this.signatures)
    const button = document.getElementById("toggle-signatures")
    if (button) button.setAttribute("aria-pressed", String(this.signatures))
    this.draw()
  },

  // The module clusters. The class lives on <body> and the button carries phx-update="ignore"
  // for the reasons signature mode does. A card's header shows its module only while the
  // clusters do not, so every card takes a new width with the mode and the heights reported
  // through the frame are the same cards measured again rather than cards that grew.
  toggleModules() {
    this.modules = !this.modules
    this.markRemeasure()
    document.body.classList.toggle("grasp-modules", this.modules)
    const button = document.getElementById("toggle-modules")
    if (button) button.setAttribute("aria-pressed", String(this.modules))
    this.draw()
  },

  wheel(e) {
    // The toolbar floats over the canvas; a wheel there is aimed at the toolbar, and panning
    // the ground out from under it would make the buttons hard to hit.
    if (e.target.closest?.(".toolbar")) return
    // A zoom modifier means the canvas, whatever is under the cursor.
    if (!e.ctrlKey && !e.metaKey && this.scrollableUnder(e)) return
    e.preventDefault()
    if (e.ctrlKey || e.metaKey) {
      this.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY)
    } else {
      this.view.x -= e.deltaX
      this.view.y -= e.deltaY
      this.applyView()
    }
  },

  // Anything between the cursor and the canvas that can absorb this wheel gesture itself —
  // a code body scrolled sideways, the callers dropdown scrolled down — keeps it, because
  // panning the whole canvas instead would leave that content unreachable. An element that
  // has run out of scroll in this direction absorbs nothing, so the canvas pans instead of
  // the gesture dying against the end of a list.
  scrollableUnder(e) {
    const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY)
    let el = e.target instanceof Element ? e.target : null
    while (el && el !== this.el) {
      const style = getComputedStyle(el)
      const overflow = horizontal ? style.overflowX : style.overflowY
      const scrollable = overflow === "auto" || overflow === "scroll"
      if (scrollable && this.canScroll(el, style, horizontal, e)) return true
      el = el.parentElement
    }
    return false
  },

  // A classic scrollbar on the other axis takes space out of the client box without taking
  // it out of the scroll box, so an element that only ever scrolls sideways still reports a
  // scrollHeight one scrollbar taller than its clientHeight. Measuring that gutter and
  // discounting it is what keeps a vertical wheel over a wide code body panning the canvas
  // rather than crawling through 15px of phantom overflow.
  canScroll(el, style, horizontal, e) {
    if (horizontal) {
      const gutter = Math.max(
        0,
        el.offsetWidth -
          el.clientWidth -
          parseFloat(style.borderLeftWidth) -
          parseFloat(style.borderRightWidth),
      )
      return e.deltaX > 0
        ? el.scrollLeft + el.clientWidth < el.scrollWidth - gutter
        : el.scrollLeft > 0
    }
    const gutter = Math.max(
      0,
      el.offsetHeight -
        el.clientHeight -
        parseFloat(style.borderTopWidth) -
        parseFloat(style.borderBottomWidth),
    )
    return e.deltaY > 0
      ? el.scrollTop + el.clientHeight < el.scrollHeight - gutter
      : el.scrollTop > 0
  },

  zoomBy(factor) {
    const r = this.el.getBoundingClientRect()
    this.zoomAt(factor, r.left + r.width / 2, r.top + r.height / 2)
  },

  zoomAt(factor, clientX, clientY) {
    const r = this.el.getBoundingClientRect()
    const px = clientX - r.left
    const py = clientY - r.top
    const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.view.scale * factor))
    const k = next / this.view.scale
    this.view = {x: px - (px - this.view.x) * k, y: py - (py - this.view.y) * k, scale: next}
    this.applyView()
  },

  // Brings every card on the canvas into view.
  fit() {
    // A frame's header holds one size on screen, so it is ~30 / scale tall in stage units and
    // the block a fit measures changes shape at the scale that fit applies: the first pass
    // re-lays-out the very boxes it measured. The second pass measures the layout the first
    // one produced and corrects it.
    this.fitPass()
    this.fitPass()
  },

  // One fit against the layout as it stands.
  fitPass() {
    // The frames are measured alongside the cards: a fit that showed only the cards would cut
    // the padding and the header off the sections holding them. A card with no position yet
    // sits at the origin and says nothing about where the canvas is.
    const boxes = Array.from(
      this.el.querySelectorAll(".node:not([data-unplaced]) .card, .frame"),
    )
    if (boxes.length === 0) return
    const box = this.stageBox(boxes)
    if (!(box.width > 0) || !(box.height > 0)) return
    const r = this.el.getBoundingClientRect()
    const scale = Math.min(
      MAX_SCALE,
      Math.max(
        MIN_SCALE,
        Math.min((r.width - 2 * MARGIN) / box.width, (r.height - 2 * MARGIN) / box.height, 1),
      ),
    )
    this.view = {x: MARGIN - box.left * scale, y: MARGIN - box.top * scale, scale}
    this.applyView()
  },

  // Bounding box of elements in unscaled stage coordinates.
  stageBox(elements) {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    let left = Infinity,
      top = Infinity,
      right = -Infinity,
      bottom = -Infinity
    for (const el of elements) {
      const b = el.getBoundingClientRect()
      left = Math.min(left, (b.left - s.left) / scale)
      top = Math.min(top, (b.top - s.top) / scale)
      right = Math.max(right, (b.right - s.left) / scale)
      bottom = Math.max(bottom, (b.bottom - s.top) / scale)
    }
    return {left, top, right, bottom, width: right - left, height: bottom - top}
  },

  // A double click on an edge travels along it: of the two cards the edge joins, the one
  // further from the pointer is the one out of sight, so that is the card brought into view
  // and given focus. Near either end the gesture is a way to jump to the other.
  doubleClick(e) {
    const edge = e.target.closest?.(".edge")
    if (!edge) return
    const ends = [edge.dataset.from, edge.dataset.to]
      .map((id) => ({id, card: document.getElementById(`card-${id}`)}))
      .filter(({card}) => card)
    if (ends.length === 0) return
    const distance = ({card}) => {
      const b = card.getBoundingClientRect()
      return Math.hypot(b.left + b.width / 2 - e.clientX, b.top + b.height / 2 - e.clientY)
    }
    const far = ends.reduce((a, b) => (distance(b) > distance(a) ? b : a))
    e.preventDefault()
    this.pushEvent("focus_card", {card: far.id})
    this.revealCard(far.id)
  },

  revealCard(id) {
    if (id == null) return
    // A focus arriving mid-gesture would pan the ground out from under the pointer.
    if (this.drag) return
    const card = document.getElementById(`card-${id}`)
    if (!card) return
    // A card carrying a highlight is revealed at what it points at, which on a long body
    // is nowhere near the card's own top-left corner. Far out the body is not displayed and
    // the marked span has no box at all; a rect of zeros reads as the viewport's own corner
    // and would pan the canvas away from the card rather than onto it.
    const marked = card.querySelector('[data-highlight="true"]')
    const markedBox = marked && marked.getBoundingClientRect()
    const target = markedBox && (markedBox.width || markedBox.height) ? marked : card
    const r = this.el.getBoundingClientRect()
    const b = target.getBoundingClientRect()
    let dx = 0,
      dy = 0
    // Pulling a wide card's right edge into view must never push its left edge out, so the
    // correction that reveals the end of a card is clamped by the one that reveals its start.
    if (b.left < r.left) dx = r.left - b.left + MARGIN
    else if (b.right > r.right) dx = Math.max(r.right - b.right - MARGIN, r.left - b.left + MARGIN)
    if (b.top < r.top) dy = r.top - b.top + MARGIN
    else if (b.bottom > r.bottom) dy = Math.max(r.bottom - b.bottom - MARGIN, r.top - b.top + MARGIN)
    if (dx || dy) {
      this.view.x += dx
      this.view.y += dy
      this.applyView()
    }
  },

  pointerDown(e) {
    if (e.button !== 0) return
    // A previous gesture that ended outside the canvas never got its trailing click, and a
    // stale suppression would eat this one.
    this.suppressClick = false
    if (this.spaceHeld) return this.beginPan(e)
    // A Shift+press on a card is the start of a selection click, not of a drag: without the
    // preventDefault the browser begins a text range that smears over every card the pointer
    // crosses on the way to the next one.
    if (e.shiftKey && e.target.closest(".card")) return e.preventDefault()
    // Alt is the handle for a whole flow: a press anywhere on a card drags every card
    // connected to it, so one flow can be moved clear of another. It takes precedence over
    // Ctrl and over the header rule, both of which carry the one card. A link is left to the
    // browser, whose Alt+click downloads it.
    const altCard = e.altKey && e.target.closest(".card")
    if (altCard && !e.target.closest("a")) return this.beginGraphDrag(e, altCard)
    // A module's label is the handle for the cards of that cluster, the way a frame's header
    // is for a group's. It carries no controls to press, and a press that never moves does
    // nothing: the label names the cluster and there is nothing else to open from it.
    const label = e.target.closest(".module__title")
    if (label) return this.beginModuleDrag(e, label)
    // A frame's header is the handle the whole group is dragged by, with or without Ctrl, the
    // way a card's header is the card's: a press that moves drags every card in the group, and
    // one that does not move is the click that renames the title. The header's own controls
    // are pressed rather than dragged from.
    const title = e.target.closest(".flow__title")
    if (title && !e.target.closest("button, a, input")) {
      return this.beginGroupDrag(e, title, e.ctrlKey)
    }
    const ctrlCard = e.ctrlKey && e.target.closest(".card")
    if (ctrlCard) return this.beginCardDrag(e, ctrlCard, true)
    const header = e.target.closest(".card__header")
    // The header's own controls — the callers toggle, the file link, close — are pressed
    // rather than dragged from, and the preventDefault a drag begins with would take the
    // focus away from them.
    if (header && !e.target.closest("button, a, input")) {
      this.beginCardDrag(e, header.closest(".card"), false)
    } else if (!e.target.closest(".card, .toolbar, .chat, button, a, input")) {
      this.beginPan(e)
    }
  },

  // Without the preventDefault the gesture also starts a native text selection, which then
  // smears across every card the pointer crosses.
  beginCardDrag(e, card, ctrl) {
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    const node = card.closest(".node")
    // Where the card is now: the position the server rendered plus a displacement it has yet
    // to answer for. A second drag that started from the rendered position alone would push
    // the first one's move away again.
    const position = this.positionOf(node)
    const carried = this.translateOf(node)
    const x = Math.round(position.x + carried.x)
    const y = Math.round(position.y + carried.y)
    this.drag = {
      kind: "card",
      ctrl,
      pointerId: e.pointerId,
      node,
      id: card.id.replace("card-", ""),
      startX: e.clientX,
      startY: e.clientY,
      x,
      y,
      moved: false,
    }
  },

  // Where the server last put a node, in stage pixels from the stage's corner: the node's own
  // custom properties are the position, and the rule in app.css reads them as its left and top.
  // A node with neither is at the origin, which is where an unplaced card is rendered.
  positionOf(node) {
    return {
      x: parseInt(node.style.getPropertyValue("--x"), 10) || 0,
      y: parseInt(node.style.getPropertyValue("--y"), 10) || 0,
    }
  },

  // Every card of the group travels by the same displacement, so the cards keep their places
  // relative to one another and the frame the hook draws round them follows from their boxes.
  beginGroupDrag(e, title, ctrl) {
    const flow = title.closest(".flow")
    if (!flow) return
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "group",
      ctrl,
      pointerId: e.pointerId,
      group: Number(flow.dataset.group),
      nodes: this.nodesOfGroup(flow.dataset.group),
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
    }
  },

  // The cards of a group are anywhere on the stage, so its members are the nodes that name it
  // rather than a section's own subtree, which holds the header and nothing else.
  nodesOfGroup(group) {
    return [...this.el.querySelectorAll(".node")].filter((node) => node.dataset.group === group)
  },

  // Every card of one cluster travels by the same displacement, the way a group's do. A press
  // that gathers nothing begins no drag: the label is drawn from the cards, so a cluster with
  // none is a label nothing is left under.
  beginModuleDrag(e, label) {
    const nodes = this.nodesOfModule(label.dataset.group, label.dataset.module)
    if (!nodes.length) return
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "module",
      ctrl: false,
      pointerId: e.pointerId,
      nodes,
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
    }
  },

  // The cards of one cluster: a module is clustered per flow, so both the group and the module
  // have to match. A card still waiting for a position has none for a displacement to be added
  // to, and the frame is not drawn round it either.
  nodesOfModule(group, module) {
    return [...this.el.querySelectorAll(".node:not([data-unplaced])")].filter(
      (node) => node.dataset.group === group && node.dataset.module === module,
    )
  },

  // Every card connected to the pressed one travels by the same displacement, so a flow keeps
  // its shape while it moves away from the rest. The component is read once, at press time:
  // the cards of a flow do not change while it is being dragged, and rereading it on every
  // move would walk the canvas's call sites hundreds of times over a gesture. A press that
  // gathers nothing is no gesture at all — a card with no position cannot be shifted, so
  // pressing one begins no drag rather than a dead one the release would report.
  beginGraphDrag(e, card) {
    const node = card.closest(".node")
    if (!node) return
    const nodes = this.connectedNodes(node)
    if (!nodes.length) return
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "graph",
      ctrl: false,
      pointerId: e.pointerId,
      nodes,
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
    }
  },

  // The nodes reachable from `node` over the edges the canvas draws, the pressed one first.
  // Connection is undirected — a reader shifting a flow means the calls into it as much as the
  // calls out of it — and the edges are the call sites themselves, `[data-edge-to]` naming the
  // card each one points at, so what the gesture carries is what the reader can see joined up.
  // A card still waiting for a position is dropped: it is drawn at the origin and has no
  // position for a displacement to be added to.
  connectedNodes(node) {
    const nodes = new Map()
    for (const candidate of this.el.querySelectorAll(".node")) {
      nodes.set(candidate.dataset.card, candidate)
    }
    const neighbours = new Map()
    const join = (from, to) => {
      if (!neighbours.has(from)) neighbours.set(from, new Set())
      neighbours.get(from).add(to)
    }
    for (const site of this.el.querySelectorAll("[data-edge-to]")) {
      const from = site.closest(".node")?.dataset.card
      const to = site.dataset.edgeTo
      // A collapsed callee leaves its call site on the canvas with nothing at the far end.
      if (!from || !to || !nodes.has(to)) continue
      join(from, to)
      join(to, from)
    }
    const found = [node.dataset.card]
    const seen = new Set(found)
    for (let i = 0; i < found.length; i++) {
      for (const next of neighbours.get(found[i]) || []) {
        if (seen.has(next)) continue
        seen.add(next)
        found.push(next)
      }
    }
    return found
      .map((id) => nodes.get(id))
      .filter((el) => el && !el.hasAttribute("data-unplaced"))
  },

  // Whether a card is still waiting for the position the hook is about to give it.
  unplaced(card) {
    return card.closest(".node")?.hasAttribute("data-unplaced") === true
  },

  // The group a node belongs to, or null for a node in none. The attribute is always there and
  // empty for a card in no group, which is not group 0.
  groupOf(node) {
    const group = node.dataset.group
    return group === "" || group === undefined ? null : Number(group)
  },

  beginPan(e) {
    e.preventDefault()
    document.body.classList.add("grasp-dragging")
    this.drag = {
      kind: "pan",
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      x: this.view.x,
      y: this.view.y,
      moved: false,
    }
  },

  // The nodes a drag carries: a card drag its one node, a group drag every node of the group, a
  // graph drag every node connected to the pressed one, a module drag every card of the cluster,
  // and a pan none. The translate a drag writes is the displacement alone — a node's position is
  // already its left and top — so every node of a gesture carries the same one.
  dragNodes(drag) {
    if (drag.kind === "card") return [drag.node]
    if (drag.kind === "group" || drag.kind === "graph" || drag.kind === "module") return drag.nodes
    return []
  },

  // A second pointer — a touch, a pen, the other half of a pinch — reports its own stream of
  // moves and releases; only the one that started the gesture may drive or end it.
  otherPointer(e) {
    return !this.drag || (e.pointerId !== undefined && e.pointerId !== this.drag.pointerId)
  },

  pointerMove(e) {
    if (this.otherPointer(e)) return
    // The button came up while the pointer was outside the window, so the pointerup that
    // would have ended this gesture was never delivered; this move is the first news of it.
    if (e.buttons === 0) return this.pointerUp(e)
    const mx = e.clientX - this.drag.startX
    const my = e.clientY - this.drag.startY
    if (!this.drag.moved && Math.hypot(mx, my) < DRAG_THRESHOLD) return
    this.drag.moved = true
    if (this.drag.kind === "pan") {
      this.view.x = this.drag.x + mx
      this.view.y = this.drag.y + my
      this.applyView()
    } else {
      // The displacement is rounded to whole stage pixels, which is the unit a position is
      // stored in: the card travels through exactly the positions it can be dropped on, so
      // what the drag shows is what the release pushes. The card keeps whatever subpixel
      // phase its layout gave it — it is not on a grid.
      const s = this.view.scale
      const tx = Math.round(mx / s)
      const ty = Math.round(my / s)
      for (const node of this.dragNodes(this.drag)) {
        node.style.translate = `${tx}px ${ty}px`
      }
      this.draw()
    }
  },

  endDrag() {
    const drag = this.drag
    this.drag = null
    document.body.classList.remove("grasp-dragging")
    if (drag?.moved) this.suppressClick = true
    // A ctrl-press that never moved was a right-click, not a drag; blocking the menu it is
    // about to open would take the context menu away from the card entirely.
    if (drag?.ctrl && drag.moved) this.ctrlDragEndedAt = Date.now()
    return drag
  },

  // The browser took the pointer for a gesture of its own, so the drag is abandoned rather
  // than completed: nothing is pushed, the card goes back to the position the server last
  // rendered, and no click follows a cancel for the suppression to be waiting for.
  pointerCancel(e) {
    if (this.otherPointer(e)) return
    const drag = this.endDrag()
    this.suppressClick = false
    const nodes = this.dragNodes(drag)
    if (nodes.length) {
      nodes.forEach((node) => (node.style.translate = ""))
      this.draw()
    }
  },

  pointerUp(e) {
    if (this.otherPointer(e)) return
    const drag = this.endDrag()
    if (!drag.moved) return
    if (drag.kind === "card") {
      const {scale} = this.view
      const dx = Math.round((e.clientX - drag.startX) / scale)
      const dy = Math.round((e.clientY - drag.startY) / scale)
      // Dropping on the position the card already had produces no diff and so no updated()
      // to clear the fractional translate the drag left behind.
      drag.node.style.translate = `${dx}px ${dy}px`
      const group = this.groupUnder(e, drag)
      // The position is where the card came from plus where it was taken, in whole stage
      // pixels: the server reads integers and drops a move whose coordinates it cannot.
      const move = {card: drag.id, x: drag.x + dx, y: drag.y + dy}
      this.pushEvent("move_card", group === null ? move : {...move, group})
    } else if (drag.kind === "group") {
      const {scale} = this.view
      const dx = Math.round((e.clientX - drag.startX) / scale)
      const dy = Math.round((e.clientY - drag.startY) / scale)
      // Each node is left on the whole-pixel displacement the server is about to render as a
      // position, so a group put back where it already sat produces no diff to clear the
      // drag's fractional translate and needs none. A group drag decides no membership: the
      // cards move together and stay in the group they are the members of.
      for (const node of drag.nodes) {
        node.style.translate = `${dx}px ${dy}px`
      }
      this.pushEvent("move_group", {group: drag.group, dx, dy})
    } else if (drag.kind === "graph" || drag.kind === "module") {
      const {scale} = this.view
      const dx = Math.round((e.clientX - drag.startX) / scale)
      const dy = Math.round((e.clientY - drag.startY) / scale)
      // Each node is left on the whole-pixel displacement the server is about to render as a
      // position, so a flow put back where it already sat produces no diff to clear the drag's
      // fractional translate and needs none. Neither gesture decides membership: the cards
      // travel together, each stays in the group it is a member of, and a card cannot leave
      // the module its function belongs to.
      for (const node of drag.nodes) {
        node.style.translate = `${dx}px ${dy}px`
      }
      this.pushEvent("move_cards", {
        cards: drag.nodes.map((node) => Number(node.dataset.card)),
        dx,
        dy,
      })
    }
  },

  // The group whose frame a drop landed in, or null when it landed anywhere else — the
  // ungrouped section, the bare canvas, or the card's own frame, none of which is a change of
  // membership. The frames are rectangles the hook drew itself, so the drop is decided by area
  // alone: a pointer anywhere inside one, padding included, joins that group, whatever element
  // happens to lie under it. A pointer inside two overlapping frames takes the later one, which
  // is the one drawn on top.
  groupUnder(e, drag) {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const x = (e.clientX - s.left) / scale
    const y = (e.clientY - s.top) / scale
    // null for a card in no group, which is equal to no group id, so such a card has no frame
    // of its own to be skipped.
    const own = this.groupOf(drag.node)
    let group = null
    for (const f of this.frames) {
      if (f.group === own) continue
      if (x >= f.left && x <= f.right && y >= f.top && y <= f.bottom) group = f.group
    }
    return group
  },

  // Frames first: they are measured from the cards, and drawing both from one read of the
  // layout keeps a dragged card's frame and its edges in step through the gesture. The scale
  // is recorded only when there is a layer to draw the frames into, so a draw that finds none
  // leaves the next applyView() to redraw.
  draw() {
    this.measureExtent()
    if (this.drawFrames()) this.drawnScale = this.view.scale
    this.drawConnectors()
  },

  // The block the placed cards cover, which the stage claims as its size and the edge layer is
  // cut to. A card with no position yet is rendered at the origin, so it is left out: it would
  // stretch the stage to a corner nothing is at. Only the far edges are measured — a card at a
  // negative coordinate lies outside the stage's own box, which clips nothing and is only ever
  // panned to.
  //
  // The node's rectangle is the card's: a node has no padding, border or margin and takes the
  // card's intrinsic width, so the extent here, the frames drawn from the cards and the boxes
  // a placement is decided against are all the same rectangles.
  measureExtent() {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    let right = 0,
      bottom = 0
    for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
      const b = node.getBoundingClientRect()
      if (!b.width && !b.height) continue
      right = Math.max(right, (b.right - s.left) / scale)
      bottom = Math.max(bottom, (b.bottom - s.top) / scale)
    }
    const width = Math.ceil(right + STAGE_PAD)
    const height = Math.ceil(bottom + STAGE_PAD)
    // Every pointermove of a drag draws; rewriting the rule each time would have the browser
    // re-parse the stylesheet for a size that has not changed.
    if (width === this.extent.width && height === this.extent.height) return
    this.extent = {width, height}
    this.writeStyle()
  },

  // One rectangle per grouped section, round the cards wherever they have been dragged to,
  // with the section's header moved to sit above its top-left corner, and inside it one
  // rectangle per module, round the cards of that module with the module's name over them.
  // The rectangles kept in this.frames are the sections' alone, which is what a drop is tested
  // against: a module frame changes no membership. Answers whether it drew.
  drawFrames() {
    if (!this.framesLayer()) return false
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const titleGap = FRAME_TITLE_GAP / scale
    this.frames = []
    const divs = []
    // A group's cards are anywhere on the stage — a section's own subtree holds its header and
    // nothing else — so the extent of each one is gathered from the nodes that name it. A card
    // with no position yet is rendered at the origin and would drag the frame there.
    //
    // The cards are gathered per cluster — the module a card names inside the group it names,
    // which is what a module frame is drawn round — and a section's extent is the union of its
    // clusters. Until the clusters are drawn that union is the union of the cards themselves.
    const cards = []
    for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
      const card = node.querySelector(".card")
      // A card the browser gives no box — inside a subtree that is not displayed — says
      // nothing about where the frame round it goes.
      const b = card && card.getBoundingClientRect()
      if (!b || (!b.width && !b.height)) continue
      cards.push({
        group: node.dataset.group || "",
        module: node.dataset.module || "",
        left: (b.left - s.left) / scale,
        top: (b.top - s.top) / scale,
        right: (b.right - s.left) / scale,
        bottom: (b.bottom - s.top) / scale,
      })
    }
    // Every label is one line of one counter-scaled rule, so one height answers for the lot.
    const labelHeight = this.modules ? this.moduleLabelPx() / scale : null
    const {moduleFrames, extents} = clusterFrames(cards, labelHeight, MODULE_TITLE_GAP / scale)
    // Every box is read before the first header is moved. Writing `translate` invalidates the
    // layout, so a loop that measured one section and then moved its header would force a
    // reflow per section on every pointermove of a drag.
    const sections = []
    for (const flow of this.el.querySelectorAll(".flow[data-grouped]")) {
      const title = flow.querySelector(".flow__title")
      const {left, top, right, bottom} = extents.get(flow.dataset.group) || {
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity,
      }
      sections.push({
        group: Number(flow.dataset.group),
        title,
        titleBox: title && title.getBoundingClientRect(),
        // The offset the header is already carrying, which its box is measured with.
        carried: title && this.translateOf(title),
        left,
        top,
        right,
        bottom,
      })
    }

    for (const {group, title, titleBox, carried, left, top, right, bottom} of sections) {
      // A section with nothing measurable in it has no frame, and its header goes back to
      // wherever the layout puts it.
      if (left === Infinity) {
        if (title) title.style.translate = ""
        continue
      }
      const headerHeight = title ? titleBox.height / scale : null
      if (title) {
        // Where the header would sit untranslated: its own box less the offset it is carrying.
        const naturalLeft = (titleBox.left - s.left) / scale - carried.x
        const naturalTop = (titleBox.top - s.top) / scale - carried.y
        const x = left - naturalLeft
        const y = top - (headerHeight + titleGap) - naturalTop
        title.style.translate = `${x}px ${y}px`
      }
      const frame = {
        group,
        ...frameAround({left, top, right, bottom}, headerHeight, titleGap, FRAME_PAD),
      }
      this.frames.push(frame)
      divs.push(
        `<div class="frame" data-group="${attr(frame.group)}" style="left:${frame.left}px;top:${frame.top}px;` +
          `width:${frame.right - frame.left}px;height:${frame.bottom - frame.top}px"></div>`,
      )
    }
    // The module frames come after the sections' in the layer, so a cluster is drawn over the
    // ground of the frame it stands in rather than under it. Its label sits at the frame's
    // top-left inside the padding, which is where the head the frame leaves above the cards
    // begins, and carries the cluster it names so that a drag on it finds the cards.
    for (const frame of moduleFrames) {
      divs.push(
        `<div class="frame frame--module" style="left:${frame.left}px;` +
          `top:${frame.top}px;width:${frame.right - frame.left}px;height:${frame.bottom - frame.top}px"></div>`,
        `<div class="module__title" data-group="${attr(frame.group)}" data-module="${attr(frame.module)}" ` +
          `style="left:${frame.left + MODULE_PAD}px;top:${frame.top + MODULE_PAD}px">${attr(frame.module)}</div>`,
      )
    }
    this.frameLayer.innerHTML = divs.join("")
    return true
  },

  // The layer the frames and their labels are written into. It lives in a phx-update="ignore"
  // subtree and so normally outlives every patch; were one ever to replace it, a cached node
  // would go on collecting frames nothing renders.
  framesLayer() {
    if (!this.frameLayer?.isConnected) this.frameLayer = this.el.querySelector("#frames")
    return this.frameLayer
  },

  // The height of a module's label in screen pixels. The label is counter-scaled, so it measures
  // the same on screen at every zoom and one reading answers for all of them; a caller working
  // in stage units divides by the scale it works at. A read that finds no label measures a
  // hidden one of its own, the labels a draw is about to write not being in the document yet.
  moduleLabelPx() {
    if (this.labelPx) return this.labelPx
    const layer = this.framesLayer()
    if (!layer) return 0
    let label = layer.querySelector(".module__title")
    let probe = null
    if (!label) {
      probe = document.createElement("div")
      probe.className = "module__title"
      probe.style.visibility = "hidden"
      probe.textContent = "M"
      label = layer.appendChild(probe)
    }
    const height = label.getBoundingClientRect().height
    if (probe) probe.remove()
    // A layer the browser gives no box has nothing to say about a label's height, and a zero
    // is not an answer to keep.
    if (!height) return 0
    this.labelPx = height
    return height
  },

  // The height of a group's header, or null for a group whose section carries none — the two
  // cases `frameAround` reads. A card in no group has no section and no header, and the empty
  // group id names none. The caller says what scale to read the height at, since the scale a
  // measurement belongs to is the caller's business: `scale` 1 answers in screen pixels, which
  // is what the header measures at every zoom because the header is counter-scaled.
  headerHeightOf(group, scale) {
    if (!group) return null
    const flow = `.flow[data-grouped][data-group="${CSS.escape(group)}"]`
    const title = this.el.querySelector(`${flow} .flow__title`)
    if (!title) return null
    return title.getBoundingClientRect().height / scale
  },

  // The offset the hook last gave an element, in stage units. A property with one value is an
  // x with no y, as the CSS `translate` shorthand defines it, and an empty one is no offset.
  translateOf(el) {
    const [x, y] = (el.style.translate || "").split(" ").filter((v) => v !== "")
    return {x: parseFloat(x) || 0, y: parseFloat(y) || 0}
  },

  // One path per caller and callee: every open call site names the callee's card in
  // `[data-edge-to]` and its palette slot in `data-color`, and a card that calls the same
  // function from several places is still joined to its card once, in the colour of the first
  // of those calls, so the line and the calls it stands for agree without the hook knowing
  // what the colours are. The path leaves the caller's card rather than the call itself: a
  // card with a dozen open calls has a dozen coloured calls in its body and one line to each
  // card they reach, not a fan of lines across its own code.
  drawConnectors() {
    // The group lives in a phx-update="ignore" subtree and so normally outlives every patch;
    // were one ever to replace it, a cached node would go on collecting paths nothing renders.
    if (!this.edges?.isConnected) this.edges = this.svg?.querySelector("#edges")
    if (!this.edges) return
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    // A card holds many call sites and a callee is often called twice, so measuring per edge
    // would read the same box over and over on every pointermove of a drag.
    const boxes = new Map()
    const boxOf = (el) => {
      let box = boxes.get(el)
      if (!box) boxes.set(el, (box = el.getBoundingClientRect()))
      return box
    }
    const within = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
    const drawn = new Set()
    const paths = []
    for (const site of this.el.querySelectorAll("[data-edge-to]")) {
      const card = site.closest(".card")
      if (!card) continue
      const from = card.id.replace("card-", "")
      const to = site.dataset.edgeTo
      const pair = `${from}|${to}`
      if (drawn.has(pair)) continue
      const callee = document.getElementById(`card-${to}`)
      // A collapse takes the callee off the canvas without touching the call site's own
      // markup, so an edge is as likely to be hanging as attached.
      if (!callee) continue
      // A card waiting to be placed is drawn at the origin and not shown; an edge to or from
      // it would be a line to a corner nothing is at.
      if (this.unplaced(card) || this.unplaced(callee)) continue
      const b = boxOf(callee)
      if (!b.width && !b.height) continue
      drawn.add(pair)

      const c = boxOf(card)
      const callerLeft = (c.left - s.left) / scale
      const callerRight = (c.right - s.left) / scale
      const callerTop = (c.top - s.top) / scale
      const callerBottom = (c.bottom - s.top) / scale
      const calleeLeft = (b.left - s.left) / scale
      const calleeRight = (b.right - s.left) / scale
      const calleeTop = (b.top - s.top) / scale
      const calleeBottom = (b.bottom - s.top) / scale
      // An edge leaves towards the callee and arrives on the side it comes from, so a card
      // opened to the left of its caller is joined round the outside rather than through it.
      const rightward = calleeLeft > callerRight
      const leftward = calleeRight < callerLeft
      // A callee that shares the caller's columns has no free side to arrive at: a line drawn
      // to its left or right port would cross the card and end on it. Such a callee is joined
      // through the edges that face one another, above or below, at the point of each nearest
      // the other card's middle, kept off the corners by the port offset — or by half the card
      // when a signature-mode card is narrower than two of them.
      const below = !rightward && !leftward && calleeTop >= callerBottom
      const above = !rightward && !leftward && calleeBottom <= callerTop
      let d
      if (below || above) {
        const callerInset = Math.min(PORT_Y, (callerRight - callerLeft) / 2)
        const calleeInset = Math.min(PORT_Y, (calleeRight - calleeLeft) / 2)
        const x1 = within(
          (calleeLeft + calleeRight) / 2,
          callerLeft + callerInset,
          callerRight - callerInset,
        )
        const y1 = below ? callerBottom : callerTop
        const x2 = within(x1, calleeLeft + calleeInset, calleeRight - calleeInset)
        const y2 = below ? calleeTop : calleeBottom
        const mid = (y1 + y2) / 2
        d = `M ${x1} ${y1} C ${x1} ${mid}, ${x2} ${mid}, ${x2} ${y2}`
      } else {
        const x1 = rightward ? callerRight : callerLeft
        const y1 = callerTop + PORT_Y
        const x2 = rightward ? calleeLeft : calleeRight
        const y2 = calleeTop + PORT_Y
        const mid = (x1 + x2) / 2
        d = `M ${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2} ${y2}`
      }
      const color = /^[0-7]$/.test(site.dataset.color || "") ? site.dataset.color : null
      // The call site says what kind of hop it is; the path carries it so the stylesheet can
      // draw a hop that is not a plain function call — an HTTP request, a queued job —
      // differently from one that is.
      const kind = site.dataset.kind
      // The path is drawn in stage units, which the zoom scales; `vector-effect` is what keeps
      // its stroke 2 screen pixels instead of thinning to under half a one at MIN_SCALE.
      paths.push(
        `<path class="edge" vector-effect="non-scaling-stroke" data-from="${attr(from)}" data-to="${attr(to)}"` +
          (color === null ? "" : ` data-color="${color}" marker-end="url(#arrow-${color})"`) +
          (kind ? ` data-kind="${attr(kind)}"` : "") +
          ` d="${d}" />`,
      )
    }
    // The stage has no in-flow content to measure, so the layer is cut to the block the cards
    // cover. A path outside it is still drawn: the layer's overflow is visible, which is what
    // carries an edge to a card at a negative coordinate.
    this.svg.setAttribute("width", String(this.extent.width))
    this.svg.setAttribute("height", String(this.extent.height))
    this.edges.innerHTML = paths.join("")
  },

  // Every card the server has no position for, placed beside the card it was opened from and
  // pushed in one go. The pass measures, decides and pushes; it moves nothing, because the
  // render that answers carries the positions and drops `data-unplaced` with them.
  //
  // A card is placed against the boxes of the cards that already have a place, its own
  // included as soon as it has one, and against the frames round the other sections, so a pass
  // that lays out a whole canvas — the one after `reset_layout`, where nothing is placed —
  // reads like the one that places a single new card: taken section by section in depth order,
  // a caller is down before the callee that hangs off it, and each section is a band below the
  // ones already laid out.
  placeCards() {
    this.passes++
    // A card the server has answered about is a card to forget; what stays behind is a card
    // whose answer is still on the wire, or one the server refused — and a pass that asked
    // again on every patch would never stop.
    for (const [id] of this.attempted) {
      const node = document.getElementById(`node-${id}`)
      if (!node || !node.hasAttribute("data-unplaced")) this.attempted.delete(id)
    }
    const waiting = [...this.el.querySelectorAll(".node[data-unplaced]")]
    if (waiting.length === 0) return
    const unplaced = waiting.filter((node) => !this.attempted.has(node.dataset.card))
    // A patch of the server's own arrives while a placement is still travelling, so the pass
    // straight after the push says nothing about whether the card was taken. A pass later than
    // that one and the answer has been and gone without the position, which is a refusal:
    // said once for the card, which stays where an unplaced card is drawn.
    for (const node of waiting) {
      const asked = this.attempted.get(node.dataset.card)
      if (!asked || asked.warned || this.passes - asked.pass < 2) continue
      asked.warned = true
      console.warn(
        `grasp: the canvas placed card ${node.dataset.card} and the session did not take it; ` +
          "the card stays hidden at the stage's corner",
      )
    }
    if (unplaced.length === 0) return

    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    // Every box is read before the first placement is decided, and each node's own rectangle
    // is kept: a call site inside a card is measured where the card is standing, and the
    // distance from the card's top is what survives the card being placed somewhere else.
    const nodes = [...this.el.querySelectorAll(".node")]
    const measured = new Map()
    for (const node of nodes) {
      const b = node.getBoundingClientRect()
      measured.set(node, {
        top: (b.top - s.top) / scale,
        width: b.width / scale,
        height: b.height / scale,
      })
    }
    // Where each card stands: the position the server rendered, or the one an earlier pass
    // asked for and is still waiting to see. A card is placed against both, so two cards
    // opened inside one round trip do not land on each other.
    //
    // A node's position is its box because `.node` has no margin and no border, and `#nodes`
    // is the one in-flow child of `#stage`, at the stage's own corner: a node's --x/--y and
    // the rectangle it is measured at are the same coordinates.
    const boxes = new Map()
    const occupied = []
    for (const node of nodes) {
      const m = measured.get(node)
      const asked = this.attempted.get(node.dataset.card)
      let box
      if (!node.hasAttribute("data-unplaced")) {
        const {x, y} = this.positionOf(node)
        box = {left: x, top: y, right: x + m.width, bottom: y + m.height, node}
      } else if (asked) {
        box = {...asked.box, node}
      } else {
        continue
      }
      boxes.set(node, box)
      occupied.push(box)
    }
    // One read of the call sites for the whole pass: a card's opener is the first card in
    // document order with a call site naming it, and a card opened as a caller is one holding
    // a call site that names a card already standing somewhere.
    const sites = []
    for (const site of this.el.querySelectorAll("[data-edge-to]")) {
      const node = site.closest(".node")
      if (node) sites.push({site, node, to: site.dataset.edgeTo})
    }

    // The frame round a group is an obstacle to every card outside it, so the sections a pass
    // lays out come out one below another instead of interleaving, and the frame round a
    // cluster is an obstacle to every card of the section that is not of that module, so the
    // clusters of one section come out a gap apart. The frames are read from the boxes rather
    // than from the layer the hook draws into, because a card placed earlier in this pass has
    // grown its group's frame and is not rendered anywhere yet.
    //
    // The allowance is measured at scale 1, in screen pixels, and the gap is taken undivided:
    // a position the pass pushes is stored and read back at every zoom, so it must not depend
    // on how far out the reader was standing when the card arrived. The header is
    // counter-scaled, so its screen height is the height the frame will have at 100%.
    //
    // Header heights are measured once: nothing in the pass moves a header, and each read of
    // one is a layout the browser is asked for.
    const headerHeights = new Map()
    const headerHeightFor = (group) => {
      if (!headerHeights.has(group)) headerHeights.set(group, this.headerHeightOf(group, 1))
      return headerHeights.get(group)
    }
    // The head a module frame leaves above its cards, read in the screen pixels the flow heads
    // are read in. While the clusters are drawn a flow frame closes round its module frames
    // rather than round its cards, so the pass is kept clear of the rectangles the reader sees;
    // with the clusters undrawn there are no module frames and a flow frame closes round the
    // cards themselves.
    const labelHeight = this.modules ? this.moduleLabelPx() : null
    const moduleHead =
      labelHeight === null ? 0 : frameHead(labelHeight, MODULE_TITLE_GAP, MODULE_PAD)
    const framesOf = (placed) => {
      const {moduleFrames, extents} = clusterFrames(
        placed.map((b) => ({
          group: b.node.dataset.group || "",
          module: b.node.dataset.module || "",
          left: b.left,
          top: b.top,
          right: b.right,
          bottom: b.bottom,
        })),
        labelHeight,
        MODULE_TITLE_GAP,
      )
      const frames = [...extents].map(([group, e]) => ({
        group,
        frame: true,
        kind: "flow",
        ...frameAround(e, headerHeightFor(group), FRAME_TITLE_GAP, FRAME_PAD),
      }))
      for (const f of moduleFrames) {
        frames.push({
          group: f.group,
          cluster: `${f.group}|${f.module}`,
          frame: true,
          kind: "module",
          left: f.left,
          top: f.top,
          right: f.right,
          bottom: f.bottom,
        })
      }
      return frames
    }
    let frameBoxes = framesOf(occupied)

    // A depth counts from the root of the card's own section, so it says how far along a flow
    // a card is and nothing about where a card of another section stands. Taking the sections
    // one at a time is what makes the order mean something: inside one, a caller is placed
    // before the callee that hangs off it, and a group that has yet to place a card is laid
    // out against the groups already down rather than into the middle of them.
    unplaced.sort(
      (a, b) =>
        sortGroup(a) - sortGroup(b) ||
        Number(a.dataset.depth) - Number(b.dataset.depth) ||
        Number(a.dataset.card) - Number(b.dataset.card),
    )

    const placements = []
    for (const node of unplaced) {
      const m = measured.get(node)
      const id = node.dataset.card
      const group = node.dataset.group
      // A neighbour to stand beside is one of the card's own section: a call that crosses into
      // another group would put the card inside that group's frame, where it does not belong,
      // so a card reached only from outside its group is a root of its own group instead.
      const opener = sites.find(
        (hit) => hit.to === id && hit.node.dataset.group === group && boxes.has(hit.node),
      )
      const calls =
        !opener &&
        sites.find((hit) => {
          if (hit.node !== node) return false
          const callee = document.getElementById(`node-${hit.to}`)
          return !!callee && callee.dataset.group === group && boxes.has(callee)
        })
      // The room the card's own frame takes above it, which every drop past another section's
      // frame carries with it and which the first card of a section starts under. A card in no
      // group carries no frame and so no allowance.
      const head = group ? frameHead(headerHeightFor(group), FRAME_TITLE_GAP, FRAME_PAD) : 0
      // The cluster the card joins — the module it names inside the section it names — and the
      // frame round that cluster where the section already holds a card of it. A node that
      // names no module, and every card while the clusters are undrawn, joins no cluster.
      const cluster =
        labelHeight !== null && node.dataset.module
          ? `${group || ""}|${node.dataset.module}`
          : null
      const home = cluster === null ? null : frameBoxes.find((f) => f.cluster === cluster)
      // The frames a card is placed clear of: the sections that are not its own, and the
      // clusters that are not its own wherever they stand, since a cluster of the groupless
      // section has no flow frame round it to stand in for it. Its own section's frame and its
      // own cluster's are not among them — a card belongs inside both, and each grows round it
      // where it lands.
      const foreign = frameBoxes.filter((f) =>
        f.kind === "module" ? f.cluster !== cluster : f.group !== group,
      )
      // The room the card leaves an obstacle: the placement gap against another card, and
      // against a frame that gap plus what the card's own frames reach beyond it on that side,
      // so the frames the card grows end GAP_Y clear of their neighbour rather than cutting into
      // it. Which of the card's frames count depends on where the obstacle stands. Past another
      // section's frame both do, the card's cluster's inside its section's. Past a cluster of
      // the card's own section only the cluster's, because the two stand inside one section
      // frame that neither has to clear. Past a cluster of another section the card's section
      // frame has to clear it too, so its padding counts as well — a groupless cluster has no
      // frame of its own standing between the two. A card in no group grows no section frame,
      // and a card that joins no cluster grows no module frame, so each takes nothing where it
      // has nothing. Every module obstacle names its section as the empty string where it has
      // none, which is what a groupless card's own group reads as.
      const pad = group ? FRAME_PAD : 0
      const ownPad = cluster === null ? 0 : MODULE_PAD
      const ownHead = cluster === null ? 0 : moduleHead
      const sameSection = (other) => other.group === (group || "")
      const clearance = (other) => {
        if (!other.frame) return GAP_Y
        return other.kind === "module"
          ? MODULE_PAD + (sameSection(other) ? 0 : pad) + GAP_Y
          : pad + ownPad + GAP_Y
      }
      // The allowance a drop past a frame carries: the head the card's own frames leave above
      // it on that side, the same frames `clearance` counts the padding of. It is at least that
      // padding — `head >= pad` and `ownHead >= ownPad`, each by a title and its gap — so a drop
      // always lands at or beyond the clearance it is tested against, which is what keeps a
      // sweep moving in one direction and so ending.
      const headPast = (other) => {
        if (!other.frame) return 0
        return other.kind === "module"
          ? moduleHead + (sameSection(other) ? 0 : head)
          : head + ownHead
      }
      let x, y
      if (opener) {
        // The callee stands off the opener's right edge, level with the call that opened it:
        // the edge the hook draws leaves that line and arrives at the callee's port, so the
        // two meet without a bend. A call site the browser gives no box — scrolled away, or
        // inside a fold — leaves the card at its own port height.
        const box = boxes.get(opener.node)
        const a = opener.site.getBoundingClientRect()
        const anchored = a.width > 0 || a.height > 0
        const line = anchored
          ? (a.top + a.height / 2 - s.top) / scale - measured.get(opener.node).top
          : PORT_Y
        x = box.right + GAP_X
        y = box.top + Math.min(Math.max(line, 0), box.bottom - box.top) - PORT_Y
      } else if (calls) {
        // A card opened from its callee is the caller, and a caller reads to the left of what
        // it calls, its top edge level with it.
        const box = boxes.get(document.getElementById(`node-${calls.to}`))
        x = box.left - m.width - GAP_X
        y = box.top
      } else {
        // A root belongs to nothing on the canvas, so it starts a column of its own. With peers
        // of its section already down it opens a row under the lowest of them, at the section's
        // left edge — and where that row would reach into another section's frame it goes
        // beside the peers instead, off their right edge and level with their top, which is
        // room the section can take without growing downwards into its neighbour. A section
        // hemmed in on both sides takes the row and leaves the sweep to drop it.
        //
        // Only the frames decide between the two candidates; a card in the way is what the
        // sweep below handles.
        const peers = occupied.filter((b) => b.node.dataset.group === group)
        if (peers.length > 0) {
          const below = {
            x: Math.min(...peers.map((b) => b.left)),
            y: Math.max(...peers.map((b) => b.bottom)) + GAP_Y,
          }
          const beside = {
            x: Math.max(...peers.map((b) => b.right)) + GAP_X,
            y: Math.min(...peers.map((b) => b.top)),
          }
          const clearOfFrames = (at) =>
            !foreign.some((f) =>
              overlaps(
                {left: at.x, top: at.y, right: at.x + m.width, bottom: at.y + m.height},
                f,
                clearance(f),
              ),
            )
          const at = clearOfFrames(below) || !clearOfFrames(beside) ? below : beside
          x = at.x
          y = at.y
        } else {
          // The first card of a section starts below everything on the stage — every card and
          // every frame — at the stage's left edge, so a section is a band of its own rather
          // than a column beside the sections already laid out. The allowance above it is the
          // head of every frame that will close over it, its cluster's inside its section's,
          // which is what leaves the section frame's own top clear of the frame above by GAP_Y,
          // and, with nothing placed at all, what keeps the first title on the stage instead of
          // above its corner.
          const bottoms = occupied.map((b) => b.bottom).concat(frameBoxes.map((f) => f.bottom))
          x = 0
          y = (bottoms.length === 0 ? 0 : Math.max(...bottoms) + GAP_Y) + head + ownHead
        }
      }

      // Nothing is ever laid on top of anything: a card that would land on an occupied box, or
      // inside a frame that is not its own, moves clear of it, and clear of whatever that move
      // ran it into next. A move downwards past a frame carries `headPast`, the head the card's
      // own frames leave above it on that side, so the frames that grow round the card clear the
      // one it passed by GAP_Y rather than cutting into it — that head is at least the padding
      // the same frames take below, which is what `clearance` carries, so the move lands the
      // card outside the clearance it is tested against. Upwards no allowance is needed: what
      // the card's own frames extend below it is exactly that padding, so a bottom set at
      // `other.top - clearance(other)` leaves the frames GAP_Y apart. Sideways the clearance is
      // the whole of it, and a card that comes to rest against it ends the same GAP_Y clear. A
      // move past a card is the card's own gap either way, and card and frame agree where the
      // obstacle is a card of another section, since the frames holding that card are obstacles
      // as well and the sweep that follows the move past it finds the frame it is still inside.
      //
      // Each move within a sweep is strictly in the sweep's direction — downwards the top only
      // grows, upwards the bottom only shrinks — so a sweep runs out of obstacles within one
      // iteration per obstacle, the bound holding for either direction by the same argument
      // mirrored. With the clusters undrawn the card's own cluster allowances are zero and
      // every one of these lengths is the section's alone.
      //
      // A callee is swept four ways from the ideal box beside its opener: down and up in the
      // ideal column, and down and up in the column one card width and GAP_X to the right. The
      // candidate whose top-left comes to rest nearest the ideal top-left wins, ties going to
      // the ideal column and to downwards, and a candidate that never moved is at distance zero
      // and takes it outright. Upwards is open to a callee because the stage is unbounded both
      // ways and the edge the hook draws reads the same arriving at a port from above as from
      // below, so the nearest clear spot is the one that keeps the callee beside its call. A
      // root and a caller sweep downwards only: sections are stacked downwards on purpose, and a
      // card that leaves a frame downwards is clear of it for good.
      //
      // A group that has been closed in on both sides — the row below it and the room beside it
      // both taken — grows round its neighbour when a card of it lands past that neighbour.
      //
      // A callee or caller whose module already stands in the section is swept from four spots
      // against that cluster's frame instead of from the ideal box — to its right, below it,
      // above it and to its left — because the cards of one module read as one block and a card
      // of that module belongs in the block rather than beside the call. The ideal spot still
      // decides among the four: it is the only thing that says where the call the card was
      // opened from stands, so of the four ways round the cluster the card takes the one that
      // leaves it nearest its call. Below and above the frame the card owes the cards inside it
      // one GAP_Y and nothing more, because it is joining that frame rather than clearing it.
      // A card whose module has nothing down yet is placed by the ordinary rule, and so is a
      // root either way.
      const obstacles = occupied.concat(foreign)
      const sweep = (start, direction) => {
        const swept = {...start}
        for (let pass = 0; pass <= obstacles.length; pass++) {
          let moved = false
          for (const other of obstacles) {
            if (!overlaps(swept, other, clearance(other))) continue
            if (direction === "down") {
              swept.top = other.bottom + GAP_Y + headPast(other)
              swept.bottom = swept.top + m.height
            } else {
              swept.bottom = other.top - clearance(other)
              swept.top = swept.bottom - m.height
            }
            moved = true
          }
          if (!moved) break
        }
        return swept
      }
      const ideal = {left: x, top: y, right: x + m.width, bottom: y + m.height, node}
      let box
      if (home && (opener || calls)) {
        // Beside the cluster the card keeps the line of its call, clamped into the frame's own
        // band so that it stands against the cluster rather than off one of its corners. Below
        // and above, the card is joining the frame rather than clearing it, so it owes the
        // cards inside one gap and no more: it takes the column the leftmost of them starts,
        // one GAP_Y under the lowest or over the highest, which is what one card of a cluster
        // owes another.
        const band = Math.max(home.top, Math.min(ideal.top, home.bottom - m.height))
        const spots = []
        for (const at of [
          {x: home.right + GAP_X, y: band},
          {x: home.left + MODULE_PAD, y: home.bottom - MODULE_PAD + GAP_Y},
          {x: home.left + MODULE_PAD, y: home.top + moduleHead - GAP_Y - m.height},
          {x: home.left - GAP_X - m.width, y: band},
        ]) {
          const from = {
            left: at.x,
            top: at.y,
            right: at.x + m.width,
            bottom: at.y + m.height,
            node,
          }
          spots.push([from, "down"], [from, "up"])
        }
        let nearest = Infinity
        for (const [from, direction] of spots) {
          const settled = sweep(from, direction)
          const away = Math.hypot(settled.left - ideal.left, settled.top - ideal.top)
          if (away < nearest) {
            nearest = away
            box = settled
          }
          if (nearest === 0) break
        }
      } else if (opener) {
        const over = m.width + GAP_X
        const next = {...ideal, left: ideal.left + over, right: ideal.right + over}
        let nearest = Infinity
        for (const [from, direction] of [
          [ideal, "down"],
          [ideal, "up"],
          [next, "down"],
          [next, "up"],
        ]) {
          const settled = sweep(from, direction)
          const away = Math.hypot(settled.left - ideal.left, settled.top - ideal.top)
          if (away < nearest) {
            nearest = away
            box = settled
          }
          if (nearest === 0) break
        }
      } else {
        box = sweep(ideal, "down")
      }

      // The server reads integers and drops a placement it cannot; the box recorded is the one
      // the server will render, so the card placed next reckons with the same rectangle.
      const px = Math.round(box.left)
      const py = Math.round(box.top)
      box = {left: px, top: py, right: px + m.width, bottom: py + m.height, node}
      boxes.set(node, box)
      occupied.push(box)
      // The card has grown its section's frame, and the next card of the pass is placed clear
      // of the frame as it stands rather than as the pass found it.
      frameBoxes = framesOf(occupied)
      placements.push({id: Number(id), x: px, y: py})
      // The box outlives the pass: until the answer arrives the card is still `data-unplaced`
      // and drawn at the corner, and this is the only record of where it is going.
      this.attempted.set(id, {
        box: {left: px, top: py, right: box.right, bottom: box.bottom},
        pass: this.passes,
        warned: false,
      })
    }

    this.pushEvent("place_cards", {cards: placements})
  },

  // Every card on the canvas is watched for its height, because a card that grows would
  // otherwise come down over whatever stands under it. Observing an element already observed
  // is a no-op, so the cards a patch brought are covered by running this on every patch.
  observeCards() {
    const cards = [...this.el.querySelectorAll(".card")]
    for (const card of cards) this.cardObserver.observe(card)
    // A card the reader closed takes its height and its pushes with it: the card that opens in
    // its place is measured from scratch rather than against the height of the card that stood
    // there, and a push nothing can be moved back by is a push to forget.
    const live = new Set(cards.map((card) => cardId(card)))
    for (const id of this.cardHeights.keys()) {
      if (!live.has(id)) this.cardHeights.delete(id)
    }
    for (const id of this.pushes.keys()) {
      if (!live.has(id)) this.pushes.delete(id)
    }
  },

  // The heights the observer reports, a push for each card that grew and a retraction for each
  // card that shrank back.
  //
  // A card's height is its own layout box, which the stage's transform leaves alone, so a
  // growth is already in stage units and is not divided by the zoom — unlike a box read off
  // the screen, which is. A counter-scaled card is the exception the other way: signature mode
  // sizes a card from --zoom, so its stage-unit height changes with the zoom and with the mode
  // itself. Those reports are the same cards measured again, and a re-measure moves nothing.
  //
  // The first report for a card is the height it arrived at, neither a growth nor a shrink, so
  // it moves nothing. Every report is recorded whatever else it leads to, so the next one is
  // measured against the height the reader is looking at.
  cardResized(entries) {
    const grown = []
    const shrunk = []
    for (const entry of entries) {
      const card = entry.target
      const id = cardId(card)
      const height = entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height
      const previous = this.cardHeights.get(id)
      this.cardHeights.set(id, height)
      if (previous === undefined) continue
      const node = card.closest(".node")
      // A card still waiting for a position is drawn at the stage's corner and out of sight,
      // and the placement pass is what keeps it clear of the rest.
      if (!node || node.hasAttribute("data-unplaced")) continue
      // Half a pixel either way is the layout rounding rather than a card changing size. A
      // shrink moves nothing of its own: the room a card gives back is the room it took, so a
      // card with no push to its name leaves everything under it where it stands.
      if (height > previous + 0.5) {
        grown.push({node, dy: height - previous, top: this.positionOf(node).y})
      } else if (height < previous - 0.5 && this.pushes.get(id)?.length) {
        shrunk.push({node, shrink: previous - height})
      }
    }
    // The heights of a re-measure are kept, so the next growth is measured against the card as
    // the reader sees it, and the re-measure itself moves nothing.
    if (this.remeasure) return
    // Nothing a reader does grows a signature card: what it shows is its header and the one
    // line that names it, whatever the card holds.
    if (this.signatures) return
    // A card that grows mid-drag is measured all the same, but the boxes a push would read are
    // the ones the drag is in the middle of moving.
    if (this.drag) return
    // Room given back before room is taken: a retraction reads the positions its pushes left,
    // and the push that follows reads a canvas already back where the shrink put it.
    for (const {node, shrink} of shrunk) this.retract(node, shrink)
    // Topmost first: a card lower down is pushed by the card above it before it pushes on its
    // own account, and a push is read from where its cards stand, displacement and all, so the
    // two growths add up.
    grown.sort((a, b) => a.top - b.top)
    for (const {node, dy} of grown) this.pushBelow(node, dy)
  },

  // The cards a grown card would cover, moved down by exactly what it grew.
  //
  // A uniform `dy` is what restores the canvas rather than tidying it: every card under the
  // grown one was clear of it by at least GAP_Y before it grew, so moving each down by the
  // growth gives back exactly that clearance, and the cards those run into travel the same
  // distance for the same reason. Two cards the reader had overlapping stay overlapping by the
  // amount the reader left between them — a push restores an arrangement, it does not correct
  // one.
  //
  // Only cards from the grown card's top down move: a card the reader dragged over it from
  // above is where the reader put it. Cards of other groups are pushed like any other card and
  // their frames follow them, so no frame is an obstacle to a push.
  pushBelow(node, dy) {
    const boxes = this.placedBoxes()
    // The observer runs after the layout that grew the card, so the box read here is the
    // grown one. A card whose move the server has yet to answer for is read where it stands,
    // the displacement it carries included, so a card that grows twice inside one round trip
    // pushes the second time from the place the first push left everything.
    const grown = boxes.find((b) => b.node === node)
    if (!grown) return
    const others = boxes.filter((b) => b !== grown)
    const pushed = []
    const moving = new Set()
    for (const b of others) {
      if (b.top >= grown.top && overlaps(grown, b, GAP_Y)) {
        pushed.push(b)
        moving.add(b)
      }
    }
    // A card moved takes room of its own where it lands, so whatever it runs into travels with
    // it. A card joins the push once and only from the top of the card that pushed it down, so
    // the cascade runs out within one round per box.
    for (let i = 0; i < pushed.length; i++) {
      const b = pushed[i]
      const shifted = {...b, top: b.top + dy, bottom: b.bottom + dy}
      for (const c of others) {
        if (moving.has(c)) continue
        if (c.top >= b.top && overlaps(shifted, c, GAP_Y)) {
          pushed.push(c)
          moving.add(c)
        }
      }
    }
    if (pushed.length === 0) return
    // The session owns the positions: the translate is the move seen at once and updated()
    // drops it as soon as the render carrying the new positions arrives. Whole stage pixels,
    // because the server reads integer coordinates and drops a move whose coordinates it
    // cannot.
    const shift = Math.round(dy)
    const cards = []
    const tops = new Map()
    for (const b of pushed) {
      // The displacement already on the node is a move the server has yet to answer for; this
      // one is added to it, and the session adds the two deltas in the order they were pushed.
      const carried = this.translateOf(b.node)
      b.node.style.translate = `${carried.x}px ${carried.y + shift}px`
      cards.push(b.id)
      tops.set(b.id, b.top + shift)
    }
    this.pushEvent("move_cards", {cards, dx: 0, dy: shift})
    // The frames and the edges are drawn from the boxes as they stand, so they follow the move
    // rather than waiting for the render.
    this.draw()
    // A push that can never be retracted — its cards dragged away or closed — stays on the
    // stack, and a card streaming a thread grows many times over, so the stack keeps only the
    // most recent pushes; the oldest are the ones least likely to be undone.
    const stack = this.pushes.get(grown.id) || []
    stack.push({dy: shift, cards: tops})
    if (stack.length > PUSH_MEMORY) stack.shift()
    this.pushes.set(grown.id, stack)
  },

  // A push undone: a card that shrinks back lets the cards it pushed return, newest push
  // first, and only while those cards are where the push left them.
  //
  // A push is given back whole or not at all — its cards travelled together and the room it
  // took is one card's worth of growth — so a shrink smaller than the push on top of the stack
  // returns nothing, and what is left of the shrink pays for the push under it.
  //
  // Whether a push is retracted is read from the cards alone: a card the reader has dragged
  // since, one another move is in flight for, one that is gone or one still waiting for a
  // position is not a card standing where the push left it, and that push and every push under
  // it stay. The arrangement from there down is the reader's.
  retract(node, shrink) {
    const id = Number(node.dataset.card)
    const stack = this.pushes.get(id)
    if (!stack) return
    let remaining = shrink
    // What this retraction has already given back, per card. A card named by two pushes of the
    // same stack stands, for the push under the one just retracted, at the top that push left
    // it — displacement and all — and the displacement written here is the one displacement a
    // card may carry and still be standing where a push left it.
    const returned = new Map()
    while (stack.length > 0) {
      const push = stack[stack.length - 1]
      // The push travelled a whole pixel and the shrink is measured to the fraction, so the
      // room asked for carries the half-pixel of layout rounding the growth was read with.
      if (push.dy > remaining + 0.5) break
      const nodes = new Map()
      const standing = [...push.cards].every(([card, top]) => {
        const pushed = this.el.querySelector(`.node[data-card="${card}"]:not([data-unplaced])`)
        if (!pushed) return false
        const given = returned.get(card) || 0
        const carried = this.translateOf(pushed)
        if (carried.x !== 0 || carried.y !== given) return false
        if (this.positionOf(pushed).y + given !== top) return false
        nodes.set(card, pushed)
        return true
      })
      if (!standing) break
      stack.pop()
      remaining -= push.dy
      for (const [card, pushed] of nodes) {
        const given = (returned.get(card) || 0) - push.dy
        returned.set(card, given)
        pushed.style.translate = `0px ${given}px`
      }
      this.pushEvent("move_cards", {cards: [...nodes.keys()], dx: 0, dy: -push.dy})
    }
    if (stack.length === 0) this.pushes.delete(id)
    // The frames and the edges are drawn from the boxes as they stand, so they come back with
    // the cards rather than waiting for the render.
    if (returned.size > 0) this.draw()
  },

  // Where every placed card stands, in stage pixels, as a placement pass reads it: the
  // position the server rendered for left and top, and the measured rectangle for width and
  // height, which is a screen measurement and so divided by the scale.
  //
  // A card carrying an inline translate is standing at a move the server has yet to answer
  // for, and is read where it stands: the position plus the displacement, as a drag reads it.
  placedBoxes() {
    const {scale} = this.view
    const boxes = []
    for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
      const b = node.getBoundingClientRect()
      const {x, y} = this.positionOf(node)
      const carried = this.translateOf(node)
      const left = x + carried.x
      const top = y + carried.y
      boxes.push({
        id: Number(node.dataset.card),
        node,
        left,
        top,
        right: left + b.width / scale,
        bottom: top + b.height / scale,
      })
    }
    return boxes
  },
}

// The room a frame leaves above the cards it holds: the padding alone for a group whose section
// carries no header, and otherwise the header, the gap under it and the padding. The lengths
// are the caller's own units, the header and the gap included.
function frameHead(headerHeight, titleGap, pad) {
  return headerHeight === null ? pad : headerHeight + titleGap + pad
}

// The rectangle round a set of cards: `pad` on three sides and, above, room for the header they
// are named by — a section's title, or a cluster's module. `extent` is the union of the boxes.
//
// Drawing a frame and deciding a placement share the formula and part over the units they feed
// it. A frame is drawn in stage units at the scale it is drawn at, where the counter-scaled
// header and gap grow as the reader zooms out; a placement works in screen pixels, which is the
// frame at 100%. So the two tops agree at 100%, and further out the drawn head is the larger of
// the two.
function frameAround(extent, headerHeight, titleGap, pad) {
  return {
    left: extent.left - pad,
    top: extent.top - frameHead(headerHeight, titleGap, pad),
    right: extent.right + pad,
    bottom: extent.bottom + pad,
  }
}

// The clusters a set of cards falls into — one per module named inside one group — as the frame
// round each and the extent each group's frame is to close round. With a `labelHeight` the
// clusters are drawn, so a group's extent is the union of its module frames and a flow frame
// closes round its modules; without one there are no module frames and the extent is the union
// of the cards themselves. `labelHeight` and `moduleGap` are the head a module frame leaves
// above its cards, in whatever units the cards are given in — stage units for a draw, screen
// pixels for a placement.
//
// Drawing the frames and placing a card share this so that the rectangle a placement keeps
// clear of is the rectangle the reader sees.
function clusterFrames(cards, labelHeight, moduleGap) {
  const clusters = new Map()
  for (const {group, module, left, top, right, bottom} of cards) {
    const key = `${group}|${module}`
    const e = clusters.get(key) || {
      group,
      module,
      left: Infinity,
      top: Infinity,
      right: -Infinity,
      bottom: -Infinity,
    }
    e.left = Math.min(e.left, left)
    e.top = Math.min(e.top, top)
    e.right = Math.max(e.right, right)
    e.bottom = Math.max(e.bottom, bottom)
    clusters.set(key, e)
  }
  const moduleFrames = []
  const extents = new Map()
  for (const cluster of clusters.values()) {
    // The empty module is what a node rendered without the attribute falls back to; it clusters
    // with nothing and closes its section's frame the way any card does.
    const framed = labelHeight !== null && cluster.module !== ""
    const box = framed ? frameAround(cluster, labelHeight, moduleGap, MODULE_PAD) : cluster
    if (framed) moduleFrames.push({...box, group: cluster.group, module: cluster.module})
    if (!cluster.group) continue
    const e = extents.get(cluster.group) || {
      left: Infinity,
      top: Infinity,
      right: -Infinity,
      bottom: -Infinity,
    }
    e.left = Math.min(e.left, box.left)
    e.top = Math.min(e.top, box.top)
    e.right = Math.max(e.right, box.right)
    e.bottom = Math.max(e.bottom, box.bottom)
    extents.set(cluster.group, e)
  }
  return {moduleFrames, extents}
}

// A node's group as a number to sort by, in the order the sections are rendered in: the cards
// in no group are the last section, after every group.
function sortGroup(node) {
  return node.dataset.group === "" ? Number.MAX_SAFE_INTEGER : Number(node.dataset.group)
}

// The card a card element is, as the number its id carries — the same number the node round
// it carries in `data-card`.
function cardId(card) {
  return Number(card.id.replace("card-", ""))
}

// Two boxes are clear of one another only with `margin` between them on every side, so a card
// never comes to rest against the edge of what it was placed against.
function overlaps(a, b, margin) {
  return (
    a.left < b.right + margin &&
    a.right > b.left - margin &&
    a.top < b.bottom + margin &&
    a.bottom > b.top - margin
  )
}

export default Canvas
