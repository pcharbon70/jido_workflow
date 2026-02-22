# 01 System Overview

## Goal

`jido_workflow` provides markdown-defined DAG workflows executed by Runic through `jido_runic`, with signal-driven orchestration and control.

## Core Principles

- Workflow definitions are code-like contracts loaded from markdown (`.jido_code/workflows/*.md`).
- Execution is DAG-based (`Runic.Workflow`) with Jido integration (`Jido.Runic.ActionNode`, `Jido.Runic.Strategy`).
- Runtime control and observability are done through `Jido.Signal.Bus` topics (`workflow.*`, `runic.*`).
- No Phoenix Channel dependency exists in the runtime path.

## Major Runtime Components

- `Jido.Code.Workflow.Application`: Boots bus, registry, command runtime, trigger runtime, run store, and hook runtime.
- `Jido.Code.Workflow.Registry`: Discovers, parses, validates, compiles, and caches workflow definitions.
- `Jido.Code.Workflow.CommandRuntime`: Handles `workflow.*.requested` control signals and emits accepted/rejected responses.
- `Jido.Code.Workflow.Engine`: Executes compiled workflows through `:direct` or `:strategy` backends.
- `Jido.Code.Workflow.TriggerRuntime`: Reconciles desired triggers against active trigger processes.
- `Jido.Code.Workflow.RunStore`: Tracks run state and lifecycle transitions.
- `Jido.Code.Workflow.Broadcaster`: Emits lifecycle signals (`workflow.run.*`, `workflow.step.*`, `workflow.agent.state`).

## High-Level Flow

1. A workflow markdown file is parsed and validated.
2. The validated definition is compiled into a Runic workflow bundle.
3. A command signal or trigger starts execution.
4. The engine runs the DAG and updates `RunStore`.
5. Lifecycle signals are published and optional hooks are invoked.
