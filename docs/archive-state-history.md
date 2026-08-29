# AH5 authoritative state history

Issue #81 adds the first authoritative history-record extension to the JLD2-backed AH5 profile. The core AH5 profile and ordinary `ArchiveInspection` stay backward-compatible; authoritative state records are an optional v1 feature.

## Scope

The fixed optional root `episteme/state_history` stores payload-free records for:

- `ArchiveObject` envelopes, including exact object/revision/content identities, namespace and schema identity, provenance references, and named `ObjectRef`s;
- immutable `RevisionRecord` parent/run/plan links;
- `WorkflowHead` identities, names, and revision targets.

The representation uses indexed primitive/portable records so `JLD2.jldopen(...; plain=true)` can reconstruct the state graph without domain packages or scientific payload materialization.

## Writing and inspection

```julia
write_state_archive(path, graph; namespaces=namespaces, schemas=schemas)
view = inspect_archive(path, ArchiveStateHistory)
manifest = inspect(view, revision_id)
```

The writer validates the state graph before publishing the file and removes a newly created file if the state-history append fails. The specialized forensic reader fails closed for missing indexed roots, duplicate object/revision/head identities, revision cycles or dangling parents, dangling head targets, unavailable object references, schema/kind/namespace disagreement, or disagreement with the core AH5 history counts.

Old AH5 files that do not declare `:state_history_records` remain valid and return an empty specialized state-history view.

## State-only checkout semantics

This slice intentionally does **not** persist full `RunRecord`, `ActivityRecord`, `EventRecord`, write-transaction, or log-stream provenance. Therefore the reopened graph is authoritative for the historical **state graph**, but not yet for replay/rerun provenance.

`inspect(state, revision_id)` reuses the existing revision visibility and object-reference closure rules. Missing producing-run diagnostics are omitted because this extension explicitly does not claim run-history completeness. The returned manifest still carries exact revision parents, plan id, heads, object envelopes, content ids, provenance references, and internal/external state dependencies.

A later provenance-history slice will persist runs/activities/events and can then restore replay/restart/rerun readiness without changing these state identities.

## Trust boundary

The state-history extension stores identities and references, not payload bytes. A stored `ContentId` records the envelope's logical content identity; payload integrity remains the separate #42 contract and optional integrity-manifest extension.

The generic reader validates the reconstructed state against embedded schema listings when present. Physical JLD2/HDF5 paths, chunking, or Julia type metadata are never scientific identity.

## Reproduction capsules

This state-history layer is the missing persistence foundation for #35. A valid `CapsulePlan` can eventually compact its selected graph and write these exact state records into a standalone AH5 capsule. Full replay/rerun capsule readiness still waits for the subsequent run/activity/event provenance-history slice.
