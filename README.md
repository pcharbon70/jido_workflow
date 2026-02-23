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
./jido --workflow /workflow:review --workflow-id code_review --params '{"value":"hello"}'
./jido --workflow command /workflow:review --workflow-id code_review
./jido --workflow run code_review --inputs '{"file_path":"lib/example.ex"}'
./jido --workflow control list --status running
```

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
