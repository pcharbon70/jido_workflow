# Command Signal Reference

`Jido.Code.Workflow.CommandRuntime` subscribes to `workflow.*.requested` control signals and emits corresponding response signals.

## Response Convention

For command responses emitted by CommandRuntime:

- Success signals end with `.accepted`
- Failure signals end with `.rejected` (except status requests that are always accepted in normal operation)
- Response payloads include:
  - `requested_signal_id`
  - `requested_signal_type`
  - `requested_signal_source`

## Run Commands

| Request Signal | Required Fields | Optional Fields | Success Signal | Failure Signal |
| --- | --- | --- | --- | --- |
| `workflow.run.start.requested` | `workflow_id` (or `id`) | `run_id`, `backend`, `inputs` (or top-level fields used as inputs) | `workflow.run.start.accepted` | `workflow.run.start.rejected` |
| `workflow.run.pause.requested` | `run_id` | - | `workflow.run.pause.accepted` | `workflow.run.pause.rejected` |
| `workflow.run.step.requested` | `run_id` | - | `workflow.run.step.accepted` | `workflow.run.step.rejected` |
| `workflow.run.mode.requested` | `run_id`, `mode` (`auto` or `step`) | - | `workflow.run.mode.accepted` | `workflow.run.mode.rejected` |
| `workflow.run.resume.requested` | `run_id` | - | `workflow.run.resume.accepted` | `workflow.run.resume.rejected` |
| `workflow.run.cancel.requested` | `run_id` | `reason` | `workflow.run.cancel.accepted` | `workflow.run.cancel.rejected` |
| `workflow.run.get.requested` | `run_id` | - | `workflow.run.get.accepted` | `workflow.run.get.rejected` |
| `workflow.run.list.requested` | - | `workflow_id` (or `id`), `status`, `limit` | `workflow.run.list.accepted` | `workflow.run.list.rejected` |
| `workflow.runtime.status.requested` | - | - | `workflow.runtime.status.accepted` | - |

`workflow.runtime.status.accepted` includes command-runtime health details, including:

- `subscription_count`
- `run_tasks`
- `run_store_summary` (`total_runs`, `by_status`)
- `trigger_runtime_status` (trigger ids, counts, last sync/error snapshot)
- `hook_runtime_status` (when hook runtime is available)

## Definition and Registry Commands

| Request Signal | Required Fields | Optional Fields | Success Signal | Failure Signal |
| --- | --- | --- | --- | --- |
| `workflow.definition.list.requested` | - | `include_disabled`, `include_invalid`, `limit` | `workflow.definition.list.accepted` | `workflow.definition.list.rejected` |
| `workflow.definition.get.requested` | `workflow_id` (or `id`) | - | `workflow.definition.get.accepted` | `workflow.definition.get.rejected` |
| `workflow.registry.refresh.requested` | - | - | `workflow.registry.refresh.accepted` | `workflow.registry.refresh.rejected` |
| `workflow.registry.reload.requested` | `workflow_id` (or `id`) | - | `workflow.registry.reload.accepted` | `workflow.registry.reload.rejected` |

## Trigger Commands

| Request Signal | Required Fields | Optional Fields | Success Signal | Failure Signal |
| --- | --- | --- | --- | --- |
| `workflow.trigger.manual.requested` | `trigger_id` or `command` | `params`, `workflow_id` (for command disambiguation) | `workflow.trigger.manual.accepted` | `workflow.trigger.manual.rejected` |
| `workflow.trigger.refresh.requested` | - | - | `workflow.trigger.refresh.accepted` | `workflow.trigger.refresh.rejected` |
| `workflow.trigger.sync.requested` | - | - | `workflow.trigger.sync.accepted` | `workflow.trigger.sync.rejected` |
| `workflow.trigger.runtime.status.requested` | - | - | `workflow.trigger.runtime.status.accepted` | `workflow.trigger.runtime.status.rejected` |

## Example: Start + Observe a Run

```elixir
alias Jido.Signal
alias Jido.Signal.Bus

bus = :jido_workflow_bus
source = "/terminal"

Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

Bus.publish(bus, [
  Signal.new!(
    "workflow.run.start.requested",
    %{
      "workflow_id" => "code_review_pipeline",
      "inputs" => %{"file_path" => "lib/example.ex"}
    },
    source: source
  )
])

flush()
```

## CLI Shortcuts

The `workflow` executable can route directly to command helper tasks:

- `workflow --control ...` (`mix workflow.control`)
- `workflow --signal ...` (`mix workflow.signal`)
- `workflow --watch ...` (`mix workflow.watch`)
- `workflow --command ...` (`mix workflow.command`)

## Workflow Lifecycle Event Signals

These are emitted by `Jido.Code.Workflow.Broadcaster` during execution:

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
