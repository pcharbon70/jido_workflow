---
name: code_review_pipeline
version: "1.0.0"
description: Automated code review workflow with AI agents
enabled: true

inputs:
  - name: file_path
    type: string
    required: true
    description: Path to file being reviewed
  - name: diff_content
    type: string
    required: false
    description: Git diff content if available

triggers:
  - type: signal
    patterns: ["code.review.requested"]
  - type: manual
    command: "/workflow:review"

settings:
  max_concurrency: 4
  timeout_ms: 300000
  retry_policy:
    max_retries: 3
    backoff: exponential
    base_delay_ms: 1000
  on_failure: compensate

channel:
  topic: "workflow:code_review"
  broadcast_events: [step_started, step_completed, step_failed, workflow_complete]
---

# Code Review Pipeline

Automated code review combining static analysis with AI-powered suggestions.

## Steps

### parse_file
- **type**: action
- **module**: JidoCode.Actions.ParseElixirFile
- **inputs**:
  - file_path: `input:file_path`
- **outputs**: [ast, module_info, functions]
- **async**: true

### ai_code_review
- **type**: agent
- **agent**: code_reviewer
- **pre_actions**:
  - module: JidoCode.Actions.PrepareContext
    inputs:
      ast: `result:parse_file.ast`
- **inputs**:
  - code: `input:file_path`
  - ast: `result:parse_file.ast`
- **depends_on**: [parse_file]
- **mode**: sync
- **timeout_ms**: 60000

### apply_fixes
- **type**: sub_workflow
- **workflow**: auto_fix_pipeline
- **inputs**:
  - suggestions: `result:ai_code_review.suggestions`
  - file_path: `input:file_path`
- **depends_on**: [ai_code_review]
- **condition**: `result:ai_code_review.has_auto_fixable`

## Error Handling

### compensate:ai_code_review
- **action**: JidoCode.Actions.RevertContext
- **inputs**:
  - context_id: `result:ai_code_review.context_id`

## Return
- **value**: ai_code_review
- **transform**: |
    fn result ->
      %{summary: result.summary}
    end
