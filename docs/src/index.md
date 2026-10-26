# Episteme

`Episteme` is the shared semantic runtime and the JLD2-backed `.ah5` archive
for composable research records. Domain packages keep their payloads and the
meaning of their operations. This package keeps the common introspection
generics, local schemas, identities, history vocabulary, the in-memory
orchestration protocol, and archive persistence.

```text
Episteme = semantics + schemas + history/provenance
         + orchestration protocol
         + JLD2-backed AH5 persistence
```

The package dependencies in `Project.toml` are the standard libraries
`Dates`, `SHA`, and `UUIDs`. `JLD2` is a weak dependency. `using Episteme`
loads the records and the fail-closed archive stubs. `using JLD2` loads the
`episteme_jld2_ext` extension, which is what actually opens an `.ah5` file.

## In this manual

- [Architecture](architecture.md) — what the package owns, how `src/` is laid
  out, and the boundary stated in this repository.
- [Guide](guide.md) — common record operations, with the file each function
  comes from.
- [Public API](api.md) — curated entry points from the `export` list in
  `src/Episteme.jl`.

The contract chapters that already live in `docs/*.md` are copied into this
site at build time, under Record chapters. The copy is `docs/src/included/`
and is not committed. Edit the chapters in `docs/`, not the copy. Those
chapters are the durable archive contract, not one-off audits.

Build the HTML locally:

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

The HTML lands in `docs/build`. This manual does not deploy the site.
