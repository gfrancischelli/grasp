import Config

config :grasp, GraspWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: GraspWeb.ErrorHTML], layout: false],
  pubsub_server: Grasp.PubSub,
  live_view: [signing_salt: "grasp-live-view-salt"]

config :grasp,
  standalone: false,
  index_path: nil,
  home: nil,
  comments_path: nil,
  coverage_path: nil,
  results_path: nil,
  sessions_dir: nil,
  editor: nil,
  agent_command: "claude",
  agent_model: nil,
  gh_command: "gh"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
