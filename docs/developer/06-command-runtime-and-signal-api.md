# 06 Command Runtime and Signal API

## Purpose

`Jido.Code.Workflow.CommandRuntime` is the public control plane for workflow operations.

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

## Runtime Status Payload

`workflow.runtime.status.accepted` returns command-runtime wiring and health fields, including:

- bus + runtime process references
- command subscription diagnostics (`subscription_count`, `command_signal_types`, `subscribed_command_signal_types`, `missing_command_signal_types`)
- tracked in-flight `run_tasks`
- `workflow_registry_summary` (`total_workflows`, `enabled_workflows`, `disabled_workflows`, `valid_workflows`, `invalid_workflows`, `total_error_count`, `invalid_workflow_ids`, `disabled_workflow_ids`)
- `run_store_summary` (`total_runs`, `by_status`, `workflow_counts`, `active_runs`, `active_run_ids`, `latest_run_id`, `latest_run_status`, `latest_workflow_id`)
- `trigger_runtime_status` (active trigger ids/counts and last sync snapshot)
- `hook_runtime_status` (`subscription_count`, `supported_signal_types`, `subscribed_signal_types`, `missing_signal_types`, plus adapter/bus metadata)
- component error fields (`workflow_registry_error`, `run_store_error`, `trigger_runtime_error`, `hook_runtime_error`)

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

{:ok, _run_sub} = Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})
{:ok, _start_sub} = Bus.subscribe(bus, "workflow.run.start.*", dispatch: {:pid, target: self()})

Bus.publish(bus, [
  Signal.new!("workflow.run.start.requested", %{
    "workflow_id" => "my_flow",
    "inputs" => %{"file_path" => "lib/foo.ex"}
  }, source: "/terminal")
])
```

No websocket or channel transport is required for command/control.

## CLI Helper Commands

Build/install the project CLI once:

```bash
mix do escript.build + escript.install
```

Then use `workflow` directly:

```bash
workflow my_flow -file_path lib/foo.ex -mode full
workflow review_flow -repo_path /tmp/repo -pr_number 42
workflow review_flow -backend strategy -await-completion false -timeout 30000 -repo_path /tmp/repo
workflow --control list --status running --limit 20
workflow --signal workflow.registry.refresh.requested --data '{}'
workflow --watch --pattern workflow.run.* --limit 20
workflow --command /workflow:review --workflow-id code_review --params '{"value":"hello"}'
```

`workflow` defaults to `mix workflow.run` when the first argument is a workflow id.
In run mode, every subsequent argument must be an input pair in
`-option-name option-value` form.
Option names are normalized to lowercase snake_case keys in the `inputs` map,
except reserved run options that are forwarded directly to `mix workflow.run`:

- `run_id`
- `backend`
- `source`
- `bus`
- `timeout`
- `start_app`
- `await_completion`
- `pretty`

Non-reserved input values are JSON-decoded when possible (booleans, numbers,
objects, arrays, `null`); values that do not decode are passed as strings.

For non-run operations, these task-routing flags are available:

- `workflow --control ...` -> `mix workflow.control ...`
- `workflow --signal ...` -> `mix workflow.signal ...`
- `workflow --watch ...` -> `mix workflow.watch ...`
- `workflow --command ...` -> `mix workflow.command ...`

For terminal usage outside IEx, use:

```bash
mix workflow.signal workflow.run.start.requested \
  --data '{"workflow_id":"my_flow","inputs":{"file_path":"lib/foo.ex"}}'
```

The task publishes the request signal and, by default, waits for the matching
`*.accepted` or `*.rejected` response.

For a higher-level run convenience wrapper, use:

```bash
mix workflow.run my_flow --inputs '{"value":"hello"}'
```

`mix workflow.run` starts `workflow.run.start.requested` and can optionally wait
for terminal lifecycle completion (`workflow.run.completed|failed|cancelled`).

For run control operations from terminal, use:

```bash
mix workflow.control pause <run_id>
mix workflow.control resume <run_id>
mix workflow.control cancel <run_id> --reason "user_requested"
mix workflow.control step <run_id>
mix workflow.control mode <run_id> --mode step
mix workflow.control get <run_id>
mix workflow.control list --workflow-id my_flow --status running --limit 20
mix workflow.control runtime-status
```

For manual slash-command trigger operations from terminal, use:

```bash
mix workflow.command /workflow:review --workflow-id code_review --params '{"value":"hello"}'
```

This wrapper publishes `workflow.trigger.manual.requested` with the command,
optional workflow disambiguation, and optional params payload.
