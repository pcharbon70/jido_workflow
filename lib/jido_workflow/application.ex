defmodule JidoWorkflow.Application do
  @moduledoc false

  use Application

  @signal_bus Application.compile_env(:jido_workflow, :signal_bus, :jido_workflow_bus)

  @impl true
  def start(_type, _args) do
    children = [
      {Jido.Signal.Bus, name: @signal_bus}
    ]

    opts = [strategy: :one_for_one, name: JidoWorkflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
