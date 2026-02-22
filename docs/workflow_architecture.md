# Workflow Architecture Baseline (Phase 0)

This document locks the initial architecture contracts for implementing markdown-defined workflows with Runic and Jido.

## Core runtime decisions

- DAG runtime: `Runic.Workflow`
- Jido integration: `Jido.Runic.Strategy` and `Jido.Runic.ActionNode`
- Trigger/event backbone: `Jido.Signal.Bus`
- Run control: signal-driven (`runic.feed`, `runic.step`, `runic.resume`, `runic.set_mode`)
- Real-time updates: publish workflow lifecycle signals; UI adapters consume signals

## Module map

- `Jido.Code.Workflow.Definition`
  - Typed workflow contract structs (definition, step, trigger, settings, return)
- `Jido.Code.Workflow.Validator`
  - Contract validation and normalization
- `Jido.Code.Workflow.ValidationError`
  - Path-aware error payload for parser/loader surfaces
- `Jido.Code.Workflow.Registry` (planned)
  - Discovery, caching, reload
- `Jido.Code.Workflow.Compiler` (planned)
  - Normalize -> `Runic.Workflow`
- `Jido.Code.Workflow.Engine` (planned)
  - Execute/pause/resume/cancel orchestration
- `Jido.Code.Workflow.Triggers.*` (planned)
  - File, git, signal, schedule, manual trigger processes

## Signal taxonomy (reserved)

- Commands:
  - `workflow.run.start.requested`
  - `workflow.run.pause.requested`
  - `workflow.run.step.requested`
  - `workflow.run.mode.requested`
  - `workflow.run.resume.requested`
  - `workflow.run.cancel.requested`
  - `workflow.run.get.requested`
  - `workflow.run.list.requested`
  - `workflow.runtime.status.requested`
  - `workflow.definition.list.requested`
  - `workflow.definition.get.requested`
  - `workflow.registry.refresh.requested`
  - `workflow.registry.reload.requested`
  - `workflow.trigger.manual.requested`
  - `workflow.trigger.refresh.requested`
  - `workflow.trigger.sync.requested`
  - `workflow.trigger.runtime.status.requested`
- Runic strategy/control:
  - `runic.feed`
  - `runic.set_workflow`
  - `runic.step`
  - `runic.resume`
  - `runic.set_mode`
- Runtime events:
  - `workflow.step.started`
  - `workflow.step.completed`
  - `workflow.step.failed`
  - `workflow.run.completed`
  - `workflow.run.failed`

## Configuration contracts

- Canonical JSON schemas live under:
  - `priv/schemas/workflow_definition.schema.json`
  - `priv/schemas/triggers.schema.json`
- Internal code should validate to the same constraints and return `ValidationError` structs with `path`, `code`, and `message`.
