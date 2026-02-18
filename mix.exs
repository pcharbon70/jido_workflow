defmodule JidoWorkflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_workflow,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:jido_runic, github: "agentjido/jido_runic"}
    ]
  end
end
