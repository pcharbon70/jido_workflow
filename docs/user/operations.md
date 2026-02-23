# Operations and Troubleshooting

This guide covers runtime configuration, observability, and common failure modes.

## Runtime Configuration

Global runtime overrides can be defined in:

- `.jido_code/config.json`

Supported keys:

- `workflow_dir`
- `triggers_config_path`
- `trigger_sync_interval_ms`
- `trigger_backend`
- `engine_backend`

`backend` and `workflow_backend` are also accepted aliases in config normalization.

## Backend Selection

Current runtime supports two backends:

- `direct`
  - Executes Runic workflow in-process.
  - Simpler and lower overhead.
- `strategy`
  - Executes through `Jido.Runic.Strategy` and a runtime agent.
  - Supports run control with `runic.set_mode`, `runic.step`, `runic.resume`.

You can set backend:

- Globally via config (`engine_backend`, `trigger_backend`)
- Per run start request (`"backend": "direct"` or `"backend": "strategy"`)

## Observability Signals

Subscribe to these patterns while operating the system:

- `workflow.run.*`
- `workflow.step.*`
- `workflow.definition.*`
- `workflow.registry.*`
- `workflow.trigger.*`

Example:

```elixir
Bus.subscribe(:jido_workflow_bus, "workflow.*", dispatch: {:pid, target: self()})
```

## Registry and Trigger Maintenance

Use these commands after editing workflow or trigger files:

- `workflow.registry.refresh.requested`
- `workflow.trigger.refresh.requested`

Use these for targeted operations:

- `workflow.registry.reload.requested` for one workflow id
- `workflow.trigger.sync.requested` to reconcile trigger processes without registry refresh

## Terminal Run Control

For terminal control workflows without writing raw JSON payloads, use:

```bash
workflow my_flow -value hello
workflow my_flow -backend strategy -await-completion false -timeout 30000 -value hello
```

Pair values are JSON-decoded when possible, so `-count 3`, `-enabled true`,
and `-meta '{"k":"v"}'` become typed workflow inputs.

You can also use Mix wrappers:

```bash
mix workflow.run my_flow --inputs '{"value":"hello"}'
mix workflow.control list --status running --limit 20
mix workflow.control pause <run_id>
mix workflow.control resume <run_id>
mix workflow.control cancel <run_id> --reason "user_requested"
mix workflow.control mode <run_id> --mode step
mix workflow.control step <run_id>
mix workflow.control get <run_id>
mix workflow.control runtime-status
```

These wrappers publish the corresponding `workflow.*.requested` command signals and wait for accepted/rejected responses.

## Common Rejection Reasons

| Reason Fragment | Meaning | Typical Fix |
| --- | --- | --- |
| `missing_or_invalid` | Request payload failed normalization | Check required fields and value types |
| `workflow_not_available` | Workflow missing/disabled/not compiled | Refresh registry and verify definition validity |
| `run_store_unavailable` | Run store process not reachable | Check supervision/runtime health |
| `invalid_transition` | Illegal run status transition | Pause/resume/cancel only when status allows it |
| `unsupported_backend` | Run backend does not support requested operation | Use supported backend or operation |
| `runtime_agent_unavailable` | Strategy runtime agent missing for active control | Verify strategy run initialization and task state |
| `trigger_runtime_unavailable` | Trigger runtime process is not reachable | Verify trigger runtime child is running |

## Run Status Model

Run statuses in `RunStore`:

- `running`
- `paused`
- `completed`
- `failed`
- `cancelled`

`workflow.run.list.requested` supports filtering by:

- `workflow_id` (or `id`)
- `status` (`running`, `paused`, `completed`, `failed`, `cancelled`)
- `limit` (positive integer)

## Hook Runtime Integration

`Jido.Code.Workflow.HookRuntime` subscribes to lifecycle signals and forwards hook payloads to an adapter (`run/2`).

Mapped hook events:

- `before_workflow` <- `workflow.run.started`
- `before_workflow_step` <- `workflow.step.started`
- `after_workflow_step` <- `workflow.step.completed` / `workflow.step.failed`
- `after_workflow` <- `workflow.run.completed` / `workflow.run.failed` / `workflow.run.cancelled`

Default adapter is no-op. Override via application config or runtime configuration.

## Operational Checklist

1. Confirm workflows exist under configured workflow directory.
2. Refresh registry and check accepted summary.
3. Refresh trigger runtime and confirm expected trigger ids.
4. Subscribe to `workflow.run.*` and `workflow.step.*` while testing.
5. Start a direct run and verify completion path.
6. Validate manual and signal trigger paths.
