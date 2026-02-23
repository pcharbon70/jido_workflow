# Jido.Code.Workflow

`Jido.Code.Workflow` is an Elixir application scaffold.

## Running

Install dependencies:

```bash
mix deps.get
```

Run tests:

```bash
mix test
```

## CLI

Build a local `workflow` executable:

```bash
mix escript.build
```

Then run commands directly:

```bash
./workflow code_review -file_path lib/example.ex -mode full
./workflow release_validation -target_branch main -commit_sha abc123
./workflow code_review -backend strategy -await-completion false -timeout 45000 -file_path lib/example.ex
./workflow --control list --status running --limit 20
./workflow --control pause run_123
./workflow --watch --limit 10
./workflow --command /workflow:code_review --workflow-id code_review --params '{"file_path":"lib/example.ex"}'
```

`workflow` defaults to `mix workflow.run` when the first argument is a workflow id.
For run starts, all trailing options must be `-option-name option-value` pairs,
and they are encoded into the run `inputs` map, except these reserved run options:

- `-run-id`
- `-backend` (`direct` or `strategy`)
- `-source`
- `-bus`
- `-timeout` (positive integer milliseconds)
- `-start-app` (`true|false` or `1|0`)
- `-await-completion` (`true|false` or `1|0`)
- `-pretty` (`true|false` or `1|0`)

You can also forward directly to other workflow Mix tasks:

- `workflow --control ...` -> `mix workflow.control ...`
- `workflow --signal ...` -> `mix workflow.signal ...`
- `workflow --watch ...` -> `mix workflow.watch ...`
- `workflow --command ...` -> `mix workflow.command ...`

Non-reserved input values are JSON-decoded when possible (`true`, `3`, `9.5`,
`{"k":"v"}`, `[1,2]`); otherwise they remain strings.

Install globally (optional):

```bash
mix do escript.build + escript.install
```

If needed, add `~/.mix/escripts` to your `PATH` so `workflow` is available everywhere.
Set `JIDO_WORKFLOW_TZDATA_DIR` if you want a custom timezone data directory.

## Documentation

- Developer guides: `docs/developer/README.md`
- User guides: `docs/user/README.md`

## Git Hooks

Install repository-managed hooks:

```bash
./scripts/install-git-hooks.sh
```

The pre-commit hook blocks commits unless all of these pass:

```bash
mix test
mix credo --strict
mix dialyzer
```
