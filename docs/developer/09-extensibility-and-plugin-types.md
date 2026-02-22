# 09 Extensibility and Plugin Types

## Extension Surface

`Jido.Code.Workflow.PluginExtensions` provides registration APIs for custom workflow types.

- `register_step_type/2`
- `unregister_step_type/1`
- `register_trigger_type/2`
- `unregister_trigger_type/1`

## Step Type Registry

`StepTypeRegistry` built-ins are reserved:

- `action`
- `agent`
- `skill`
- `sub_workflow`

Custom step types:

- must use a non-empty type name
- must not conflict with built-ins
- must map to a module

When compiler resolves a custom step type, it delegates component building to the registered module.

## Trigger Type Registry

`TriggerTypeRegistry` built-ins are reserved:

- `file_system`
- `git_hook`
- `scheduled`
- `signal`
- `manual`

Custom trigger types:

- must register a module implementing a trigger worker process contract compatible with `TriggerSupervisor.start_trigger/2`
- should register in process registry using trigger id semantics used by built-ins

## Configuration Storage

Custom type registrations are stored in application env keys:

- step types: `:workflow_step_types`
- trigger types: `:workflow_trigger_types`

Because this is runtime env state, extensions should be initialized in application startup code for deterministic behavior.
