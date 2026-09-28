// Phoenix and LiveView are not bundled: GraspWeb.Assets puts the host application's own
// copies of them in front of this file, and they define these two globals. Bundling them
// would ship a client that may not speak the LiveView the host runs.
import "../css/app.css"
import Palette from "./hooks/palette"
import Keys from "./hooks/keys"
import Canvas from "./hooks/canvas"
import Chat from "./hooks/chat"
import Composer from "./hooks/composer"
import Gutter from "./hooks/gutter"
import Help from "./hooks/help"
import Runs from "./hooks/runs"

const {Socket} = window.Phoenix
const {LiveSocket} = window.LiveView

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// The socket belongs to the host's endpoint, so its path is whatever the host declared;
// the layout writes it onto <html> because only the server knows it.
const socketPath = document.documentElement.getAttribute("phx-socket") || "/live"
const liveSocket = new LiveSocket(socketPath, Socket, {params: {_csrf_token: csrfToken}, hooks: {Palette, Keys, Canvas, Chat, Composer, Gutter, Help, Runs}})

liveSocket.connect()
window.liveSocket = liveSocket
