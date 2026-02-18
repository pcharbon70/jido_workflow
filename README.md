# JidoWorkflow

`JidoWorkflow` is an Elixir application scaffold.

## Running

Install dependencies:

```bash
mix deps.get
```

Run tests:

```bash
mix test
```

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
