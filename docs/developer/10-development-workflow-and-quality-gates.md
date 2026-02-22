# 10 Development Workflow and Quality Gates

## Toolchain

Local runtime versions are pinned in `.tool-versions`:

- Erlang `28.3.1`
- Elixir `1.19.5-otp-28`

Install with:

```bash
asdf install
```

## Local Quality Gate

The repo uses a git pre-commit hook (`.githooks/pre-commit`) that requires all checks to pass:

1. `mix test`
2. `mix credo --strict`
3. `mix dialyzer`

If `asdf` is available, the hook runs commands via `asdf exec`.

Install hooks via:

```bash
scripts/install-git-hooks.sh
```

## CI Gate

GitHub Actions CI (`.github/workflows/ci.yml`) runs:

- lint workflow (reusable action)
- tests across OTP `27` and `28`, Elixir `1.18` and `1.19`

## Contributor Expectations

- Keep docs and contracts aligned with runtime behavior.
- Add/adjust tests for command, trigger, and execution behavior when changing runtime modules.
- Avoid bypassing hooks (`--no-verify`) for normal contributor flow.
- Treat `workflow.*` signal contracts as API surface; changes require coordinated doc updates.
