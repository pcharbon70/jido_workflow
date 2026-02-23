# Jido.Code.Workflow User Guides

These guides describe how to use the current workflow architecture implemented in this repository.

The runtime is signal-native and centered on:

- Markdown workflow definitions (`.md`) discovered by `Jido.Code.Workflow.Registry`
- DAG execution through Runic (`Runic.Workflow`) and Jido Runic integration (`Jido.Runic.Strategy` / `Jido.Runic.ActionNode`)
- Pub/sub orchestration through `Jido.Signal.Bus` (no Phoenix Channels required)
- Command and control through `workflow.*.requested` signals handled by `Jido.Code.Workflow.CommandRuntime`

## Guide Index

- [Getting Started](./getting-started.md)
- [CLI Command Guide](./cli-commands.md)
- [Workflow Definition Guide](./workflow-definition.md)
- [Trigger Guide](./triggers.md)
- [Command Signal Reference](./command-signals.md)
- [Operations and Troubleshooting](./operations.md)

## Quick Runtime Defaults

- Signal bus: `:jido_workflow_bus`
- Workflow directory: `.jido_code/workflows`
- Global workflow config file: `.jido_code/config.json`
- Global trigger config file: `.jido_code/workflows/triggers.json` (default resolution)

## Lifecycle at a Glance

1. Write/update workflow markdown files in `.jido_code/workflows`.
2. Refresh the registry with `workflow.registry.refresh.requested`.
3. Start runs directly (`workflow.run.start.requested`) or via triggers.
4. Observe lifecycle events on `workflow.run.*` and `workflow.step.*`.
5. Control active runs with pause/step/mode/resume/cancel commands.
