// The vim walk shares the map with the arrows, so `h` `j` `k` `l` push exactly what
// ← ↓ ↑ → push. Only the bare lowercase letter is a direction: a Shift-modified letter
// arrives uppercase and matches nothing here.
const DIRECTIONS = {
  ArrowLeft: "parent",
  ArrowRight: "child",
  ArrowUp: "prev",
  ArrowDown: "next",
  h: "parent",
  l: "child",
  k: "prev",
  j: "next",
}

const Keys = {
  mounted() {
    this.onKeydown = (e) => {
      // A dialog over the canvas has the keyboard: neither the palette's search nor the
      // list of shortcuts is aimed at the cards underneath it.
      if (document.getElementById("palette")?.dataset.open === "true") return
      if (document.getElementById("help")?.open) return

      // The toolbar advertises Cmd+I as a toggle, so it has to reach the prompt it just
      // focused; every other chord stays out of a field the user is typing in.
      const chatToggle = (e.metaKey || e.ctrlKey) && e.key === "i"
      if (["INPUT", "TEXTAREA"].includes(e.target.tagName) && !chatToggle) return

      // Cmd+= and Cmd+- stay with the browser; only the two chords the canvas claims are taken.
      if (e.metaKey || e.ctrlKey) {
        // Cmd+M is the macOS "minimise window" shortcut and a browser may act on it before the
        // page ever sees the key, so Cmd+\ is the fallback that always gets through.
        if (e.key === "m" || e.key === "\\") {
          e.preventDefault()
          this.pushEvent("toggle_sidebar", {})
        } else if (e.key === "i") {
          e.preventDefault()
          this.pushEvent("chat_toggle", {})
        } else if (e.key === "0") {
          e.preventDefault()
          // The zoom lives entirely in the Canvas hook, so this is hook to hook through the DOM
          // rather than a round trip to the server.
          window.dispatchEvent(new CustomEvent("grasp:zoom-reset"))
        } else if (e.key.toLowerCase() === "g") {
          // ⌘G is the browser's own find-next, which would otherwise run on top of the frame
          // this just made. Shift is what separates the pair, not the case of the key.
          e.preventDefault()
          this.pushEvent(e.shiftKey ? "ungroup_selected" : "group_selected", {})
        }
        return
      }
      if (e.altKey) return

      if (DIRECTIONS[e.key]) {
        e.preventDefault()
        this.pushEvent("move_focus", {dir: DIRECTIONS[e.key]})
      } else if (e.key.toLowerCase() === "x") {
        // Shift is what separates the two, not the case of the key: CapsLock also sends "X",
        // and closing the whole chain is the one of the pair that cannot be undone.
        this.pushEvent(e.shiftKey ? "close_focused_chain" : "close_focused", {})
      } else if (e.key === "c") {
        this.pushEvent("collapse_focused", {})
      } else if (e.key === "d") {
        this.pushEvent("toggle_view_focused", {})
      } else if (e.key === "z") {
        // `z` is the fold key in vim, and folding the unchanged lines away is what the
        // toggle does.
        this.pushEvent("toggle_context_focused", {})
      } else if (e.key.toLowerCase() === "s") {
        // Signature mode is the Canvas hook's, so this is hook to hook through the DOM rather
        // than a round trip to the server.
        window.dispatchEvent(new CustomEvent("grasp:toggle-signatures"))
      } else if (e.key.toLowerCase() === "v") {
        // Coverage mode is the Canvas hook's, like signature mode.
        window.dispatchEvent(new CustomEvent("grasp:toggle-coverage"))
      } else if (e.key.toLowerCase() === "m") {
        // The module frames are the Canvas hook's, like signature mode. The bare letter alone:
        // ⌘M is the sidebar, and it has already returned above.
        window.dispatchEvent(new CustomEvent("grasp:toggle-modules"))
      } else if (e.key.toLowerCase() === "t") {
        // The arrows from the test suite's cards are the Canvas hook's, like the module frames.
        window.dispatchEvent(new CustomEvent("grasp:toggle-test-edges"))
      } else if (e.key.toLowerCase() === "b") {
        // The arrows crossing the frames' borders are drawn by the Canvas hook as well.
        window.dispatchEvent(new CustomEvent("grasp:toggle-cross-frame-edges"))
      } else if (e.key.toLowerCase() === "f") {
        // The fit is the Canvas hook's too: it measures the cards the browser has laid out,
        // which the server cannot see.
        window.dispatchEvent(new CustomEvent("grasp:zoom-fit"))
      } else if (e.key === "Escape") {
        // The palette and any field have already returned above, so Escape here is aimed at
        // the canvas and means the cards picked out on it are let go.
        this.pushEvent("clear_selection", {})
      }
    }
    window.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
}

export default Keys
