defmodule Grasp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gfrancischelli/grasp"

  def project do
    [
      app: :grasp,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_load_filters: [&(String.ends_with?(&1, "_test.exs") and not fixture?(&1))],
      test_ignore_filters: [&fixture?/1],
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps(),
      description: "Grasp: call-chain code review for Elixir, mounted in your app",
      package: package(),
      name: "Grasp",
      docs: docs()
    ]
  end

  def application do
    [mod: {Grasp.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  def cli do
    [preferred_envs: [test: :test, "test.all": :test]]
  end

  defp fixture?(path), do: String.starts_with?(path, "test/fixtures/")

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.12", optional: true},
      {:jason, "~> 1.4"},
      {:lumis, "~> 0.8"},
      {:mdex, "~> 0.13"},
      {:lazy_html, ">= 0.1.0"},
      {:anubis_mcp, "~> 2.0"},
      {:sourceror, "~> 1.10"},
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      "assets.build": ["esbuild grasp"],
      "assets.deploy": ["esbuild grasp --minify"],
      "test.all": ["test --include integration"]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/static priv/test_trace.exs guides mix.exs .formatter.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "main",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/reviewing.md",
        "guides/pull-requests.md",
        "guides/agent.md",
        "guides/indexing.md",
        "guides/contributing.md"
      ],
      groups_for_extras: [Guides: ~r"guides/"],
      groups_for_modules: [
        Indexer: ~r/Grasp\.Index/,
        Viewer: ~r/GraspWeb/,
        MCP: ~r/Grasp\.MCP/,
        Agent: ~r/Grasp\.Agent/,
        "Mix tasks": ~r/Mix\.Tasks/
      ]
    ]
  end
end
