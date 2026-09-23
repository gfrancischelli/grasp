(() => {
  // js/hooks/palette.js
  var Palette = {
    mounted() {
      this.input = this.el.querySelector("input[name=q]");
      this.wasOpen = false;
      this.onKeydownWindow = (e) => {
        if (document.getElementById("help")?.open) return;
        if ((e.metaKey || e.ctrlKey) && e.key?.toLowerCase() === "k") {
          e.preventDefault();
          this.pushEvent("palette_show", {});
        } else if (e.key === "/" && !e.metaKey && !e.ctrlKey && !e.altKey) {
          if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return;
          e.preventDefault();
          this.pushEvent("palette_show", {});
        }
      };
      window.addEventListener("keydown", this.onKeydownWindow);
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          this.pushEvent("palette_hide", {});
        } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          this.pushEvent("palette_move", { delta: e.key === "ArrowDown" ? 1 : -1 });
        } else if (e.key === "Enter") {
          e.preventDefault();
          this.pushEvent("palette_choose", { child: e.shiftKey });
        }
      });
      this.focusWhenOpened();
    },
    updated() {
      this.focusWhenOpened();
      this.el.querySelector("li[aria-selected='true']")?.scrollIntoView({ block: "nearest" });
    },
    destroyed() {
      window.removeEventListener("keydown", this.onKeydownWindow);
    },
    // Focus is taken once per opening: on later patches the caret belongs to whatever the
    // user is typing in, so stealing it back would undo their edits.
    focusWhenOpened() {
      const open = this.el.dataset.open === "true";
      if (open && !this.wasOpen && document.activeElement !== this.input) {
        this.input.focus();
        this.input.select();
      }
      this.wasOpen = open;
    }
  };
  var palette_default = Palette;

  // js/hooks/keys.js
  var DIRECTIONS = {
    ArrowLeft: "parent",
    ArrowRight: "child",
    ArrowUp: "prev",
    ArrowDown: "next",
    h: "parent",
    l: "child",
    k: "prev",
    j: "next"
  };
  var Keys = {
    mounted() {
      this.onKeydown = (e) => {
        if (document.getElementById("palette")?.dataset.open === "true") return;
        if (document.getElementById("help")?.open) return;
        const chatToggle = (e.metaKey || e.ctrlKey) && e.key === "i";
        if (["INPUT", "TEXTAREA"].includes(e.target.tagName) && !chatToggle) return;
        if (e.metaKey || e.ctrlKey) {
          if (e.key === "m" || e.key === "\\") {
            e.preventDefault();
            this.pushEvent("toggle_sidebar", {});
          } else if (e.key === "i") {
            e.preventDefault();
            this.pushEvent("chat_toggle", {});
          } else if (e.key === "0") {
            e.preventDefault();
            window.dispatchEvent(new CustomEvent("grasp:zoom-reset"));
          } else if (e.key.toLowerCase() === "g") {
            e.preventDefault();
            this.pushEvent(e.shiftKey ? "ungroup_selected" : "group_selected", {});
          }
          return;
        }
        if (e.altKey) return;
        if (DIRECTIONS[e.key]) {
          e.preventDefault();
          this.pushEvent("move_focus", { dir: DIRECTIONS[e.key] });
        } else if (e.key.toLowerCase() === "x") {
          this.pushEvent(e.shiftKey ? "close_focused_chain" : "close_focused", {});
        } else if (e.key === "c") {
          this.pushEvent("collapse_focused", {});
        } else if (e.key === "d") {
          this.pushEvent("toggle_view_focused", {});
        } else if (e.key === "z") {
          this.pushEvent("toggle_context_focused", {});
        } else if (e.key.toLowerCase() === "s") {
          window.dispatchEvent(new CustomEvent("grasp:toggle-signatures"));
        } else if (e.key.toLowerCase() === "m") {
          window.dispatchEvent(new CustomEvent("grasp:toggle-modules"));
        } else if (e.key.toLowerCase() === "f") {
          window.dispatchEvent(new CustomEvent("grasp:zoom-fit"));
        } else if (e.key === "Escape") {
          this.pushEvent("clear_selection", {});
        }
      };
      window.addEventListener("keydown", this.onKeydown);
    },
    destroyed() {
      window.removeEventListener("keydown", this.onKeydown);
    }
  };
  var keys_default = Keys;

  // js/hooks/canvas.js
  var MIN_SCALE = 0.05;
  var MAX_SCALE = 2.5;
  var DRAG_THRESHOLD = 4;
  var MARGIN = 24;
  var PORT_Y = 18;
  var CTRL_MENU_GRACE = 300;
  var FRAME_PAD = 28;
  var FRAME_TITLE_GAP = 8;
  var MODULE_PAD = 12;
  var MODULE_TITLE_GAP = 4;
  var GAP_X = 48;
  var GAP_Y = 16;
  var PUSH_MEMORY = 32;
  var STAGE_PAD = 48;
  var attr = (value) => String(value ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  var Canvas = {
    mounted() {
      this.stage = this.el.querySelector("#stage");
      this.svg = this.el.querySelector("#connectors");
      this.zoomLevel = this.el.querySelector("#zoom-level");
      this.view = { x: MARGIN, y: MARGIN, scale: 1 };
      this.signatures = false;
      this.modules = true;
      document.body.classList.toggle("grasp-modules", this.modules);
      this.frames = [];
      this.lastReveal = null;
      this.extent = { width: 0, height: 0 };
      this.attempted = /* @__PURE__ */ new Map();
      this.passes = 0;
      this.pendingReveal = null;
      this.drawnScale = this.view.scale;
      this.labelPx = 0;
      this.styledScale = this.view.scale;
      this.remeasure = false;
      this.remeasureFrame = null;
      this.style = document.getElementById("grasp-canvas-style") || document.head.appendChild(
        Object.assign(document.createElement("style"), { id: "grasp-canvas-style" })
      );
      this.applyView();
      this.onWheel = (e) => this.wheel(e);
      this.onPointerDown = (e) => this.pointerDown(e);
      this.onPointerMove = (e) => this.pointerMove(e);
      this.onPointerUp = (e) => this.pointerUp(e);
      this.onPointerCancel = (e) => this.pointerCancel(e);
      this.onClickCapture = (e) => this.clickCapture(e);
      this.onDoubleClick = (e) => this.doubleClick(e);
      this.onContextMenu = (e) => this.contextMenu(e);
      this.onKeyDown = (e) => this.spaceDown(e);
      this.onKeyUp = (e) => this.spaceUp(e);
      this.onZoomReset = () => this.resetZoom();
      this.onToggleSignatures = () => this.toggleSignatures();
      this.onToggleModules = () => this.toggleModules();
      this.onZoomFit = () => this.fit();
      this.onSpaceRelease = () => this.releaseSpace();
      this.el.addEventListener("wheel", this.onWheel, { passive: false });
      this.el.addEventListener("pointerdown", this.onPointerDown);
      window.addEventListener("pointermove", this.onPointerMove);
      window.addEventListener("pointerup", this.onPointerUp);
      window.addEventListener("pointercancel", this.onPointerCancel);
      this.el.addEventListener("click", this.onClickCapture, true);
      this.el.addEventListener("dblclick", this.onDoubleClick);
      this.el.addEventListener("contextmenu", this.onContextMenu);
      window.addEventListener("keydown", this.onKeyDown);
      window.addEventListener("keyup", this.onKeyUp);
      window.addEventListener("grasp:zoom-reset", this.onZoomReset);
      window.addEventListener("grasp:toggle-signatures", this.onToggleSignatures);
      window.addEventListener("grasp:toggle-modules", this.onToggleModules);
      window.addEventListener("grasp:zoom-fit", this.onZoomFit);
      window.addEventListener("blur", this.onSpaceRelease);
      document.addEventListener("visibilitychange", this.onSpaceRelease);
      this.resizeObserver = new ResizeObserver(() => this.draw());
      this.resizeObserver.observe(this.stage);
      this.cardHeights = /* @__PURE__ */ new Map();
      this.pushes = /* @__PURE__ */ new Map();
      this.cardObserver = new ResizeObserver((entries) => this.cardResized(entries));
      this.observeCards();
      this.handleEvent("focus", ({ id }) => {
        const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || "";
        if (`${id}:${key}` === this.lastReveal) return;
        const node = document.getElementById(`node-${id}`);
        if (!node || node.hasAttribute("data-unplaced")) {
          this.pendingReveal = id;
          return;
        }
        this.lastReveal = `${id}:${key}`;
        this.revealCard(id);
      });
      this.placeCards();
      this.draw();
    },
    updated() {
      this.el.querySelectorAll(".node[style*='translate']").forEach((node) => node.style.translate = "");
      this.observeCards();
      this.placeCards();
      this.draw();
      this.revealPending();
    },
    // The reveal a focus put off because its card had nowhere to be panned to. The render that
    // carries the position is the first moment there is: a card closed before it arrives is a
    // reveal to drop.
    revealPending() {
      const id = this.pendingReveal;
      if (id === null) return;
      const node = document.getElementById(`node-${id}`);
      if (node && node.hasAttribute("data-unplaced")) return;
      this.pendingReveal = null;
      if (!node) return;
      const key = document.getElementById(`card-${id}`)?.dataset.highlightKey || "";
      this.lastReveal = `${id}:${key}`;
      this.revealCard(id);
    },
    destroyed() {
      this.el.removeEventListener("wheel", this.onWheel);
      this.el.removeEventListener("pointerdown", this.onPointerDown);
      window.removeEventListener("pointermove", this.onPointerMove);
      window.removeEventListener("pointerup", this.onPointerUp);
      window.removeEventListener("pointercancel", this.onPointerCancel);
      this.el.removeEventListener("click", this.onClickCapture, true);
      this.el.removeEventListener("dblclick", this.onDoubleClick);
      this.el.removeEventListener("contextmenu", this.onContextMenu);
      window.removeEventListener("keydown", this.onKeyDown);
      window.removeEventListener("keyup", this.onKeyUp);
      window.removeEventListener("grasp:zoom-reset", this.onZoomReset);
      window.removeEventListener("grasp:toggle-signatures", this.onToggleSignatures);
      window.removeEventListener("grasp:toggle-modules", this.onToggleModules);
      window.removeEventListener("grasp:zoom-fit", this.onZoomFit);
      window.removeEventListener("blur", this.onSpaceRelease);
      document.removeEventListener("visibilitychange", this.onSpaceRelease);
      document.body.classList.remove("grasp-space");
      document.body.classList.remove("grasp-dragging");
      document.body.classList.remove("grasp-signatures");
      document.body.classList.remove("grasp-modules");
      this.resizeObserver.disconnect();
      this.cardObserver.disconnect();
      if (this.remeasureFrame !== null) cancelAnimationFrame(this.remeasureFrame);
      this.style.remove();
    },
    // The translate is rounded to whole screen pixels: a fractional composited offset resamples
    // the rasterised card text and blurs it. this.view stays fractional so small deltas accumulate.
    applyView() {
      const { scale } = this.view;
      this.writeStyle();
      if (this.drawnScale !== scale) this.draw();
      if (this.zoomLevel) this.zoomLevel.textContent = `${Math.round(scale * 100)}%`;
    },
    // The one rule the hook owns on #stage: the view, the zoom the counter-scaled rules divide
    // by, and the size the stage claims. Every card is positioned absolutely, so the stage has
    // no size of its own and the layers stretched across it — the frames, the edges — would
    // have none either; the extent the last draw measured is what gives them one.
    writeStyle() {
      const { x, y, scale } = this.view;
      const { width, height } = this.extent;
      if (this.signatures && this.styledScale !== scale) this.markRemeasure();
      this.styledScale = scale;
      this.style.textContent = `#stage{transform:translate(${Math.round(x)}px,${Math.round(y)}px) scale(${scale});--zoom:${scale};min-width:${width}px;min-height:${height}px}`;
    },
    // A view or mode change is a re-measure for the frame it lands in: every height reported
    // through that frame is the same cards measured again rather than a card that grew. The
    // observer delivers after the frame's animation-frame callbacks, and one change reaches it
    // in as many deliveries as the card depths it touches, so the flag is dropped from the frame
    // after the one that raised it — past every delivery of the change, and ahead of the first
    // height a growth of the reader's own could report.
    markRemeasure() {
      this.remeasure = true;
      if (this.remeasureFrame !== null) cancelAnimationFrame(this.remeasureFrame);
      this.remeasureFrame = requestAnimationFrame(() => {
        this.remeasureFrame = requestAnimationFrame(() => {
          this.remeasureFrame = null;
          this.remeasure = false;
        });
      });
    },
    // Back to 1:1 about the centre of the canvas, so whatever you were looking at stays put.
    resetZoom() {
      this.zoomBy(1 / this.view.scale);
    },
    // Space is a page-scroll key as well as the pan modifier, and the class it sets lives on
    // <body>, which the server never renders, so a patch mid-gesture cannot drop it.
    spaceDown(e) {
      if (e.key !== " ") return;
      if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return;
      if (e.target.closest?.("button, a")) return;
      if (document.getElementById("palette")?.dataset.open === "true") return;
      e.preventDefault();
      this.spaceHeld = true;
      document.body.classList.add("grasp-space");
    },
    spaceUp(e) {
      if (e.key !== " ") return;
      this.releaseSpace();
    },
    // Also the teardown for a hold the page never sees the end of, so it is unconditional: a
    // page coming back to the foreground has no key down, and a held Space re-arms on repeat.
    releaseSpace() {
      this.spaceHeld = false;
      document.body.classList.remove("grasp-space");
    },
    // On macOS Ctrl+press is the context-menu gesture, so without this the menu opens over the
    // card the press is dragging, and again on the release that drops it.
    contextMenu(e) {
      if (this.drag?.ctrl || Date.now() - (this.ctrlDragEndedAt || 0) < CTRL_MENU_GRACE) {
        e.preventDefault();
      }
    },
    // A drag ends in a click on whatever was under the pointer, which on a card header is
    // the focus_card binding; that click is the tail of the gesture, not a new one.
    clickCapture(e) {
      if (this.suppressClick) {
        e.stopPropagation();
        e.preventDefault();
        this.suppressClick = false;
        return;
      }
      const card = e.shiftKey && e.target.closest(".card");
      if (card && !e.target.closest("button, a, input, .call, .also, .card__body")) {
        e.stopPropagation();
        e.preventDefault();
        this.pushEvent("toggle_select", { card: card.id.replace("card-", "") });
        return;
      }
      const control = e.target.closest(
        "#zoom-in, #zoom-out, #zoom-fit, #zoom-level, #toggle-signatures, #toggle-modules"
      );
      if (!control) return;
      e.stopPropagation();
      e.preventDefault();
      control.blur();
      if (control.id === "zoom-in") this.zoomBy(1.2);
      else if (control.id === "zoom-out") this.zoomBy(1 / 1.2);
      else if (control.id === "zoom-level") this.resetZoom();
      else if (control.id === "toggle-signatures") this.toggleSignatures();
      else if (control.id === "toggle-modules") this.toggleModules();
      else this.fit();
    },
    // Signature mode. The class lives on <body>, which the server never renders, so a patch
    // cannot drop it; the button carries phx-update="ignore" for the same reason, the state it
    // shows being the hook's. Every card changes size with the mode, so every frame and every
    // edge now ends somewhere else, which only a redraw can say.
    toggleSignatures() {
      this.signatures = !this.signatures;
      this.markRemeasure();
      document.body.classList.toggle("grasp-signatures", this.signatures);
      const button = document.getElementById("toggle-signatures");
      if (button) button.setAttribute("aria-pressed", String(this.signatures));
      this.draw();
    },
    // The module clusters. The class lives on <body> and the button carries phx-update="ignore"
    // for the reasons signature mode does. A card's header shows its module only while the
    // clusters do not, so every card takes a new width with the mode and the heights reported
    // through the frame are the same cards measured again rather than cards that grew.
    toggleModules() {
      this.modules = !this.modules;
      this.markRemeasure();
      document.body.classList.toggle("grasp-modules", this.modules);
      const button = document.getElementById("toggle-modules");
      if (button) button.setAttribute("aria-pressed", String(this.modules));
      this.draw();
    },
    wheel(e) {
      if (e.target.closest?.(".toolbar")) return;
      if (!e.ctrlKey && !e.metaKey && this.scrollableUnder(e)) return;
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) {
        this.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
      } else {
        this.view.x -= e.deltaX;
        this.view.y -= e.deltaY;
        this.applyView();
      }
    },
    // Anything between the cursor and the canvas that can absorb this wheel gesture itself —
    // a code body scrolled sideways, the callers dropdown scrolled down — keeps it, because
    // panning the whole canvas instead would leave that content unreachable. An element that
    // has run out of scroll in this direction absorbs nothing, so the canvas pans instead of
    // the gesture dying against the end of a list.
    scrollableUnder(e) {
      const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY);
      let el = e.target instanceof Element ? e.target : null;
      while (el && el !== this.el) {
        const style = getComputedStyle(el);
        const overflow = horizontal ? style.overflowX : style.overflowY;
        const scrollable = overflow === "auto" || overflow === "scroll";
        if (scrollable && this.canScroll(el, style, horizontal, e)) return true;
        el = el.parentElement;
      }
      return false;
    },
    // A classic scrollbar on the other axis takes space out of the client box without taking
    // it out of the scroll box, so an element that only ever scrolls sideways still reports a
    // scrollHeight one scrollbar taller than its clientHeight. Measuring that gutter and
    // discounting it is what keeps a vertical wheel over a wide code body panning the canvas
    // rather than crawling through 15px of phantom overflow.
    canScroll(el, style, horizontal, e) {
      if (horizontal) {
        const gutter2 = Math.max(
          0,
          el.offsetWidth - el.clientWidth - parseFloat(style.borderLeftWidth) - parseFloat(style.borderRightWidth)
        );
        return e.deltaX > 0 ? el.scrollLeft + el.clientWidth < el.scrollWidth - gutter2 : el.scrollLeft > 0;
      }
      const gutter = Math.max(
        0,
        el.offsetHeight - el.clientHeight - parseFloat(style.borderTopWidth) - parseFloat(style.borderBottomWidth)
      );
      return e.deltaY > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - gutter : el.scrollTop > 0;
    },
    zoomBy(factor) {
      const r = this.el.getBoundingClientRect();
      this.zoomAt(factor, r.left + r.width / 2, r.top + r.height / 2);
    },
    zoomAt(factor, clientX, clientY) {
      const r = this.el.getBoundingClientRect();
      const px = clientX - r.left;
      const py = clientY - r.top;
      const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.view.scale * factor));
      const k = next / this.view.scale;
      this.view = { x: px - (px - this.view.x) * k, y: py - (py - this.view.y) * k, scale: next };
      this.applyView();
    },
    // Brings every card on the canvas into view.
    fit() {
      this.fitPass();
      this.fitPass();
    },
    // One fit against the layout as it stands.
    fitPass() {
      const boxes = Array.from(
        this.el.querySelectorAll(".node:not([data-unplaced]) .card, .frame")
      );
      if (boxes.length === 0) return;
      const box = this.stageBox(boxes);
      if (!(box.width > 0) || !(box.height > 0)) return;
      const r = this.el.getBoundingClientRect();
      const scale = Math.min(
        MAX_SCALE,
        Math.max(
          MIN_SCALE,
          Math.min((r.width - 2 * MARGIN) / box.width, (r.height - 2 * MARGIN) / box.height, 1)
        )
      );
      this.view = { x: MARGIN - box.left * scale, y: MARGIN - box.top * scale, scale };
      this.applyView();
    },
    // Bounding box of elements in unscaled stage coordinates.
    stageBox(elements) {
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
      for (const el of elements) {
        const b = el.getBoundingClientRect();
        left = Math.min(left, (b.left - s.left) / scale);
        top = Math.min(top, (b.top - s.top) / scale);
        right = Math.max(right, (b.right - s.left) / scale);
        bottom = Math.max(bottom, (b.bottom - s.top) / scale);
      }
      return { left, top, right, bottom, width: right - left, height: bottom - top };
    },
    // A double click on an edge travels along it: of the two cards the edge joins, the one
    // further from the pointer is the one out of sight, so that is the card brought into view
    // and given focus. Near either end the gesture is a way to jump to the other.
    doubleClick(e) {
      const edge = e.target.closest?.(".edge");
      if (!edge) return;
      const ends = [edge.dataset.from, edge.dataset.to].map((id) => ({ id, card: document.getElementById(`card-${id}`) })).filter(({ card }) => card);
      if (ends.length === 0) return;
      const distance = ({ card }) => {
        const b = card.getBoundingClientRect();
        return Math.hypot(b.left + b.width / 2 - e.clientX, b.top + b.height / 2 - e.clientY);
      };
      const far = ends.reduce((a, b) => distance(b) > distance(a) ? b : a);
      e.preventDefault();
      this.pushEvent("focus_card", { card: far.id });
      this.revealCard(far.id);
    },
    revealCard(id) {
      if (id == null) return;
      if (this.drag) return;
      const card = document.getElementById(`card-${id}`);
      if (!card) return;
      const marked = card.querySelector('[data-highlight="true"]');
      const markedBox = marked && marked.getBoundingClientRect();
      const target = markedBox && (markedBox.width || markedBox.height) ? marked : card;
      const r = this.el.getBoundingClientRect();
      const b = target.getBoundingClientRect();
      let dx = 0, dy = 0;
      if (b.left < r.left) dx = r.left - b.left + MARGIN;
      else if (b.right > r.right) dx = Math.max(r.right - b.right - MARGIN, r.left - b.left + MARGIN);
      if (b.top < r.top) dy = r.top - b.top + MARGIN;
      else if (b.bottom > r.bottom) dy = Math.max(r.bottom - b.bottom - MARGIN, r.top - b.top + MARGIN);
      if (dx || dy) {
        this.view.x += dx;
        this.view.y += dy;
        this.applyView();
      }
    },
    pointerDown(e) {
      if (e.button !== 0) return;
      this.suppressClick = false;
      if (this.spaceHeld) return this.beginPan(e);
      if (e.shiftKey && e.target.closest(".card")) return e.preventDefault();
      const altCard = e.altKey && e.target.closest(".card");
      if (altCard && !e.target.closest("a")) return this.beginGraphDrag(e, altCard);
      const label = e.target.closest(".module__title");
      if (label) return this.beginModuleDrag(e, label);
      const title = e.target.closest(".flow__title");
      if (title && !e.target.closest("button, a, input")) {
        return this.beginGroupDrag(e, title, e.ctrlKey);
      }
      const ctrlCard = e.ctrlKey && e.target.closest(".card");
      if (ctrlCard) return this.beginCardDrag(e, ctrlCard, true);
      const header = e.target.closest(".card__header");
      if (header && !e.target.closest("button, a, input")) {
        this.beginCardDrag(e, header.closest(".card"), false);
      } else if (!e.target.closest(".card, .toolbar, .chat, button, a, input")) {
        this.beginPan(e);
      }
    },
    // Without the preventDefault the gesture also starts a native text selection, which then
    // smears across every card the pointer crosses.
    beginCardDrag(e, card, ctrl) {
      e.preventDefault();
      document.body.classList.add("grasp-dragging");
      const node = card.closest(".node");
      const position = this.positionOf(node);
      const carried = this.translateOf(node);
      const x = Math.round(position.x + carried.x);
      const y = Math.round(position.y + carried.y);
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
        moved: false
      };
    },
    // Where the server last put a node, in stage pixels from the stage's corner: the node's own
    // custom properties are the position, and the rule in app.css reads them as its left and top.
    // A node with neither is at the origin, which is where an unplaced card is rendered.
    positionOf(node) {
      return {
        x: parseInt(node.style.getPropertyValue("--x"), 10) || 0,
        y: parseInt(node.style.getPropertyValue("--y"), 10) || 0
      };
    },
    // Every card of the group travels by the same displacement, so the cards keep their places
    // relative to one another and the frame the hook draws round them follows from their boxes.
    beginGroupDrag(e, title, ctrl) {
      const flow = title.closest(".flow");
      if (!flow) return;
      e.preventDefault();
      document.body.classList.add("grasp-dragging");
      this.drag = {
        kind: "group",
        ctrl,
        pointerId: e.pointerId,
        group: Number(flow.dataset.group),
        nodes: this.nodesOfGroup(flow.dataset.group),
        startX: e.clientX,
        startY: e.clientY,
        moved: false
      };
    },
    // The cards of a group are anywhere on the stage, so its members are the nodes that name it
    // rather than a section's own subtree, which holds the header and nothing else.
    nodesOfGroup(group) {
      return [...this.el.querySelectorAll(".node")].filter((node) => node.dataset.group === group);
    },
    // Every card of one cluster travels by the same displacement, the way a group's do. A press
    // that gathers nothing begins no drag: the label is drawn from the cards, so a cluster with
    // none is a label nothing is left under.
    beginModuleDrag(e, label) {
      const nodes = this.nodesOfModule(label.dataset.group, label.dataset.module);
      if (!nodes.length) return;
      e.preventDefault();
      document.body.classList.add("grasp-dragging");
      this.drag = {
        kind: "module",
        ctrl: false,
        pointerId: e.pointerId,
        nodes,
        startX: e.clientX,
        startY: e.clientY,
        moved: false
      };
    },
    // The cards of one cluster: a module is clustered per flow, so both the group and the module
    // have to match. A card still waiting for a position has none for a displacement to be added
    // to, and the frame is not drawn round it either.
    nodesOfModule(group, module) {
      return [...this.el.querySelectorAll(".node:not([data-unplaced])")].filter(
        (node) => node.dataset.group === group && node.dataset.module === module
      );
    },
    // Every card connected to the pressed one travels by the same displacement, so a flow keeps
    // its shape while it moves away from the rest. The component is read once, at press time:
    // the cards of a flow do not change while it is being dragged, and rereading it on every
    // move would walk the canvas's call sites hundreds of times over a gesture. A press that
    // gathers nothing is no gesture at all — a card with no position cannot be shifted, so
    // pressing one begins no drag rather than a dead one the release would report.
    beginGraphDrag(e, card) {
      const node = card.closest(".node");
      if (!node) return;
      const nodes = this.connectedNodes(node);
      if (!nodes.length) return;
      e.preventDefault();
      document.body.classList.add("grasp-dragging");
      this.drag = {
        kind: "graph",
        ctrl: false,
        pointerId: e.pointerId,
        nodes,
        startX: e.clientX,
        startY: e.clientY,
        moved: false
      };
    },
    // The nodes reachable from `node` over the edges the canvas draws, the pressed one first.
    // Connection is undirected — a reader shifting a flow means the calls into it as much as the
    // calls out of it — and the edges are the call sites themselves, `[data-edge-to]` naming the
    // card each one points at, so what the gesture carries is what the reader can see joined up.
    // A card still waiting for a position is dropped: it is drawn at the origin and has no
    // position for a displacement to be added to.
    connectedNodes(node) {
      const nodes = /* @__PURE__ */ new Map();
      for (const candidate of this.el.querySelectorAll(".node")) {
        nodes.set(candidate.dataset.card, candidate);
      }
      const neighbours = /* @__PURE__ */ new Map();
      const join = (from, to) => {
        if (!neighbours.has(from)) neighbours.set(from, /* @__PURE__ */ new Set());
        neighbours.get(from).add(to);
      };
      for (const site of this.el.querySelectorAll("[data-edge-to]")) {
        const from = site.closest(".node")?.dataset.card;
        const to = site.dataset.edgeTo;
        if (!from || !to || !nodes.has(to)) continue;
        join(from, to);
        join(to, from);
      }
      const found = [node.dataset.card];
      const seen = new Set(found);
      for (let i = 0; i < found.length; i++) {
        for (const next of neighbours.get(found[i]) || []) {
          if (seen.has(next)) continue;
          seen.add(next);
          found.push(next);
        }
      }
      return found.map((id) => nodes.get(id)).filter((el) => el && !el.hasAttribute("data-unplaced"));
    },
    // Whether a card is still waiting for the position the hook is about to give it.
    unplaced(card) {
      return card.closest(".node")?.hasAttribute("data-unplaced") === true;
    },
    // The group a node belongs to, or null for a node in none. The attribute is always there and
    // empty for a card in no group, which is not group 0.
    groupOf(node) {
      const group = node.dataset.group;
      return group === "" || group === void 0 ? null : Number(group);
    },
    beginPan(e) {
      e.preventDefault();
      document.body.classList.add("grasp-dragging");
      this.drag = {
        kind: "pan",
        pointerId: e.pointerId,
        startX: e.clientX,
        startY: e.clientY,
        x: this.view.x,
        y: this.view.y,
        moved: false
      };
    },
    // The nodes a drag carries: a card drag its one node, a group drag every node of the group, a
    // graph drag every node connected to the pressed one, a module drag every card of the cluster,
    // and a pan none. The translate a drag writes is the displacement alone — a node's position is
    // already its left and top — so every node of a gesture carries the same one.
    dragNodes(drag) {
      if (drag.kind === "card") return [drag.node];
      if (drag.kind === "group" || drag.kind === "graph" || drag.kind === "module") return drag.nodes;
      return [];
    },
    // A second pointer — a touch, a pen, the other half of a pinch — reports its own stream of
    // moves and releases; only the one that started the gesture may drive or end it.
    otherPointer(e) {
      return !this.drag || e.pointerId !== void 0 && e.pointerId !== this.drag.pointerId;
    },
    pointerMove(e) {
      if (this.otherPointer(e)) return;
      if (e.buttons === 0) return this.pointerUp(e);
      const mx = e.clientX - this.drag.startX;
      const my = e.clientY - this.drag.startY;
      if (!this.drag.moved && Math.hypot(mx, my) < DRAG_THRESHOLD) return;
      this.drag.moved = true;
      if (this.drag.kind === "pan") {
        this.view.x = this.drag.x + mx;
        this.view.y = this.drag.y + my;
        this.applyView();
      } else {
        const s = this.view.scale;
        const tx = Math.round(mx / s);
        const ty = Math.round(my / s);
        for (const node of this.dragNodes(this.drag)) {
          node.style.translate = `${tx}px ${ty}px`;
        }
        this.draw();
      }
    },
    endDrag() {
      const drag = this.drag;
      this.drag = null;
      document.body.classList.remove("grasp-dragging");
      if (drag?.moved) this.suppressClick = true;
      if (drag?.ctrl && drag.moved) this.ctrlDragEndedAt = Date.now();
      return drag;
    },
    // The browser took the pointer for a gesture of its own, so the drag is abandoned rather
    // than completed: nothing is pushed, the card goes back to the position the server last
    // rendered, and no click follows a cancel for the suppression to be waiting for.
    pointerCancel(e) {
      if (this.otherPointer(e)) return;
      const drag = this.endDrag();
      this.suppressClick = false;
      const nodes = this.dragNodes(drag);
      if (nodes.length) {
        nodes.forEach((node) => node.style.translate = "");
        this.draw();
      }
    },
    pointerUp(e) {
      if (this.otherPointer(e)) return;
      const drag = this.endDrag();
      if (!drag.moved) return;
      if (drag.kind === "card") {
        const { scale } = this.view;
        const dx = Math.round((e.clientX - drag.startX) / scale);
        const dy = Math.round((e.clientY - drag.startY) / scale);
        drag.node.style.translate = `${dx}px ${dy}px`;
        const group = this.groupUnder(e, drag);
        const move = { card: drag.id, x: drag.x + dx, y: drag.y + dy };
        this.pushEvent("move_card", group === null ? move : { ...move, group });
      } else if (drag.kind === "group") {
        const { scale } = this.view;
        const dx = Math.round((e.clientX - drag.startX) / scale);
        const dy = Math.round((e.clientY - drag.startY) / scale);
        for (const node of drag.nodes) {
          node.style.translate = `${dx}px ${dy}px`;
        }
        this.pushEvent("move_group", { group: drag.group, dx, dy });
      } else if (drag.kind === "graph" || drag.kind === "module") {
        const { scale } = this.view;
        const dx = Math.round((e.clientX - drag.startX) / scale);
        const dy = Math.round((e.clientY - drag.startY) / scale);
        for (const node of drag.nodes) {
          node.style.translate = `${dx}px ${dy}px`;
        }
        this.pushEvent("move_cards", {
          cards: drag.nodes.map((node) => Number(node.dataset.card)),
          dx,
          dy
        });
      }
    },
    // The group whose frame a drop landed in, or null when it landed anywhere else — the
    // ungrouped section, the bare canvas, or the card's own frame, none of which is a change of
    // membership. The frames are rectangles the hook drew itself, so the drop is decided by area
    // alone: a pointer anywhere inside one, padding included, joins that group, whatever element
    // happens to lie under it. A pointer inside two overlapping frames takes the later one, which
    // is the one drawn on top.
    groupUnder(e, drag) {
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      const x = (e.clientX - s.left) / scale;
      const y = (e.clientY - s.top) / scale;
      const own = this.groupOf(drag.node);
      let group = null;
      for (const f of this.frames) {
        if (f.group === own) continue;
        if (x >= f.left && x <= f.right && y >= f.top && y <= f.bottom) group = f.group;
      }
      return group;
    },
    // Frames first: they are measured from the cards, and drawing both from one read of the
    // layout keeps a dragged card's frame and its edges in step through the gesture. The scale
    // is recorded only when there is a layer to draw the frames into, so a draw that finds none
    // leaves the next applyView() to redraw.
    draw() {
      this.measureExtent();
      if (this.drawFrames()) this.drawnScale = this.view.scale;
      this.drawConnectors();
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
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      let right = 0, bottom = 0;
      for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
        const b = node.getBoundingClientRect();
        if (!b.width && !b.height) continue;
        right = Math.max(right, (b.right - s.left) / scale);
        bottom = Math.max(bottom, (b.bottom - s.top) / scale);
      }
      const width = Math.ceil(right + STAGE_PAD);
      const height = Math.ceil(bottom + STAGE_PAD);
      if (width === this.extent.width && height === this.extent.height) return;
      this.extent = { width, height };
      this.writeStyle();
    },
    // One rectangle per grouped section, round the cards wherever they have been dragged to,
    // with the section's header moved to sit above its top-left corner, and inside it one
    // rectangle per module, round the cards of that module with the module's name over them.
    // The rectangles kept in this.frames are the sections' alone, which is what a drop is tested
    // against: a module frame changes no membership. Answers whether it drew.
    drawFrames() {
      if (!this.framesLayer()) return false;
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      const titleGap = FRAME_TITLE_GAP / scale;
      this.frames = [];
      const divs = [];
      const cards = [];
      for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
        const card = node.querySelector(".card");
        const b = card && card.getBoundingClientRect();
        if (!b || !b.width && !b.height) continue;
        cards.push({
          group: node.dataset.group || "",
          module: node.dataset.module || "",
          left: (b.left - s.left) / scale,
          top: (b.top - s.top) / scale,
          right: (b.right - s.left) / scale,
          bottom: (b.bottom - s.top) / scale
        });
      }
      const labelHeight = this.modules ? this.moduleLabelPx() / scale : null;
      const { moduleFrames, extents } = clusterFrames(cards, labelHeight, MODULE_TITLE_GAP / scale);
      const sections = [];
      for (const flow of this.el.querySelectorAll(".flow[data-grouped]")) {
        const title = flow.querySelector(".flow__title");
        const { left, top, right, bottom } = extents.get(flow.dataset.group) || {
          left: Infinity,
          top: Infinity,
          right: -Infinity,
          bottom: -Infinity
        };
        sections.push({
          group: Number(flow.dataset.group),
          title,
          titleBox: title && title.getBoundingClientRect(),
          // The offset the header is already carrying, which its box is measured with.
          carried: title && this.translateOf(title),
          left,
          top,
          right,
          bottom
        });
      }
      for (const { group, title, titleBox, carried, left, top, right, bottom } of sections) {
        if (left === Infinity) {
          if (title) title.style.translate = "";
          continue;
        }
        const headerHeight = title ? titleBox.height / scale : null;
        if (title) {
          const naturalLeft = (titleBox.left - s.left) / scale - carried.x;
          const naturalTop = (titleBox.top - s.top) / scale - carried.y;
          const x = left - naturalLeft;
          const y = top - (headerHeight + titleGap) - naturalTop;
          title.style.translate = `${x}px ${y}px`;
        }
        const frame = {
          group,
          ...frameAround({ left, top, right, bottom }, headerHeight, titleGap, FRAME_PAD)
        };
        this.frames.push(frame);
        divs.push(
          `<div class="frame" data-group="${attr(frame.group)}" style="left:${frame.left}px;top:${frame.top}px;width:${frame.right - frame.left}px;height:${frame.bottom - frame.top}px"></div>`
        );
      }
      for (const frame of moduleFrames) {
        divs.push(
          `<div class="frame frame--module" style="left:${frame.left}px;top:${frame.top}px;width:${frame.right - frame.left}px;height:${frame.bottom - frame.top}px"></div>`,
          `<div class="module__title" data-group="${attr(frame.group)}" data-module="${attr(frame.module)}" style="left:${frame.left + MODULE_PAD}px;top:${frame.top + MODULE_PAD}px">${attr(frame.module)}</div>`
        );
      }
      this.frameLayer.innerHTML = divs.join("");
      return true;
    },
    // The layer the frames and their labels are written into. It lives in a phx-update="ignore"
    // subtree and so normally outlives every patch; were one ever to replace it, a cached node
    // would go on collecting frames nothing renders.
    framesLayer() {
      if (!this.frameLayer?.isConnected) this.frameLayer = this.el.querySelector("#frames");
      return this.frameLayer;
    },
    // The height of a module's label in screen pixels. The label is counter-scaled, so it measures
    // the same on screen at every zoom and one reading answers for all of them; a caller working
    // in stage units divides by the scale it works at. A read that finds no label measures a
    // hidden one of its own, the labels a draw is about to write not being in the document yet.
    moduleLabelPx() {
      if (this.labelPx) return this.labelPx;
      const layer = this.framesLayer();
      if (!layer) return 0;
      let label = layer.querySelector(".module__title");
      let probe = null;
      if (!label) {
        probe = document.createElement("div");
        probe.className = "module__title";
        probe.style.visibility = "hidden";
        probe.textContent = "M";
        label = layer.appendChild(probe);
      }
      const height = label.getBoundingClientRect().height;
      if (probe) probe.remove();
      if (!height) return 0;
      this.labelPx = height;
      return height;
    },
    // The height of a group's header, or null for a group whose section carries none — the two
    // cases `frameAround` reads. A card in no group has no section and no header, and the empty
    // group id names none. The caller says what scale to read the height at, since the scale a
    // measurement belongs to is the caller's business: `scale` 1 answers in screen pixels, which
    // is what the header measures at every zoom because the header is counter-scaled.
    headerHeightOf(group, scale) {
      if (!group) return null;
      const flow = `.flow[data-grouped][data-group="${CSS.escape(group)}"]`;
      const title = this.el.querySelector(`${flow} .flow__title`);
      if (!title) return null;
      return title.getBoundingClientRect().height / scale;
    },
    // The offset the hook last gave an element, in stage units. A property with one value is an
    // x with no y, as the CSS `translate` shorthand defines it, and an empty one is no offset.
    translateOf(el) {
      const [x, y] = (el.style.translate || "").split(" ").filter((v) => v !== "");
      return { x: parseFloat(x) || 0, y: parseFloat(y) || 0 };
    },
    // One path per caller and callee: every open call site names the callee's card in
    // `[data-edge-to]` and its palette slot in `data-color`, and a card that calls the same
    // function from several places is still joined to its card once, in the colour of the first
    // of those calls, so the line and the calls it stands for agree without the hook knowing
    // what the colours are. The path leaves the caller's card rather than the call itself: a
    // card with a dozen open calls has a dozen coloured calls in its body and one line to each
    // card they reach, not a fan of lines across its own code.
    drawConnectors() {
      if (!this.edges?.isConnected) this.edges = this.svg?.querySelector("#edges");
      if (!this.edges) return;
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      const boxes = /* @__PURE__ */ new Map();
      const boxOf = (el) => {
        let box = boxes.get(el);
        if (!box) boxes.set(el, box = el.getBoundingClientRect());
        return box;
      };
      const within = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
      const drawn = /* @__PURE__ */ new Set();
      const paths = [];
      for (const site of this.el.querySelectorAll("[data-edge-to]")) {
        const card = site.closest(".card");
        if (!card) continue;
        const from = card.id.replace("card-", "");
        const to = site.dataset.edgeTo;
        const pair = `${from}|${to}`;
        if (drawn.has(pair)) continue;
        const callee = document.getElementById(`card-${to}`);
        if (!callee) continue;
        if (this.unplaced(card) || this.unplaced(callee)) continue;
        const b = boxOf(callee);
        if (!b.width && !b.height) continue;
        drawn.add(pair);
        const c = boxOf(card);
        const callerLeft = (c.left - s.left) / scale;
        const callerRight = (c.right - s.left) / scale;
        const callerTop = (c.top - s.top) / scale;
        const callerBottom = (c.bottom - s.top) / scale;
        const calleeLeft = (b.left - s.left) / scale;
        const calleeRight = (b.right - s.left) / scale;
        const calleeTop = (b.top - s.top) / scale;
        const calleeBottom = (b.bottom - s.top) / scale;
        const rightward = calleeLeft > callerRight;
        const leftward = calleeRight < callerLeft;
        const below = !rightward && !leftward && calleeTop >= callerBottom;
        const above = !rightward && !leftward && calleeBottom <= callerTop;
        let d;
        if (below || above) {
          const callerInset = Math.min(PORT_Y, (callerRight - callerLeft) / 2);
          const calleeInset = Math.min(PORT_Y, (calleeRight - calleeLeft) / 2);
          const x1 = within(
            (calleeLeft + calleeRight) / 2,
            callerLeft + callerInset,
            callerRight - callerInset
          );
          const y1 = below ? callerBottom : callerTop;
          const x2 = within(x1, calleeLeft + calleeInset, calleeRight - calleeInset);
          const y2 = below ? calleeTop : calleeBottom;
          const mid = (y1 + y2) / 2;
          d = `M ${x1} ${y1} C ${x1} ${mid}, ${x2} ${mid}, ${x2} ${y2}`;
        } else {
          const x1 = rightward ? callerRight : callerLeft;
          const y1 = callerTop + PORT_Y;
          const x2 = rightward ? calleeLeft : calleeRight;
          const y2 = calleeTop + PORT_Y;
          const mid = (x1 + x2) / 2;
          d = `M ${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2} ${y2}`;
        }
        const color = /^[0-7]$/.test(site.dataset.color || "") ? site.dataset.color : null;
        const kind = site.dataset.kind;
        paths.push(
          `<path class="edge" vector-effect="non-scaling-stroke" data-from="${attr(from)}" data-to="${attr(to)}"` + (color === null ? "" : ` data-color="${color}" marker-end="url(#arrow-${color})"`) + (kind ? ` data-kind="${attr(kind)}"` : "") + ` d="${d}" />`
        );
      }
      this.svg.setAttribute("width", String(this.extent.width));
      this.svg.setAttribute("height", String(this.extent.height));
      this.edges.innerHTML = paths.join("");
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
      this.passes++;
      for (const [id] of this.attempted) {
        const node = document.getElementById(`node-${id}`);
        if (!node || !node.hasAttribute("data-unplaced")) this.attempted.delete(id);
      }
      const waiting = [...this.el.querySelectorAll(".node[data-unplaced]")];
      if (waiting.length === 0) return;
      const unplaced = waiting.filter((node) => !this.attempted.has(node.dataset.card));
      for (const node of waiting) {
        const asked = this.attempted.get(node.dataset.card);
        if (!asked || asked.warned || this.passes - asked.pass < 2) continue;
        asked.warned = true;
        console.warn(
          `grasp: the canvas placed card ${node.dataset.card} and the session did not take it; the card stays hidden at the stage's corner`
        );
      }
      if (unplaced.length === 0) return;
      const s = this.stage.getBoundingClientRect();
      const { scale } = this.view;
      const nodes = [...this.el.querySelectorAll(".node")];
      const measured = /* @__PURE__ */ new Map();
      for (const node of nodes) {
        const b = node.getBoundingClientRect();
        measured.set(node, {
          top: (b.top - s.top) / scale,
          width: b.width / scale,
          height: b.height / scale
        });
      }
      const boxes = /* @__PURE__ */ new Map();
      const occupied = [];
      for (const node of nodes) {
        const m = measured.get(node);
        const asked = this.attempted.get(node.dataset.card);
        let box;
        if (!node.hasAttribute("data-unplaced")) {
          const { x, y } = this.positionOf(node);
          box = { left: x, top: y, right: x + m.width, bottom: y + m.height, node };
        } else if (asked) {
          box = { ...asked.box, node };
        } else {
          continue;
        }
        boxes.set(node, box);
        occupied.push(box);
      }
      const sites = [];
      for (const site of this.el.querySelectorAll("[data-edge-to]")) {
        const node = site.closest(".node");
        if (node) sites.push({ site, node, to: site.dataset.edgeTo });
      }
      const headerHeights = /* @__PURE__ */ new Map();
      const headerHeightFor = (group) => {
        if (!headerHeights.has(group)) headerHeights.set(group, this.headerHeightOf(group, 1));
        return headerHeights.get(group);
      };
      const labelHeight = this.modules ? this.moduleLabelPx() : null;
      const moduleHead = labelHeight === null ? 0 : frameHead(labelHeight, MODULE_TITLE_GAP, MODULE_PAD);
      const framesOf = (placed) => {
        const { moduleFrames, extents } = clusterFrames(
          placed.map((b) => ({
            group: b.node.dataset.group || "",
            module: b.node.dataset.module || "",
            left: b.left,
            top: b.top,
            right: b.right,
            bottom: b.bottom
          })),
          labelHeight,
          MODULE_TITLE_GAP
        );
        const frames = [...extents].map(([group, e]) => ({
          group,
          frame: true,
          kind: "flow",
          ...frameAround(e, headerHeightFor(group), FRAME_TITLE_GAP, FRAME_PAD)
        }));
        for (const f of moduleFrames) {
          frames.push({
            group: f.group,
            cluster: `${f.group}|${f.module}`,
            frame: true,
            kind: "module",
            left: f.left,
            top: f.top,
            right: f.right,
            bottom: f.bottom
          });
        }
        return frames;
      };
      let frameBoxes = framesOf(occupied);
      unplaced.sort(
        (a, b) => sortGroup(a) - sortGroup(b) || Number(a.dataset.depth) - Number(b.dataset.depth) || Number(a.dataset.card) - Number(b.dataset.card)
      );
      const placements = [];
      for (const node of unplaced) {
        const m = measured.get(node);
        const id = node.dataset.card;
        const group = node.dataset.group;
        const opener = sites.find(
          (hit) => hit.to === id && hit.node.dataset.group === group && boxes.has(hit.node)
        );
        const calls = !opener && sites.find((hit) => {
          if (hit.node !== node) return false;
          const callee = document.getElementById(`node-${hit.to}`);
          return !!callee && callee.dataset.group === group && boxes.has(callee);
        });
        const head = group ? frameHead(headerHeightFor(group), FRAME_TITLE_GAP, FRAME_PAD) : 0;
        const cluster = labelHeight !== null && node.dataset.module ? `${group || ""}|${node.dataset.module}` : null;
        const home = cluster === null ? null : frameBoxes.find((f) => f.cluster === cluster);
        const foreign = frameBoxes.filter(
          (f) => f.kind === "module" ? f.cluster !== cluster : f.group !== group
        );
        const pad = group ? FRAME_PAD : 0;
        const ownPad = cluster === null ? 0 : MODULE_PAD;
        const ownHead = cluster === null ? 0 : moduleHead;
        const sameSection = (other) => other.group === (group || "");
        const clearance = (other) => {
          if (!other.frame) return GAP_Y;
          return other.kind === "module" ? MODULE_PAD + (sameSection(other) ? 0 : pad) + GAP_Y : pad + ownPad + GAP_Y;
        };
        const headPast = (other) => {
          if (!other.frame) return 0;
          return other.kind === "module" ? moduleHead + (sameSection(other) ? 0 : head) : head + ownHead;
        };
        let x, y;
        if (opener) {
          const box2 = boxes.get(opener.node);
          const a = opener.site.getBoundingClientRect();
          const anchored = a.width > 0 || a.height > 0;
          const line = anchored ? (a.top + a.height / 2 - s.top) / scale - measured.get(opener.node).top : PORT_Y;
          x = box2.right + GAP_X;
          y = box2.top + Math.min(Math.max(line, 0), box2.bottom - box2.top) - PORT_Y;
        } else if (calls) {
          const box2 = boxes.get(document.getElementById(`node-${calls.to}`));
          x = box2.left - m.width - GAP_X;
          y = box2.top;
        } else {
          const peers = occupied.filter((b) => b.node.dataset.group === group);
          if (peers.length > 0) {
            const below = {
              x: Math.min(...peers.map((b) => b.left)),
              y: Math.max(...peers.map((b) => b.bottom)) + GAP_Y
            };
            const beside = {
              x: Math.max(...peers.map((b) => b.right)) + GAP_X,
              y: Math.min(...peers.map((b) => b.top))
            };
            const clearOfFrames = (at2) => !foreign.some(
              (f) => overlaps(
                { left: at2.x, top: at2.y, right: at2.x + m.width, bottom: at2.y + m.height },
                f,
                clearance(f)
              )
            );
            const at = clearOfFrames(below) || !clearOfFrames(beside) ? below : beside;
            x = at.x;
            y = at.y;
          } else {
            const bottoms = occupied.map((b) => b.bottom).concat(frameBoxes.map((f) => f.bottom));
            x = 0;
            y = (bottoms.length === 0 ? 0 : Math.max(...bottoms) + GAP_Y) + head + ownHead;
          }
        }
        const obstacles = occupied.concat(foreign);
        const sweep = (start, direction) => {
          const swept = { ...start };
          for (let pass = 0; pass <= obstacles.length; pass++) {
            let moved = false;
            for (const other of obstacles) {
              if (!overlaps(swept, other, clearance(other))) continue;
              if (direction === "down") {
                swept.top = other.bottom + GAP_Y + headPast(other);
                swept.bottom = swept.top + m.height;
              } else {
                swept.bottom = other.top - clearance(other);
                swept.top = swept.bottom - m.height;
              }
              moved = true;
            }
            if (!moved) break;
          }
          return swept;
        };
        const ideal = { left: x, top: y, right: x + m.width, bottom: y + m.height, node };
        let box;
        if (home && (opener || calls)) {
          const band = Math.max(home.top, Math.min(ideal.top, home.bottom - m.height));
          const spots = [];
          for (const at of [
            { x: home.right + GAP_X, y: band },
            { x: home.left + MODULE_PAD, y: home.bottom - MODULE_PAD + GAP_Y },
            { x: home.left + MODULE_PAD, y: home.top + moduleHead - GAP_Y - m.height },
            { x: home.left - GAP_X - m.width, y: band }
          ]) {
            const from = {
              left: at.x,
              top: at.y,
              right: at.x + m.width,
              bottom: at.y + m.height,
              node
            };
            spots.push([from, "down"], [from, "up"]);
          }
          let nearest = Infinity;
          for (const [from, direction] of spots) {
            const settled = sweep(from, direction);
            const away = Math.hypot(settled.left - ideal.left, settled.top - ideal.top);
            if (away < nearest) {
              nearest = away;
              box = settled;
            }
            if (nearest === 0) break;
          }
        } else if (opener) {
          const over = m.width + GAP_X;
          const next = { ...ideal, left: ideal.left + over, right: ideal.right + over };
          let nearest = Infinity;
          for (const [from, direction] of [
            [ideal, "down"],
            [ideal, "up"],
            [next, "down"],
            [next, "up"]
          ]) {
            const settled = sweep(from, direction);
            const away = Math.hypot(settled.left - ideal.left, settled.top - ideal.top);
            if (away < nearest) {
              nearest = away;
              box = settled;
            }
            if (nearest === 0) break;
          }
        } else {
          box = sweep(ideal, "down");
        }
        const px = Math.round(box.left);
        const py = Math.round(box.top);
        box = { left: px, top: py, right: px + m.width, bottom: py + m.height, node };
        boxes.set(node, box);
        occupied.push(box);
        frameBoxes = framesOf(occupied);
        placements.push({ id: Number(id), x: px, y: py });
        this.attempted.set(id, {
          box: { left: px, top: py, right: box.right, bottom: box.bottom },
          pass: this.passes,
          warned: false
        });
      }
      this.pushEvent("place_cards", { cards: placements });
    },
    // Every card on the canvas is watched for its height, because a card that grows would
    // otherwise come down over whatever stands under it. Observing an element already observed
    // is a no-op, so the cards a patch brought are covered by running this on every patch.
    observeCards() {
      const cards = [...this.el.querySelectorAll(".card")];
      for (const card of cards) this.cardObserver.observe(card);
      const live = new Set(cards.map((card) => cardId(card)));
      for (const id of this.cardHeights.keys()) {
        if (!live.has(id)) this.cardHeights.delete(id);
      }
      for (const id of this.pushes.keys()) {
        if (!live.has(id)) this.pushes.delete(id);
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
      const grown = [];
      const shrunk = [];
      for (const entry of entries) {
        const card = entry.target;
        const id = cardId(card);
        const height = entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height;
        const previous = this.cardHeights.get(id);
        this.cardHeights.set(id, height);
        if (previous === void 0) continue;
        const node = card.closest(".node");
        if (!node || node.hasAttribute("data-unplaced")) continue;
        if (height > previous + 0.5) {
          grown.push({ node, dy: height - previous, top: this.positionOf(node).y });
        } else if (height < previous - 0.5 && this.pushes.get(id)?.length) {
          shrunk.push({ node, shrink: previous - height });
        }
      }
      if (this.remeasure) return;
      if (this.signatures) return;
      if (this.drag) return;
      for (const { node, shrink } of shrunk) this.retract(node, shrink);
      grown.sort((a, b) => a.top - b.top);
      for (const { node, dy } of grown) this.pushBelow(node, dy);
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
      const boxes = this.placedBoxes();
      const grown = boxes.find((b) => b.node === node);
      if (!grown) return;
      const others = boxes.filter((b) => b !== grown);
      const pushed = [];
      const moving = /* @__PURE__ */ new Set();
      for (const b of others) {
        if (b.top >= grown.top && overlaps(grown, b, GAP_Y)) {
          pushed.push(b);
          moving.add(b);
        }
      }
      for (let i = 0; i < pushed.length; i++) {
        const b = pushed[i];
        const shifted = { ...b, top: b.top + dy, bottom: b.bottom + dy };
        for (const c of others) {
          if (moving.has(c)) continue;
          if (c.top >= b.top && overlaps(shifted, c, GAP_Y)) {
            pushed.push(c);
            moving.add(c);
          }
        }
      }
      if (pushed.length === 0) return;
      const shift = Math.round(dy);
      const cards = [];
      const tops = /* @__PURE__ */ new Map();
      for (const b of pushed) {
        const carried = this.translateOf(b.node);
        b.node.style.translate = `${carried.x}px ${carried.y + shift}px`;
        cards.push(b.id);
        tops.set(b.id, b.top + shift);
      }
      this.pushEvent("move_cards", { cards, dx: 0, dy: shift });
      this.draw();
      const stack = this.pushes.get(grown.id) || [];
      stack.push({ dy: shift, cards: tops });
      if (stack.length > PUSH_MEMORY) stack.shift();
      this.pushes.set(grown.id, stack);
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
      const id = Number(node.dataset.card);
      const stack = this.pushes.get(id);
      if (!stack) return;
      let remaining = shrink;
      const returned = /* @__PURE__ */ new Map();
      while (stack.length > 0) {
        const push = stack[stack.length - 1];
        if (push.dy > remaining + 0.5) break;
        const nodes = /* @__PURE__ */ new Map();
        const standing = [...push.cards].every(([card, top]) => {
          const pushed = this.el.querySelector(`.node[data-card="${card}"]:not([data-unplaced])`);
          if (!pushed) return false;
          const given = returned.get(card) || 0;
          const carried = this.translateOf(pushed);
          if (carried.x !== 0 || carried.y !== given) return false;
          if (this.positionOf(pushed).y + given !== top) return false;
          nodes.set(card, pushed);
          return true;
        });
        if (!standing) break;
        stack.pop();
        remaining -= push.dy;
        for (const [card, pushed] of nodes) {
          const given = (returned.get(card) || 0) - push.dy;
          returned.set(card, given);
          pushed.style.translate = `0px ${given}px`;
        }
        this.pushEvent("move_cards", { cards: [...nodes.keys()], dx: 0, dy: -push.dy });
      }
      if (stack.length === 0) this.pushes.delete(id);
      if (returned.size > 0) this.draw();
    },
    // Where every placed card stands, in stage pixels, as a placement pass reads it: the
    // position the server rendered for left and top, and the measured rectangle for width and
    // height, which is a screen measurement and so divided by the scale.
    //
    // A card carrying an inline translate is standing at a move the server has yet to answer
    // for, and is read where it stands: the position plus the displacement, as a drag reads it.
    placedBoxes() {
      const { scale } = this.view;
      const boxes = [];
      for (const node of this.el.querySelectorAll(".node:not([data-unplaced])")) {
        const b = node.getBoundingClientRect();
        const { x, y } = this.positionOf(node);
        const carried = this.translateOf(node);
        const left = x + carried.x;
        const top = y + carried.y;
        boxes.push({
          id: Number(node.dataset.card),
          node,
          left,
          top,
          right: left + b.width / scale,
          bottom: top + b.height / scale
        });
      }
      return boxes;
    }
  };
  function frameHead(headerHeight, titleGap, pad) {
    return headerHeight === null ? pad : headerHeight + titleGap + pad;
  }
  function frameAround(extent, headerHeight, titleGap, pad) {
    return {
      left: extent.left - pad,
      top: extent.top - frameHead(headerHeight, titleGap, pad),
      right: extent.right + pad,
      bottom: extent.bottom + pad
    };
  }
  function clusterFrames(cards, labelHeight, moduleGap) {
    const clusters = /* @__PURE__ */ new Map();
    for (const { group, module, left, top, right, bottom } of cards) {
      const key = `${group}|${module}`;
      const e = clusters.get(key) || {
        group,
        module,
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity
      };
      e.left = Math.min(e.left, left);
      e.top = Math.min(e.top, top);
      e.right = Math.max(e.right, right);
      e.bottom = Math.max(e.bottom, bottom);
      clusters.set(key, e);
    }
    const moduleFrames = [];
    const extents = /* @__PURE__ */ new Map();
    for (const cluster of clusters.values()) {
      const framed = labelHeight !== null && cluster.module !== "";
      const box = framed ? frameAround(cluster, labelHeight, moduleGap, MODULE_PAD) : cluster;
      if (framed) moduleFrames.push({ ...box, group: cluster.group, module: cluster.module });
      if (!cluster.group) continue;
      const e = extents.get(cluster.group) || {
        left: Infinity,
        top: Infinity,
        right: -Infinity,
        bottom: -Infinity
      };
      e.left = Math.min(e.left, box.left);
      e.top = Math.min(e.top, box.top);
      e.right = Math.max(e.right, box.right);
      e.bottom = Math.max(e.bottom, box.bottom);
      extents.set(cluster.group, e);
    }
    return { moduleFrames, extents };
  }
  function sortGroup(node) {
    return node.dataset.group === "" ? Number.MAX_SAFE_INTEGER : Number(node.dataset.group);
  }
  function cardId(card) {
    return Number(card.id.replace("card-", ""));
  }
  function overlaps(a, b, margin) {
    return a.left < b.right + margin && a.right > b.left - margin && a.top < b.bottom + margin && a.bottom > b.top - margin;
  }
  var canvas_default = Canvas;

  // js/hooks/chat.js
  var BOTTOM_PX = 24;
  var HISTORY = 20;
  var COPIED_MS = 1500;
  var MAX_ROWS = 6;
  var Chat = {
    mounted() {
      this.el.addEventListener("submit", () => {
        const input = this.input();
        this.remember(input && input.value);
        this.atBottom = true;
        window.setTimeout(() => {
          const input2 = this.input();
          if (input2) {
            input2.value = "";
            this.grow(input2);
          }
          this.scrollToBottom();
        }, 0);
      });
      this.el.addEventListener("click", (event) => {
        const link = event.target.closest(".msg .fn[data-fn]");
        if (link) this.pushEvent("open_root", { id: link.dataset.fn });
        const copy = event.target.closest(".copy");
        if (copy) this.copy(copy);
        if (event.target.closest("#chat-jump")) {
          this.atBottom = true;
          this.scrollToBottom();
          this.showPill();
        }
      });
      this.el.addEventListener("keydown", (event) => {
        if (event.target.id === "chat-prompt") this.keydown(event);
      });
      this.el.addEventListener("input", (event) => {
        if (event.target.id === "chat-prompt") {
          this.recalled = null;
          this.grow(event.target);
        }
      });
      this.el.addEventListener(
        "scroll",
        (event) => {
          if (event.target.id !== "chat-log") return;
          this.atBottom = this.isAtBottom(event.target);
          this.showPill();
        },
        true
      );
      this.wasOpen = false;
      this.timer = null;
      this.atBottom = true;
      this.history = [];
      this.recalled = null;
      this.at = null;
      this.scrollToBottom();
      this.focusWhenOpened();
      this.fenceButtons();
      this.tick();
    },
    updated() {
      if (this.atBottom) this.scrollToBottom();
      this.showPill();
      this.focusWhenOpened();
      this.fenceButtons();
      this.tick();
    },
    destroyed() {
      this.stopTicking();
    },
    input() {
      return this.el.querySelector("#chat-prompt");
    },
    log() {
      return this.el.querySelector("#chat-log");
    },
    scrollToBottom() {
      const log = this.log();
      if (log) log.scrollTop = log.scrollHeight;
    },
    isAtBottom(log) {
      return log.scrollHeight - log.scrollTop - log.clientHeight <= BOTTOM_PX;
    },
    // The pill offers the way down to a reader who has scrolled away from it. The server
    // renders it hidden, so every patch hides it again and this says whether it stays that
    // way.
    showPill() {
      const pill = this.el.querySelector("#chat-jump");
      if (pill) pill.hidden = this.atBottom;
    },
    // Enter sends, because the box is a prompt before it is a text editor; a line break is
    // the shifted one. ArrowUp on an empty box recalls what was sent last, and pressing it
    // again on a recalled prompt steps further back, so a question can be reworded rather
    // than retyped. A composition in progress owns its own Enter.
    keydown(event) {
      const input = event.target;
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        if (input.form) input.form.requestSubmit();
        return;
      }
      if (event.key === "ArrowUp") {
        const from = this.recallFrom(input.value);
        if (from === null) return;
        event.preventDefault();
        input.value = this.history[from];
        this.recalled = input.value;
        this.at = from;
        this.grow(input);
        input.setSelectionRange(input.value.length, input.value.length);
      }
    },
    recallFrom(value) {
      if (value === "") return this.history.length ? this.history.length - 1 : null;
      if (value === this.recalled && this.at > 0) return this.at - 1;
      return null;
    },
    // A prompt resent as it was recalled is the entry already at the end of the history, and
    // pushing it again would leave ArrowUp stepping over the same words twice.
    remember(prompt) {
      if (!prompt || !prompt.trim()) return;
      if (this.history[this.history.length - 1] !== prompt) {
        this.history = this.history.concat([prompt]).slice(-HISTORY);
      }
      this.recalled = null;
    },
    // The box is one line until what is in it needs more, and stops growing at six so the
    // transcript is never pushed off the panel by a long prompt.
    grow(input) {
      const style = window.getComputedStyle(input);
      const line = parseFloat(style.lineHeight) || 18;
      const around = input.offsetHeight - input.clientHeight + parseFloat(style.paddingBlockStart || 0) + parseFloat(style.paddingBlockEnd || 0);
      input.style.height = "auto";
      input.style.height = `${Math.min(input.scrollHeight, line * MAX_ROWS + around)}px`;
    },
    // What the reader sees, not what the markup says: a rendered answer is Markdown, so its
    // text is read off the DOM. The copy buttons inside it are hidden for the reading, since
    // `innerText` would otherwise hand back their labels as part of the answer.
    copy(button) {
      const target = button.dataset.copy === "pre" ? button.closest("pre") : button.closest(".msg");
      if (!target) return;
      const buttons = Array.from(target.querySelectorAll(".copy"));
      buttons.forEach((each) => each.hidden = true);
      const text = target.innerText;
      buttons.forEach((each) => each.hidden = false);
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(text).then(() => {
        const label = button.textContent;
        button.textContent = "Copied";
        window.setTimeout(() => {
          if (button.isConnected) button.textContent = label;
        }, COPIED_MS);
      });
    },
    // Only fences that have not got a button, and none inside a message still being
    // streamed: the selector is what makes a patch that changed nothing cost no DOM writes,
    // and a partial message's markup is rewritten on every delta, so a button put in it
    // would go with the next one.
    fenceButtons() {
      const fences = `#chat-log .msg:not([data-partial="true"]) pre.fence:not(:has(> button.copy))`;
      this.el.querySelectorAll(fences).forEach((fence) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "copy";
        button.dataset.copy = "pre";
        button.textContent = "Copy";
        fence.prepend(button);
      });
    },
    // Only on the opening patch: later ones land while the user is typing here or reading a
    // card, and taking focus back on each of them would fight whatever they are doing.
    focusWhenOpened() {
      const open = !this.el.hidden;
      if (open && !this.wasOpen) this.input()?.focus();
      this.wasOpen = open;
    },
    tick() {
      const span = this.el.querySelector("[data-elapsed-from]");
      if (!span) return this.stopTicking();
      const from = Number(span.dataset.elapsedFrom);
      if (Number.isFinite(from)) {
        const seconds = Math.max(0, Math.floor((Date.now() - from) / 1e3));
        span.textContent = `${seconds}s`;
      }
      if (!this.timer) this.timer = window.setInterval(() => this.tick(), 1e3);
    },
    stopTicking() {
      if (this.timer) window.clearInterval(this.timer);
      this.timer = null;
    }
  };
  var chat_default = Chat;

  // js/hooks/composer.js
  var Composer = {
    mounted() {
      this.el.querySelector("textarea")?.focus();
      this.el.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
          e.preventDefault();
          e.stopPropagation();
          this.el.requestSubmit();
        } else if (e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          this.pushEvent("comment_cancel", {});
        }
      });
    }
  };
  var composer_default = Composer;

  // js/hooks/gutter.js
  var Gutter = {
    mounted() {
      this.onPointerDown = (e) => this.pointerDown(e);
      this.onPointerMove = (e) => this.pointerMove(e);
      this.onPointerUp = (e) => this.pointerUp(e);
      this.onPointerCancel = (e) => this.pointerCancel(e);
      this.onAbandon = () => this.clearSelection();
      this.onClickCapture = (e) => this.clickCapture(e);
      this.el.addEventListener("pointerdown", this.onPointerDown);
      window.addEventListener("pointermove", this.onPointerMove);
      window.addEventListener("pointerup", this.onPointerUp);
      window.addEventListener("pointercancel", this.onPointerCancel);
      window.addEventListener("blur", this.onAbandon);
      document.addEventListener("visibilitychange", this.onAbandon);
      this.el.addEventListener("click", this.onClickCapture, true);
    },
    // The lines are rendered by the server, so a patch arriving mid-drag has just dropped the
    // marks this gesture put on them.
    updated() {
      if (!this.sel) return;
      this.el.setAttribute("data-selecting", "");
      this.paint();
    },
    destroyed() {
      this.el.removeEventListener("pointerdown", this.onPointerDown);
      window.removeEventListener("pointermove", this.onPointerMove);
      window.removeEventListener("pointerup", this.onPointerUp);
      window.removeEventListener("pointercancel", this.onPointerCancel);
      window.removeEventListener("blur", this.onAbandon);
      document.removeEventListener("visibilitychange", this.onAbandon);
      this.el.removeEventListener("click", this.onClickCapture, true);
    },
    pointerDown(e) {
      if (e.button !== 0 || e.ctrlKey || e.metaKey) return;
      const ln = e.target.closest?.(".ln");
      const anchor = ln && this.lineOf(ln);
      if (!anchor) return;
      e.stopPropagation();
      this.sel = { ...anchor, pointerId: e.pointerId, end: anchor.line };
      this.el.setAttribute("data-selecting", "");
      this.paint();
    },
    pointerMove(e) {
      const sel = this.sel;
      if (!sel || e.pointerId !== void 0 && e.pointerId !== sel.pointerId) return;
      if (e.buttons === 0) return this.clearSelection();
      const line = this.lineAt(e.clientX, e.clientY);
      if (line === null || line === sel.end) return;
      sel.end = line;
      this.paint();
    },
    pointerUp(e) {
      const sel = this.sel;
      if (!sel || e.pointerId !== void 0 && e.pointerId !== sel.pointerId) return;
      this.clearSelection();
      const where = { card: sel.card, side: sel.side };
      if (e.shiftKey) {
        this.push({ ...where, line: sel.end, shift: true });
      } else if (sel.end !== sel.line) {
        this.push({ ...where, line: Math.min(sel.line, sel.end), end_line: Math.max(sel.line, sel.end) });
      }
    },
    pointerCancel(e) {
      if (!this.sel || e.pointerId !== void 0 && e.pointerId !== this.sel.pointerId) return;
      this.clearSelection();
    },
    push(params) {
      this.swallowClick = true;
      setTimeout(() => this.swallowClick = false, 0);
      this.pushEvent("comment_start", params);
    },
    clickCapture(e) {
      if (!this.swallowClick || e.detail === 0) return;
      this.swallowClick = false;
      e.stopPropagation();
      e.preventDefault();
    },
    // The line under a point, or null wherever a range cannot run: outside this body, over a
    // fold, or on the other side of a diff — a range lives on one side, since the two sides
    // number their lines differently.
    lineAt(x, y) {
      const at = document.elementFromPoint(x, y);
      if (!at || !this.el.contains(at)) return null;
      const ln = at.closest(".line")?.querySelector(".ln");
      const found = ln && this.lineOf(ln);
      if (!found || found.side !== this.sel.side) return null;
      return found.line;
    },
    lineOf(ln) {
      const number = ln.getAttribute("phx-value-line");
      const line = Number(number);
      if (!number || !Number.isInteger(line) || line < 1) return null;
      return { card: ln.getAttribute("phx-value-card"), side: ln.getAttribute("phx-value-side"), line };
    },
    // The anchor is tinted from the press onwards, so a range of one line looks like the start
    // of a range rather than like nothing happening.
    paint() {
      const { side, line, end } = this.sel;
      const [first, last] = [Math.min(line, end), Math.max(line, end)];
      for (const ln of this.el.querySelectorAll(".ln")) {
        const row = ln.closest(".line");
        const found = this.lineOf(ln);
        if (!row || !found) continue;
        const inside = found.side === side && found.line >= first && found.line <= last;
        if (inside) row.setAttribute("data-selecting", "");
        else row.removeAttribute("data-selecting");
      }
    },
    clearSelection() {
      this.sel = null;
      this.el.removeAttribute("data-selecting");
      for (const row of this.el.querySelectorAll(".line[data-selecting]")) {
        row.removeAttribute("data-selecting");
      }
    }
  };
  var gutter_default = Gutter;

  // js/hooks/help.js
  var Help = {
    mounted() {
      this.onKeydown = (e) => {
        if (e.key !== "?") return;
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return;
        if (document.getElementById("palette")?.dataset.open === "true") return;
        e.preventDefault();
        this.toggle();
      };
      this.onClickDocument = (e) => {
        const button = e.target.closest?.("#help-toggle");
        if (!button) return;
        e.preventDefault();
        button.blur();
        this.toggle();
      };
      this.onClickDialog = (e) => {
        if (e.target === this.el || e.target.closest?.(".help__close")) this.el.close();
      };
      window.addEventListener("keydown", this.onKeydown);
      document.addEventListener("click", this.onClickDocument);
      this.el.addEventListener("click", this.onClickDialog);
    },
    destroyed() {
      window.removeEventListener("keydown", this.onKeydown);
      document.removeEventListener("click", this.onClickDocument);
      this.el.removeEventListener("click", this.onClickDialog);
    },
    toggle() {
      if (this.el.open) this.el.close();
      else this.el.showModal();
    }
  };
  var help_default = Help;

  // js/app.js
  var { Socket } = window.Phoenix;
  var { LiveSocket } = window.LiveView;
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var socketPath = document.documentElement.getAttribute("phx-socket") || "/live";
  var liveSocket = new LiveSocket(socketPath, Socket, { params: { _csrf_token: csrfToken }, hooks: { Palette: palette_default, Keys: keys_default, Canvas: canvas_default, Chat: chat_default, Composer: composer_default, Gutter: gutter_default, Help: help_default } });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
