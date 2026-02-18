defmodule JidoWorkflow.Application do
  @moduledoc false

  use Application

  @signal_bus Application.compile_env(:jido_workflow, :signal_bus, :jido_workflow_bus)
  @trigger_process_registry Application.compile_env(
                              :jido_workflow,
                              :trigger_process_registry,
                              JidoWorkflow.Workflow.TriggerProcessRegistry
                            )

  @trigger_supervisor Application.compile_env(
                        :jido_workflow,
                        :trigger_supervisor,
                        JidoWorkflow.Workflow.TriggerSupervisor
                      )

  @impl true
  def start(_type, _args) do
    children = [
      {Jido.Signal.Bus, name: @signal_bus},
      {Registry, keys: :unique, name: @trigger_process_registry},
      {JidoWorkflow.Workflow.TriggerSupervisor, name: @trigger_supervisor}
    ]

    opts = [strategy: :one_for_one, name: JidoWorkflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
