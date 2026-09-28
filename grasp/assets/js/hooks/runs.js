// The run's output is server state, streamed a line at a time, so the hook only does what a
// render cannot: keep the log pinned to the newest line while the reader is at the bottom
// of it, and offer the way back down when they are not, as the chat log does.
//
// A stream insert patches the log's children rather than the panel, so the lines arriving
// are watched on the log itself; the scroll position is the reader's, so it is read off the
// log each time rather than remembered across patches that may have replaced it.
const BOTTOM_PX = 24

const Runs = {
  mounted() {
    this.atBottom = true

    this.el.addEventListener("click", (event) => {
      if (event.target.closest("#runs-jump")) {
        this.atBottom = true
        this.scrollToBottom()
        this.showPill()
      }
    })

    // A scroll event does not bubble, so it is caught on the way down instead.
    this.el.addEventListener(
      "scroll",
      (event) => {
        if (event.target.id !== "runs-log") return
        this.atBottom = this.isAtBottom(event.target)
        this.showPill()
      },
      true,
    )

    this.observer = new MutationObserver(() => this.follow())
    this.observe()
    this.scrollToBottom()
  },

  updated() {
    this.observe()
    this.follow()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  // The log a later patch put in place of the one watched is watched instead.
  observe() {
    const log = this.log()
    if (!log || log === this.watched) return
    this.observer.disconnect()
    this.observer.observe(log, { childList: true })
    this.watched = log
  },

  follow() {
    if (this.atBottom) this.scrollToBottom()
    this.showPill()
  },

  log() {
    return this.el.querySelector("#runs-log")
  },

  scrollToBottom() {
    const log = this.log()
    if (log) log.scrollTop = log.scrollHeight
  },

  isAtBottom(log) {
    return log.scrollHeight - log.scrollTop - log.clientHeight <= BOTTOM_PX
  },

  // The server renders the pill hidden, so every patch hides it again and this says whether
  // it stays that way.
  showPill() {
    const pill = this.el.querySelector("#runs-jump")
    if (pill) pill.hidden = this.atBottom
  },
}

export default Runs
