// The draft is the browser's. The textarea is `phx-update="ignore"`, so what is being typed
// survives every patch without a round trip, and the hook adds only the two keys a plain
// textarea has not got: save and cancel.
//
// The listener is on the form rather than on the textarea, so a patch that replaces the
// textarea keeps the behaviour. Both keys are stopped where they are handled: the default
// action and the bubble to the window, so neither ever reaches the global key handlers.
const Composer = {
  mounted() {
    // A box that rewrites a comment opens holding its text, and the caret goes after it, where
    // a reader adding to what they wrote starts typing.
    const textarea = this.el.querySelector("textarea")
    if (textarea) {
      textarea.focus()
      textarea.setSelectionRange(textarea.value.length, textarea.value.length)
    }

    this.el.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        e.stopPropagation()
        this.el.requestSubmit()
      } else if (e.key === "Escape") {
        e.preventDefault()
        e.stopPropagation()
        this.pushEvent("comment_cancel", {})
      }
    })
  },
}

export default Composer
