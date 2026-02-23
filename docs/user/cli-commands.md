# CLI Command Guide

This guide is the command-line reference for running and operating workflows from a terminal.

## 1. Build the Executable

```bash
mix escript.build
```

This produces `./workflow`.

## 2. Start a Workflow Run

Use positional workflow id syntax:

```bash
workflow <workflow-id> -option-name option-value [-option-name option-value ...]
```

Examples:

```bash
workflow code_review -file_path lib/example.ex -mode full
workflow release_validation -target_branch main -commit_sha abc123
workflow code_review -backend strategy -await-completion false -timeout 45000 -file_path lib/example.ex
```

Rules:

- First argument is always the workflow id.
- All following arguments must be `-option-name option-value` pairs.
- Non-reserved pairs become workflow `inputs`.
- Input values are JSON-decoded when possible (`true`, `3`, `9.5`, `{...}`, `[...]`).

Reserved run options (forwarded to `mix workflow.run`):

- `-run-id`
- `-backend` (`direct` or `strategy`)
- `-source`
- `-bus`
- `-timeout`
- `-start-app` (`true|false` or `1|0`)
- `-await-completion` (`true|false` or `1|0`)
- `-pretty` (`true|false` or `1|0`)

## 3. Control Active Runs

Use task routing via `workflow --control ...`:

```bash
workflow --control list --status running --limit 20
workflow --control get <run_id>
workflow --control pause <run_id>
workflow --control resume <run_id>
workflow --control mode <run_id> --mode step
workflow --control step <run_id>
workflow --control cancel <run_id> --reason "user_requested"
workflow --control runtime-status
```

## 4. Publish Command Signals Directly

```bash
workflow --signal workflow.registry.refresh.requested --data '{}'
workflow --signal workflow.run.start.requested --data '{"workflow_id":"my_flow","inputs":{"value":"hello"}}'
```

## 5. Watch Runtime Signals

```bash
workflow --watch
workflow --watch --pattern workflow.run.* --pattern workflow.step.* --limit 20
workflow --watch --timeout 30000
```

## 6. Trigger Manual Commands

```bash
workflow --command /workflow:review --workflow-id code_review
workflow --command /workflow:review --params '{"file_path":"lib/example.ex"}'
```

## 7. Mix Task Equivalents

Every `workflow --...` mode maps to an existing Mix task:

- `workflow <workflow-id> ...` -> `mix workflow.run <workflow-id> ...`
- `workflow --control ...` -> `mix workflow.control ...`
- `workflow --signal ...` -> `mix workflow.signal ...`
- `workflow --watch ...` -> `mix workflow.watch ...`
- `workflow --command ...` -> `mix workflow.command ...`
