# Trigger Guide

Triggers are how workflows start automatically or on demand.

The current runtime supports:

- `manual`
- `signal`
- `scheduled`
- `file_system`
- `git_hook`

## Two Trigger Sources

## 1) Workflow-local triggers (in markdown frontmatter)

Defined in each workflow file under `triggers:`.

```yaml
triggers:
  - type: signal
    patterns: ["code.review.requested"]
  - type: manual
    command: "/workflow:review"
```

## 2) Global trigger config file

Default location: `.jido_code/workflows/triggers.json`

Validated by: `priv/schemas/triggers.schema.json`

Example:

```json
{
  "global_settings": {
    "default_debounce_ms": 500,
    "max_concurrent_triggers": 10
  },
  "triggers": [
    {
      "id": "review-signal-1",
      "workflow_id": "code_review_pipeline",
      "type": "signal",
      "enabled": true,
      "config": {
        "patterns": ["code.review.requested"]
      }
    }
  ]
}
```

## Trigger Runtime Lifecycle

Trigger processes are synchronized by `Jido.Code.Workflow.TriggerRuntime`.

Use command signals:

- `workflow.trigger.refresh.requested`: refresh workflow registry + sync triggers
- `workflow.trigger.sync.requested`: sync trigger processes only
- `workflow.trigger.runtime.status.requested`: inspect trigger runtime status

## Trigger Payloads Injected into Workflow Inputs

Every trigger enriches workflow inputs with trigger metadata.

## `manual`

- `trigger_type`: `"manual"`
- `trigger_id`
- `triggered_at`
- `command` (when available)

## `signal`

- `trigger_type`: `"signal"`
- `trigger_id`
- `triggered_at`
- `signal_type`
- `signal_source`
- `signal_id`
- `signal_data`

## `scheduled`

- `trigger_type`: `"scheduled"`
- `trigger_id`
- `triggered_at`
- `schedule`
- `scheduled_for`
- plus configured `params`

## `file_system`

- `trigger_type`: `"file_system"`
- `trigger_id`
- `triggered_at`
- `file_path`
- `events` (sorted list)

## `git_hook`

- `trigger_type`: `"git_hook"`
- `trigger_id`
- `triggered_at`
- `git_event`
- `branch`
- `commit`

## Manual Trigger Invocation via Command Runtime

You can trigger manual workflows without knowing trigger internals:

```elixir
request.("workflow.trigger.manual.requested", %{
  "command" => "/workflow:review",
  "params" => %{"file_path" => "lib/example.ex"}
})
```

or by explicit trigger id:

```elixir
request.("workflow.trigger.manual.requested", %{
  "trigger_id" => "code_review_pipeline:manual:0",
  "params" => %{"file_path" => "lib/example.ex"}
})
```

## Notes on Sync Behavior

- Disabled global trigger entries (`"enabled": false`) are ignored.
- Trigger ids must be unique across workflow-defined and global trigger configs.
- `max_concurrent_triggers` limits how many desired triggers are activated.
- Existing orphaned trigger processes are stopped during sync.
