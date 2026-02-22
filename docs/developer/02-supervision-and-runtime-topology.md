# 02 Supervision and Runtime Topology

## Boot Order

`Jido.Code.Workflow.Application` starts these children under `Jido.Code.Workflow.Supervisor` (`:one_for_one`):

1. `Jido.Signal.Bus`
2. trigger process `Registry`
3. `Jido.Code.Workflow.TriggerSupervisor`
4. `Jido.Code.Workflow.Registry`
5. `Jido.Code.Workflow.RunStore`
6. `Jido.Code.Workflow.CommandRuntime`
7. `Jido.Code.Workflow.HookRuntime`
8. `Jido.Code.Workflow.TriggerRuntime`

## Runtime Defaults

- `signal_bus`: `:jido_workflow_bus`
- `workflow_dir`: `.jido_code/workflows`
- `workflow_config_path`: `.jido_code/config.json`
- `triggers_config_path`: defaults to `Path.join(workflow_dir, "triggers.json")`

## Runtime Overrides

`Jido.Code.Workflow.GlobalConfig.load_file/1` can override runtime settings at boot. Supported override patterns include:

- workflow directory
- trigger backend and sync interval
- engine backend
- explicit triggers config path

## Process Roles

- `CommandRuntime` owns command subscriptions and run task process tracking.
- `TriggerRuntime` owns periodic refresh/sync orchestration.
- `TriggerSupervisor` owns dynamic trigger workers.
- `HookRuntime` subscribes to lifecycle events and forwards them to adapter hooks.

## Operational Notes

- If `TriggerRuntime` is configured with `sync_interval_ms`, periodic refresh+sync is scheduled.
- `CommandRuntime` tracks strategy runtime agent pids for step/mode/resume control signals.
- All cross-component coordination is bus/process based, not websocket/channel based.
