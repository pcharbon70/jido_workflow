defmodule Jido.Code.Workflow.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/pcharbon70/jido_workflow"
  @description "Workflow runtime and CLI for DAG-based Jido code workflows."

  def project do
    [
      app: :jido_workflow,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: escript(),
      name: "Jido.Code.Workflow",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
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
      extra_applications: [:logger, :mix],
      mod: {Jido.Code.Workflow.Application, []}
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.0"},
      {:jido_runic, github: "agentjido/jido_runic"},
      {:file_system, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["test", "credo --strict", "dialyzer"]
    ]
  end

  defp escript do
    [
      main_module: Jido.Code.Workflow.CLI,
      name: "workflow",
      app: nil
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "priv/schemas",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      maintainers: ["Pascal Charbon"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "Jido.Code.Workflow",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "docs/user/README.md",
        "docs/developer/README.md"
      ],
      skip_undefined_reference_warnings_on: [
        "docs/user/README.md",
        "docs/developer/README.md"
      ]
    ]
  end
end
