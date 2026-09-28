import Config

# The suite exercises the endpoint and the routes it serves, so it runs the standalone form.
config :grasp, standalone: true

config :grasp, GraspWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4041],
  server: false,
  secret_key_base:
    "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-00"

# A host application's endpoint, mounting Grasp under a prefix on a socket path of its own.
config :grasp, GraspWeb.MountedEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4042],
  server: false,
  url: [host: "app.localhost", port: 4042],
  secret_key_base:
    "host-only-secret-key-base-host-only-secret-key-base-host-only-secret-key-base-00",
  live_view: [signing_salt: "host-live-view-salt"],
  pubsub_server: Grasp.PubSub,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: GraspWeb.ErrorHTML], layout: false]

config :grasp, index_path: "test/fixtures/index.json"

# Comments and sessions are kept under the home directory, so the suite gives it a temporary
# one: a test that drops its own override must not write inside the repository.
config :grasp,
  home: Path.join(System.tmp_dir!(), "grasp-test-home-#{System.os_time(:millisecond)}")

# The fixture index names a project root that need not exist, and the suite must never write
# inside the repository: comments go to one temporary file per run.
config :grasp,
  comments_path:
    Path.join(System.tmp_dir!(), "grasp-test-#{System.os_time(:millisecond)}/comments.json")

# Coverage is read from a temporary file of its own, which no test leaves behind: a store
# watching the fixture directory would read whatever a stray run wrote there.
config :grasp,
  coverage_path:
    Path.join(System.tmp_dir!(), "grasp-test-#{System.os_time(:millisecond)}/coverage.json")

# The test results likewise, for the same reason.
config :grasp,
  results_path:
    Path.join(System.tmp_dir!(), "grasp-test-#{System.os_time(:millisecond)}/results.json")

# And the sessions to a temporary directory of their own, one per run.
config :grasp,
  sessions_dir:
    Path.join(System.tmp_dir!(), "grasp-test-sessions-#{System.os_time(:millisecond)}")

# The suite never runs the real CLI: this stand-in prints a canned stream-json run.
config :grasp, agent_command: Path.expand("test/support/fake_claude.sh", __DIR__ <> "/..")

# Nor the real GitHub CLI: this stand-in answers canned pull request JSON.
config :grasp, gh_command: Path.expand("test/support/fake_gh.sh", __DIR__ <> "/..")

# Nor the project's own `mix`: a test or coverage run started from the viewer reaches this
# stand-in, which prints each argument it receives on a line of its own.
config :grasp,
  runs_command: ["sh", "-c", ~S|for arg in "$@"; do printf 'arg %s\n' "$arg"; done|, "fake-mix"]

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
