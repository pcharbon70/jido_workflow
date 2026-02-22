# 03 Definition Loading and Registry

## Loading Pipeline

The load path for each workflow file is:

1. `MarkdownParser.parse_file/1`
2. `SchemaValidator.validate_workflow/1`
3. `Validator.validate/1`
4. `Compiler.compile/1`

`Loader.load_file/1` runs steps 1 to 3 and returns a typed `Definition` struct.

## Markdown Contract

`MarkdownParser` expects:

- YAML frontmatter (`---` block)
- `## Steps` containing `### step_name` sections
- optional `## Error Handling`
- optional `## Return`

Input references such as `` `input:foo` `` and result references such as `` `result:step.output` `` remain string expressions and are resolved at runtime.

## Validation Layers

- `SchemaValidator` enforces JSON schema contracts from `priv/schemas/*.schema.json`.
- `Validator` enforces domain rules and normalizes into typed structs.
- Errors are normalized as `Jido.Code.Workflow.ValidationError` with `path`, `code`, and `message`.

## Registry Behavior

`Registry`:

- scans `workflow_dir` for `*.md`
- hashes files to skip unchanged entries
- keeps invalid entries cached with errors
- can refresh all entries or force reload one workflow id

Useful APIs:

- `refresh/1`
- `reload/2`
- `list/2`
- `get_definition/2`
- `get_compiled/2`

## Cache and Invalid Entries

If a workflow fails to parse/validate/compile, the entry is retained with:

- `enabled: false`
- `definition: nil`
- `compiled: nil`
- captured errors

This keeps diagnostics visible via registry commands without crashing the runtime.
