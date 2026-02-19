defmodule JidoWorkflow.Application do
  @moduledoc false

  use Application

  @signal_bus Application.compile_env(:jido_workflow, :signal_bus, :jido_workflow_bus)
  @workflow_registry Application.compile_env(
                       :jido_workflow,
                       :workflow_registry,
                       JidoWorkflow.Workflow.Registry
                     )

  @workflow_dir Application.compile_env(:jido_workflow, :workflow_dir, ".jido_code/workflows")
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

  @trigger_runtime Application.compile_env(
                     :jido_workflow,
                     :trigger_runtime,
                     JidoWorkflow.Workflow.TriggerRuntime
                   )

  @run_store Application.compile_env(
               :jido_workflow,
               :run_store,
               JidoWorkflow.Workflow.RunStore
             )

  @command_runtime Application.compile_env(
                     :jido_workflow,
                     :command_runtime,
                     JidoWorkflow.Workflow.CommandRuntime
                   )

  @hook_runtime Application.compile_env(
                  :jido_workflow,
                  :hook_runtime,
                  JidoWorkflow.Workflow.HookRuntime
                )

  @workflow_hook_adapter Application.compile_env(
                           :jido_workflow,
                           :workflow_hook_adapter,
                           JidoWorkflow.Workflow.Hooks.NoopAdapter
                         )

  @trigger_sync_interval_ms Application.compile_env(
                              :jido_workflow,
                              :trigger_sync_interval_ms,
                              nil
                            )

  @impl true
  def start(_type, _args) do
    children = [
      {Jido.Signal.Bus, name: @signal_bus},
      {Registry, keys: :unique, name: @trigger_process_registry},
      {JidoWorkflow.Workflow.TriggerSupervisor, name: @trigger_supervisor},
      {JidoWorkflow.Workflow.Registry, name: @workflow_registry, workflow_dir: @workflow_dir},
      {@run_store, name: @run_store},
      {@command_runtime,
       name: @command_runtime,
       bus: @signal_bus,
       workflow_registry: @workflow_registry,
       run_store: @run_store},
      {@hook_runtime, name: @hook_runtime, bus: @signal_bus, adapter: @workflow_hook_adapter},
      {JidoWorkflow.Workflow.TriggerRuntime,
       name: @trigger_runtime,
       workflow_registry: @workflow_registry,
       trigger_supervisor: @trigger_supervisor,
       process_registry: @trigger_process_registry,
       bus: @signal_bus,
       sync_interval_ms: @trigger_sync_interval_ms}
    ]

    opts = [strategy: :one_for_one, name: JidoWorkflow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
