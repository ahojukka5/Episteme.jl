# Contributing to Episteme.jl

> Shared governance is maintained in the
> [current OodiHandbook](https://github.com/ahojukka5/OodiHandbook/blob/master/index.qmd).
> Start with its `guides/ENG/local-development.qmd` and `guides/ENG/contributing.qmd`.
> This file contains repository-specific information, not copied common rules.

Package scope, boundaries and test commands are in [`AGENTS.md`](AGENTS.md).
The package's `[deps]` stays stdlib-only and JLD2 stays a weak
dependency. Consult the current Handbook for common contribution
and review procedures.

## Commit scopes

Scopes in use: `archive`, `capsule`,
`migration`, `integrity`, `lifecycle`, `compat`, `api`, `readme`,
`workflows`, `governance`, `agents`. A scope is optional for a change that
spans the package.

## Hooks

The repository has no pre-commit or Git hooks. Run `pkg> test Episteme`, and
`julia --project=docs docs/make.jl` for documentation changes, before opening
a pull request.

## Never commit

- `Manifest.toml`, `Manifest-*.toml`, `LocalPreferences.toml`
- `docs/build/` and `docs/src/included/` (Documenter products)
- `runs/`, `*.out`, `*.err`, `run.log`, `inst.log`, coverage and `*.mem` files
