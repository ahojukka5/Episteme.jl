# Architecture

## Responsibility

Episteme owns the cross-domain research contract. A domain package owns the
scientific payload and the meaning of its operations.

The shared contract, as this repository states it, is:

- introspection generics `report`, `validate`, and `readiness`, so domain
  packages extend one set of functions instead of defining local lookalikes;
- structured reports and diagnostics;
- the domain-neutral semantic tree (`SemanticNode`, `NodeRef`) and local
  declarative schemas (`NodeSchema`, `AttributeSchema`, `ValidationRule`,
  `NodeValidationRule`);
- opaque scripting contracts (`script_node`), stored but not executed;
- archive identities, references, schema-version vocabulary, and portable
  document envelopes;
- provenance and history records, including the in-memory run, commit, and
  restart protocol;
- the JLD2-backed `.ah5` profile (`write_archive`, `inspect_archive`) in the
  package extension.

Shared infrastructure kinds use the `:episteme` / `episteme/*` namespace.
A domain kind stays in the namespace of the package that owns it.

## Source layout

`src/` has no subdirectories and no nested modules. `src/Episteme.jl` defines
the only module and `include`s the files below. `src/archive_envelope.jl`
itself includes `src/archive_history.jl` (plans, runs, events, and staging
records). The other source files are included from `src/Episteme.jl`.

Introspection and the semantic model:

- `src/introspection.jl`
- `src/semantic_tree.jl`
- `src/declarative.jl`
- `src/semantic_model.jl`
- `src/portable_document.jl`

Archive envelope, namespaces, and schemas:

- `src/archive_envelope.jl`
- `src/archive_history.jl` (included by `archive_envelope.jl`)
- `src/archive_namespaces.jl`
- `src/archive_schemas.jl`
- `src/schema_migration.jl`
- `src/schema_migration_archive.jl`

In-memory lifecycle, checkout, purge, and provenance queries:

- `src/archive_execution.jl`
- `src/archive_checkout.jl`
- `src/archive_purge.jl`
- `src/archive_provenance.jl`
- `src/archive_reproduction.jl`
- `src/derived_artifacts.jl`

Integrity, environments, and contexts:

- `src/content_integrity.jl`
- `src/external_integrity.jl`
- `src/revision_integrity.jl`
- `src/integrity_reverification.jl`
- `src/archive_integrity_persistence.jl`
- `src/archive_integrity_semantics.jl`
- `src/software_environment.jl`
- `src/execution_context.jl`
- `src/archive_external_preflight.jl`

Fail-closed archive entry points. These throw until `JLD2` is loaded:

- `src/archive_persistence.jl`
- `src/archive_profile.jl`
- `src/archive_profile_root_validation.jl`
- `src/archive_state_history.jl`
- `src/archive_run_history.jl`
- `src/archive_run_history_semantics.jl`
- `src/archive_event_history.jl`
- `src/archive_event_history_semantics.jl`
- `src/archive_software_environments.jl`
- `src/archive_execution_contexts.jl`
- `src/archive_derived_artifacts.jl`
- `src/archive_views.jl`
- `src/capsule_plan.jl`
- `src/capsule_archive.jl`
- `src/capsule_archive_metadata.jl`
- `src/capsule_content.jl`

File I/O lives in `ext/`, not under `src/`. `ext/episteme_jld2_ext.jl` is the
extension module. It includes the other `ext/episteme_jld2_ext_*.jl` files.
Those methods open `.ah5` files. The stubs in `src/archive_persistence.jl`
remain the methods a caller hits when `JLD2` is not loaded.

## Boundary

Dependencies flow one way. A domain package may depend on Episteme. Episteme
does not depend on a domain package. `[deps]` is stdlib only. A caller that
only needs the shared semantics does not load the archive extension.

`report`, `validate`, and `readiness` are read-only. They have no default
method for an arbitrary caller type. Domain packages add methods. Local
schema checks in Episteme are structural: required fields, portable value
kinds, finiteness, ranges, non-empty values, enums, and node-local order.
Cross-object scientific constraints stay in the domain package.

`script_node` records language, source, inputs, outputs, and effects.
Episteme does not run that source. Execution belongs to a caller that binds
inputs and outputs and decides which effects are allowed.

`execute!`, `commit!`, `recover_writes!`, and `restart!` mutate an
`ArchiveGraph` in memory. They do not write an `.ah5` file. `execute!` does
not move a workflow head. `commit!` is the head-moving publication step.
Physical writes are `write_archive` and the other writers in
`src/archive_persistence.jl`, and only after `using JLD2`.

`capture_portable` is a fail-closed interchange subset of a live
`SemanticNode` tree. It is not the `.ah5` writer, and `to_namedtuple` does
not turn an arbitrary `SemanticNode` into that portable contract.

Episteme does not own domain models, meshes, solvers, or the meaning of a
payload. It stores identities, schemas, history, and the protocol those
packages share.
