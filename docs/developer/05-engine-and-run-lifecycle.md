# 05 Engine and Run Lifecycle

## Backends

`JidoWorkflow.Workflow.Engine` supports two backends:

- `:direct` (default): `Runic.Workflow.react_until_satisfied/3`
- `:strategy`: `Jido.Runic.Strategy` through `RuntimeAgent`

## Execution Entry Points

- `execute/3` by workflow id from registry
- `execute_definition/3` from in-memory definition
- `execute_compiled/3` from compiled bundle

## Input Contract Enforcement

Before run execution, `InputContract.normalize_inputs/2` validates and fills defaults.

On input errors:

- run may be recorded failed in `RunStore`
- `workflow.run.failed` is broadcast
- execution returns `{:error, {:invalid_inputs, errors}}`

## Run Lifecycle Storage

`RunStore` tracks:

- `run_id`, `workflow_id`, `status`, `backend`
- inputs, start/finish timestamps
- result or error

Supported statuses:

- `:running`
- `:paused`
- `:completed`
- `:failed`
- `:cancelled`

## Control Operations

Engine APIs used by command runtime:

- `pause/2`
- `resume/2`
- `cancel/3`
- `get_run/2`
- `list_runs/1`

For strategy backend, step/mode/resume actions send `runic.*` signals to the runtime agent and then update run state.

## Broadcast Events

Engine emits lifecycle events through `Broadcaster`:

- `workflow.run.started|completed|failed|paused|resumed|cancelled`
- `workflow.step.started|completed|failed`
- `workflow.agent.state`
