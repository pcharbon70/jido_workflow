# 04 Compilation and Step Execution

## Compiler Output

`Jido.Code.Workflow.Compiler.compile/1` emits a bundle:

- `workflow` (`Runic.Workflow`)
- `input_schema`
- `return`
- `signals`
- `error_handling`
- `settings`
- `metadata`

## Compile-Time Safety Checks

Before DAG creation, compiler enforces:

- unique step names
- dependency existence
- no self-dependency
- dependency acyclicity via topological sort

## Step Type Resolution

Step types are resolved through `StepTypeRegistry`.

Built-ins:

- `action`
- `agent`
- `skill`
- `sub_workflow`

Any non-builtin type must be a registered custom module.

## Built-in Step Adapters

- `Actions.ExecuteActionStep`
- `Actions.ExecuteAgentStep`
- `Actions.ExecuteSkillStep`
- `Actions.ExecuteSubWorkflowStep`

Compiler wraps each step as `Jido.Runic.ActionNode` and wires dependencies into Runic edges.

## Runtime Input Resolution

`ArgumentResolver` resolves step input expressions against runtime state:

- `input:<name>` from root inputs
- `result:<step>` from prior step result
- `result:<step>.<path>` nested lookup

## Return Projection

`ReturnProjector` resolves workflow return value from final productions:

- default: last production
- configured `value`: result lookup by step/path
- configured `transform`: eval of arity-1 function source

Return transform failures are surfaced as execution errors.
