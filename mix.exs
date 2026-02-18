defmodule JidoWorkflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_workflow,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        quality: :dev,
        credo: :dev,
        dialyzer: :dev
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {JidoWorkflow.Application, []}
    ]
  end

  defp deps do
    [
      {:jido, github: "agentjido/jido", override: true},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true},
      {:libgraph, github: "zblanco/libgraph", branch: "zw/multigraph-indexes", override: true},
      {:jido_runic, github: "agentjido/jido_runic"},
      {:yaml_elixir, "~> 2.12"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["test", "credo --strict", "dialyzer"]
    ]
  end
end
