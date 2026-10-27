# Contributing to Episteme.jl

> Process rules come from the latest approved
> [OodiHandbook](https://github.com/ahojukka5/OodiHandbook) tag (AUTH-007).
> Start with its `guides/local-development.qmd` and `guides/contributing.qmd`.
> This file adds only this repository's facts (ENG-001, ENG-028).

Package scope, boundaries and test commands are in [`AGENTS.md`](AGENTS.md).
In short: open an issue, work on a branch, and open a pull request; the owner
reviews it and merges by rebase, so `master` stays linear.
Issues, branches (ENG-026), commits, trailers (ENG-025), review threads
(ENG-024) and rebase-merge (ENG-018) follow the Handbook. Dependencies resolve
through the registry (SWE-016); `[deps]` stays stdlib-only and JLD2 stays a
weak dependency.

## Commit scopes

Subjects are `type(scope): imperative`. Scopes in use: `archive`, `capsule`,
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
