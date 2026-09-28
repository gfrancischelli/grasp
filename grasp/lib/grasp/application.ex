defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of Grasp: PubSub, the index store, the coverage store, the review
  comments store, the session and agent registries and supervisors, the MCP server the
  `/mcp` route forwards to, and — only when standalone — the viewer's own endpoint.

  The review comments and the saved sessions are the reader's own, so they are kept under
  the directory Grasp started in rather than under the project root the index names — a
  pull request reviewed from a worktree writes its threads beside the checkout the reader
  opened, and they outlive that worktree. `home/0` is that directory.

  The MCP server starts explicitly rather than following the endpoint, so it also runs
  under `mix test` and inside a host application, where Grasp serves no endpoint of its
  own. It starts before the endpoint, so `/mcp` is never routable ahead of the server that
  answers it.

  Grasp is a development dependency: everything it does — reading the project's source,
  running an agent in the working tree, writing `.grasp/` — assumes a checkout and a Mix
  project. A release has neither, so when Mix is not running the tree starts empty and
  says why.

  The endpoint belongs to the standalone viewer, `mix grasp.viewer`. A host mounts Grasp
  in its own router instead, so `config :grasp, standalone: false` — the default — leaves
  the host's endpoint the only one serving. `Grasp.Reindexer` is the mirror image: it
  follows the compiles a host's code reloader performs, and standalone Grasp has no host
  compiling anything.
  """

  use Application

  require Logger

  # Highlighting loads a grammar on demand, so without this the first card of a session pays
  # for the download. Elixir is what cards are written in; the rest are what Lumis injects
  # into an Elixir document — a ~H sigil, an embedded stylesheet or script.
  @languages ["elixir", "heex", "html", "css", "javascript"]

  @impl true
  def start(_type, _args) do
    mix? = mix_running?()
    if mix?, do: Lumis.Languages.async_load(@languages)
    record_home()

    mix?
    |> children(standalone?())
    |> Supervisor.start_link(strategy: :one_for_one, name: Grasp.Supervisor)
  end

  @doc """
  The directory Grasp keeps the reader's own files under, in a `.grasp/` inside it.

  It is `:grasp, :home` when that is set and the working directory Grasp started in
  otherwise, recorded at start so a later `File.cd/1` cannot move the comments file or the
  sessions directory out from under a running viewer. Nil before Grasp has started, which
  the stores read as: keep everything in memory.
  """
  @spec home() :: Path.t() | nil
  def home, do: Application.get_env(:grasp, :home)

  @doc """
  The processes Grasp starts, given whether Mix is running and whether it serves its own
  endpoint.

  Without Mix there is nothing to review, so the list is empty and a warning says so.
  Standalone adds the viewer's endpoint; mounted in a host, `Grasp.Reindexer` takes its
  place and rides the host's code reloader.
  """
  @spec children(boolean(), boolean()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def children(false, _standalone?) do
    Logger.warning(
      "grasp: Mix is not running, so Grasp did not start. Use it as a dev dependency."
    )

    []
  end

  def children(true, standalone?) do
    core = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      {Grasp.IndexStore, []},
      {Grasp.CoverageStore, []},
      {Grasp.Comments, []},
      {Registry, keys: :unique, name: Grasp.SessionRegistry},
      {DynamicSupervisor, name: Grasp.SessionSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Grasp.AgentRegistry},
      {DynamicSupervisor, name: Grasp.AgentSupervisor, strategy: :one_for_one},
      {Grasp.MCP.Server, transport: {:streamable_http, start: true}}
    ]

    if standalone?, do: core ++ [GraspWeb.Endpoint], else: core ++ [{Grasp.Reindexer, []}]
  end

  # The flag is read once, at start; a configuration reload that flipped it afterwards would
  # otherwise send a config change to an endpoint that was never started. What is running
  # answers that without depending on the flag holding still.
  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(GraspWeb.Endpoint), do: GraspWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A host starts its dev server from its project root, which is the checkout the reader is
  # reviewing from and the one their comments belong to.
  defp record_home do
    if is_nil(Application.get_env(:grasp, :home)) do
      Application.put_env(:grasp, :home, File.cwd!())
    end
  end

  defp mix_running?, do: not is_nil(Application.spec(:mix, :vsn))

  defp standalone?, do: Application.get_env(:grasp, :standalone, false)
end
