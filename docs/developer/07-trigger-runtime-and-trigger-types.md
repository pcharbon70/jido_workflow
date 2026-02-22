# 07 Trigger Runtime and Trigger Types

## Runtime Roles

- `TriggerRuntime`: refresh+sync orchestrator
- `TriggerManager`: computes desired trigger set
- `TriggerSupervisor`: starts/stops dynamic trigger workers

## Configuration Sources

1. Workflow-local `triggers:` in markdown definitions.
2. Global triggers document (`.jido_code/workflows/triggers.json` by default).

`TriggerManager` merges both sources and enforces uniqueness of trigger ids.

## Sync Model

`TriggerRuntime.refresh/1` performs:

1. registry refresh
2. trigger sync (start missing, stop orphaned)

`TriggerRuntime.sync/1` performs only trigger reconciliation.

Optional periodic sync runs when `sync_interval_ms` is configured.

## Supported Trigger Types

- `manual`
- `signal`
- `scheduled`
- `file_system`
- `git_hook`

Each trigger invokes `Engine.execute/3` and injects trigger metadata into workflow inputs.

## Payload Shapes by Trigger

`manual` adds:

- `trigger_type = "manual"`
- `trigger_id`
- `triggered_at`
- `command` (when configured)

`signal` adds:

- `trigger_type = "signal"`
- `trigger_id`
- `triggered_at`
- `signal_type`, `signal_source`, `signal_id`, `signal_data`

`scheduled` adds:

- `trigger_type = "scheduled"`
- `trigger_id`
- `triggered_at`
- `schedule`
- `scheduled_for`
- configured `params`

`file_system` adds:

- `trigger_type = "file_system"`
- `trigger_id`
- `triggered_at`
- `file_path`
- `events`

`git_hook` adds:

- `trigger_type = "git_hook"`
- `trigger_id`
- `triggered_at`
- `git_event`
- `branch`
- `commit`

## Manual Trigger Lookup

Manual commands can be resolved by:

- explicit `trigger_id`
- `command` plus optional `workflow_id` disambiguation

Ambiguous command matches return an error from `TriggerSupervisor.lookup_manual_by_command/2`.
