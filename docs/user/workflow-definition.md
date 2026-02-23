# Workflow Definition Guide

Workflow definitions are markdown files with:

1. YAML frontmatter
2. `## Steps` section
3. Optional `## Error Handling` section
4. Optional `## Return` section

They are parsed by `Jido.Code.Workflow.MarkdownParser`, schema-validated, then normalized by `Jido.Code.Workflow.Validator`.

## File Location

- Default directory: `.jido_code/workflows`
- File extension: `.md`

## Frontmatter Contract

## Required fields

- `name`: snake_case id, pattern `^[a-z][a-z0-9_]*$`
- `version`: semver string, pattern `^\d+\.\d+\.\d+$`

## Common optional fields

- `description`: string
- `enabled`: boolean (default true)
- `inputs`: typed input declarations
- `triggers`: trigger declarations
- `settings`: runtime settings (timeout, retries, failure mode)
- `signals`: publish policy for lifecycle events

## Input declaration

```yaml
inputs:
  - name: file_path
    type: string
    required: true
    description: File path to process
```

Supported input types:

- `string`
- `integer`
- `boolean`
- `map`
- `list`

## Step Sections

Each step is an `###` heading under `## Steps`.

Example:

```markdown
## Steps

### parse_file
- **type**: action
- **module**: MyApp.Actions.ParseFile
- **inputs**:
  - file_path: `input:file_path`
- **outputs**: [ast]
```

## Input/Result reference syntax

- `input:<name>` reads root workflow input
- `result:<step>` reads full result from prior step
- `result:<step>.<path>` reads nested result field

Backticks are optional in parser logic but recommended for readability:

- `input:file_path`
- `result:parse_file.ast`

## Supported step types

## `action`

- Required: `name`, `type: action`, `module`
- Optional: `inputs`, `outputs`, `depends_on`, `async`, `optional`, `timeout_ms`, `max_retries`

## `agent`

- Required: `name`, `type: agent`, `agent`
- Optional: `callback_signal`, `inputs`, `depends_on`, `mode` (`sync` or `async`), `timeout_ms`, `pre_actions`, `post_actions`

## `skill`

- Required: `name`, `type: skill`, `module`
- Optional: same shape as `action`

## `sub_workflow`

- Required: `name`, `type: sub_workflow`, `workflow`
- Optional: `inputs`, `depends_on`, `condition`, `parallel`, `timeout_ms`

## Error Handling Section

Example:

```markdown
## Error Handling

### compensate:ai_step
- **action**: MyApp.Actions.RevertContext
- **inputs**:
  - context_id: `result:ai_step.context_id`
```

For `compensate:*` handlers, `action` is required.

## Return Section

Example:

```markdown
## Return
- **value**: ai_step
- **transform**: |
    fn result ->
      %{summary: result.summary}
    end
```

## Full Template

```markdown
---
name: my_flow
version: "1.0.0"
description: Example flow
enabled: true

inputs:
  - name: value
    type: string
    required: true

triggers:
  - type: manual
    command: "/workflow:my_flow"
  - type: signal
    patterns: ["my_flow.requested"]

settings:
  timeout_ms: 120000
  retry_policy:
    max_retries: 2
    backoff: exponential
    base_delay_ms: 500
  on_failure: compensate

signals:
  topic: "workflow:my_flow"
  publish_events: [step_started, step_completed, step_failed, workflow_complete]
---

# My Flow

## Steps

### first
- **type**: action
- **module**: MyApp.Actions.First
- **inputs**:
  - value: `input:value`
- **outputs**: [out]

### second
- **type**: action
- **module**: MyApp.Actions.Second
- **depends_on**: [first]
- **inputs**:
  - value: `result:first.out`

## Return
- **value**: second
```

## Validation and Error Surfacing

- Workflow files are validated against `priv/schemas/workflow_definition.schema.json`.
- Invalid files remain in the registry as invalid entries (disabled with errors).
- Use registry refresh + definition list commands to audit load health.
