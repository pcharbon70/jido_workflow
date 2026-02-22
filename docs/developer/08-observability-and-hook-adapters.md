# 08 Observability and Hook Adapters

## Lifecycle Signal Emission

`JidoWorkflow.Workflow.Broadcaster` is the central publisher for execution events.

Primary signal types:

- `workflow.run.started`
- `workflow.run.completed`
- `workflow.run.failed`
- `workflow.run.paused`
- `workflow.run.resumed`
- `workflow.run.cancelled`
- `workflow.step.started`
- `workflow.step.completed`
- `workflow.step.failed`
- `workflow.agent.state`

These signals are emitted on `Jido.Signal.Bus` and should be treated as the observability contract.

## Hook Runtime

`JidoWorkflow.Workflow.HookRuntime` subscribes to selected lifecycle signals and forwards them into hook callbacks through `HooksIntegration`.

Signal to hook mapping currently includes:

- `workflow.run.started` -> `:before_workflow`
- `workflow.step.started` -> `:before_workflow_step`
- `workflow.step.completed` -> `:after_workflow_step`
- `workflow.step.failed` -> `:after_workflow_step`
- `workflow.run.completed` -> `:after_workflow`
- `workflow.run.failed` -> `:after_workflow`
- `workflow.run.cancelled` -> `:after_workflow`

## Adapter Contract

Hook adapter module requirements:

- module must be loadable
- must export `run/2`
- should return `:ok`, `{:ok, term()}`, or `{:error, reason}`

Unexpected returns and exceptions are logged as warnings and swallowed to protect workflow runtime continuity.

## Default Adapter

If no adapter is configured, `JidoWorkflow.Workflow.Hooks.NoopAdapter` is used.
