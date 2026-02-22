# Developer Guides

This directory contains implementation-oriented guides for contributors working on `jido_workflow` internals.

The runtime is signal-native and uses `Jido.Signal.Bus` for orchestration. Phoenix Channels are not part of the execution architecture.

## Numbered Guide Index

1. [01 System Overview](./01-system-overview.md)
2. [02 Supervision and Runtime Topology](./02-supervision-and-runtime-topology.md)
3. [03 Definition Loading and Registry](./03-definition-loading-and-registry.md)
4. [04 Compilation and Step Execution](./04-compilation-and-step-execution.md)
5. [05 Engine and Run Lifecycle](./05-engine-and-run-lifecycle.md)
6. [06 Command Runtime and Signal API](./06-command-runtime-and-signal-api.md)
7. [07 Trigger Runtime and Trigger Types](./07-trigger-runtime-and-trigger-types.md)
8. [08 Observability and Hook Adapters](./08-observability-and-hook-adapters.md)
9. [09 Extensibility and Plugin Types](./09-extensibility-and-plugin-types.md)
10. [10 Development Workflow and Quality Gates](./10-development-workflow-and-quality-gates.md)
