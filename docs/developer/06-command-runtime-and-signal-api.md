# 06 Command Runtime and Signal API

## Purpose

`JidoWorkflow.Workflow.CommandRuntime` is the public control plane for workflow operations.

It subscribes to `workflow.*.requested` signals and emits response signals.

## Response Pattern

- success: `*.accepted`
- failure: `*.rejected`
- response metadata always includes:
  - `requested_signal_id`
  - `requested_signal_type`
  - `requested_signal_source`

## Supported Request Signals

Run control:

- `workflow.run.start.requested`
- `workflow.run.pause.requested`
- `workflow.run.step.requested`
- `workflow.run.mode.requested`
- `workflow.run.resume.requested`
- `workflow.run.cancel.requested`
- `workflow.run.get.requested`
- `workflow.run.list.requested`
- `workflow.runtime.status.requested`

Definitions and registry:

- `workflow.definition.list.requested`
- `workflow.definition.get.requested`
- `workflow.registry.refresh.requested`
- `workflow.registry.reload.requested`

Triggers:

- `workflow.trigger.manual.requested`
- `workflow.trigger.refresh.requested`
- `workflow.trigger.sync.requested`
- `workflow.trigger.runtime.status.requested`

## Start Request Shape

Accepted `workflow.run.start.requested` fields:

- required: `workflow_id` (or `id`)
- optional: `run_id`, `backend`, `inputs`
- compatibility: top-level extra fields can be used as inputs

## Terminal Integration Pattern

A terminal process can act as a command client by publishing request signals and subscribing to response/lifecycle patterns on the bus.

```elixir
alias Jido.Signal
alias Jido.Signal.Bus

bus = :jido_workflow_bus

{:ok, _sub} = Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

Bus.publish(bus, [
  Signal.new!("workflow.run.start.requested", %{
    "workflow_id" => "my_flow",
    "inputs" => %{"file_path" => "lib/foo.ex"}
  }, source: "/terminal")
])
```

No websocket or channel transport is required for command/control.
