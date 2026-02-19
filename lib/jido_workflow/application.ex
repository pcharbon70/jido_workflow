defmodule JidoWorkflow.Application do
  @moduledoc false

  use Application

  require Logger

  alias JidoWorkflow.Workflow.GlobalConfig

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

  @engine_backend Application.compile_env(
                    :jido_workflow,
                    :engine_backend,
                    nil
                  )

  @workflow_config_path Application.compile_env(
                          :jido_workflow,
                          :workflow_config_path,
                          ".jido_code/config.json"
                        )

  @triggers_config_path Application.compile_env(
                          :jido_workflow,
                          :triggers_config_path,
                          nil
                        )

  @impl true
  def start(_type, _args) do
    runtime_overrides = load_runtime_overrides()

    workflow_dir = Map.get(runtime_overrides, :workflow_dir, @workflow_dir)

    trigger_sync_interval_ms =
      Map.get(runtime_overrides, :trigger_sync_interval_ms, @trigger_sync_interval_ms)

    trigger_backend = Map.get(runtime_overrides, :trigger_backend)
    engine_backend = Map.get(runtime_overrides, :engine_backend, @engine_backend)

    triggers_config_path =
      Map.get_lazy(runtime_overrides, :triggers_config_path, fn ->
        @triggers_config_path || Path.join(workflow_dir, "triggers.json")
      end)

    children = [
      {Jido.Signal.Bus, name: @signal_bus},
      {Registry, keys: :unique, name: @trigger_process_registry},
      {JidoWorkflow.Workflow.TriggerSupervisor, name: @trigger_supervisor},
      {JidoWorkflow.Workflow.Registry, name: @workflow_registry, workflow_dir: workflow_dir},
      {@run_store, name: @run_store},
      {@command_runtime,
       name: @command_runtime,
       bus: @signal_bus,
       workflow_registry: @workflow_registry,
       run_store: @run_store,
       backend: engine_backend},
      {@hook_runtime, name: @hook_runtime, bus: @signal_bus, adapter: @workflow_hook_adapter},
      {JidoWorkflow.Workflow.TriggerRuntime,
       name: @trigger_runtime,
       workflow_registry: @workflow_registry,
       trigger_supervisor: @trigger_supervisor,
       process_registry: @trigger_process_registry,
       bus: @signal_bus,
       triggers_config_path: triggers_config_path,
       sync_interval_ms: trigger_sync_interval_ms,
       backend: trigger_backend}
    ]

    opts = [strategy: :one_for_one, name: JidoWorkflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp load_runtime_overrides do
    case GlobalConfig.load_file(@workflow_config_path) do
      {:ok, overrides} ->
        overrides

      {:error, errors} ->
        Logger.warning(
          "Failed to load workflow config #{@workflow_config_path}: #{inspect(errors)}"
        )

        %{}
    end
  end
end
