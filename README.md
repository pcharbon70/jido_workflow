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

Build a local `jido` executable:

```bash
mix escript.build
```

Then run commands directly:

```bash
./jido --workflow code_review -file_path lib/example.ex -mode full
./jido --workflow release_validation -target_branch main -commit_sha abc123
./jido --workflow code_review -backend strategy -await-completion false -timeout 45000 -file_path lib/example.ex
```

`jido --workflow` always routes to `mix workflow.run`.
All trailing options must be `-option-name option-value` pairs, and they are
encoded into the run `inputs` map, except these reserved run options:

- `-run-id`
- `-backend` (`direct` or `strategy`)
- `-source`
- `-bus`
- `-timeout` (positive integer milliseconds)
- `-start-app` (`true|false` or `1|0`)
- `-await-completion` (`true|false` or `1|0`)
- `-pretty` (`true|false` or `1|0`)

Install globally (optional):

```bash
mix do escript.build + escript.install
```

If needed, add `~/.mix/escripts` to your `PATH` so `jido` is available everywhere.
Set `JIDO_WORKFLOW_TZDATA_DIR` if you want a custom timezone data directory.

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
