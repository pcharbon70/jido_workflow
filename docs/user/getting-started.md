# Getting Started

This guide walks through the shortest path to run workflows in the current architecture.

## 1. Start the Runtime

Use an interactive Elixir shell so you can publish and inspect signals:

```bash
iex -S mix
```

Inside `iex`:

```elixir
alias Jido.Signal
alias Jido.Signal.Bus

bus = :jido_workflow_bus
source = "/terminal"

request = fn type, data ->
  Bus.publish(bus, [Signal.new!(type, data, source: source)])
end
```

## 2. Create a Workflow File

Place workflow markdown files under `.jido_code/workflows`.

Example file: `.jido_code/workflows/sample_flow.md`

```markdown
---
name: sample_flow
version: "1.0.0"
description: Minimal sample workflow
enabled: true

inputs:
  - name: value
    type: string
    required: true

triggers:
  - type: manual
    command: "/workflow:sample"
  - type: signal
    patterns: ["sample.requested"]
---

# Sample Flow

## Steps

### echo
- **type**: action
- **module**: MyApp.Workflow.Actions.Echo
- **inputs**:
  - value: `input:value`
- **outputs**: [echo]
```

Replace `MyApp.Workflow.Actions.Echo` with an action module available in your app/runtime.

## 3. Refresh the Registry

```elixir
Bus.subscribe(bus, "workflow.registry.refresh.*", dispatch: {:pid, target: self()})
```

```elixir
request.("workflow.registry.refresh.requested", %{})
```

Inspect response signals:

```elixir
flush()
```

## 4. Verify Definitions

```elixir
Bus.subscribe(bus, "workflow.definition.list.*", dispatch: {:pid, target: self()})
request.("workflow.definition.list.requested", %{
  "include_disabled" => false,
  "include_invalid" => false
})
flush()
```

## 5. Start a Run Directly

```elixir
Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

request.("workflow.run.start.requested", %{
  "workflow_id" => "sample_flow",
  "inputs" => %{"value" => "hello"}
})

flush()
```

You should see:

- `workflow.run.start.accepted`
- `workflow.run.started`
- `workflow.run.completed` (or `workflow.run.failed`)

## 6. Trigger by Command

If you defined a manual trigger command, you can invoke it with:

```elixir
Bus.subscribe(bus, "workflow.trigger.manual.*", dispatch: {:pid, target: self()})

request.("workflow.trigger.manual.requested", %{
  "command" => "/workflow:sample",
  "params" => %{"value" => "from_command"}
})

flush()
```

`workflow.trigger.manual.accepted` includes `trigger_id`, `workflow_id`, `run_id`, and status.

## 7. Trigger by Incoming Signal

For a `signal` trigger pattern, publish the matching signal:

```elixir
request.("sample.requested", %{"value" => "from_signal_trigger"})
```

The trigger runtime will start a workflow run when the pattern matches.

## 8. Start a Run from CLI

Outside `iex`, you can start runs with the project CLI:

```bash
workflow sample_flow -value hello
```

The first argument is the workflow id. Remaining pairs are
mapped into workflow inputs (JSON-decoded when possible).

You can also route directly to terminal control/watch tasks:

```bash
workflow --control runtime-status
workflow --control list --status running --limit 20
workflow --watch --limit 10
```
