# Derived-artifact and debug provenance

This is the first implementation slice of issue
[#32](https://github.com/ahojukka5/Episteme.jl/issues/32), tracked by
[#105](https://github.com/ahojukka5/Episteme.jl/issues/105). It gives
postprocessed, diagnostic, and debug products a shared provenance
envelope. Domain packages still own payload types. AH5 persistence of
these records is a later slice.

## Why this envelope exists

Raw/authoritative evidence must stay distinct from later analysis.
Recomputation appends a new derived object and a new provenance record.
It does not overwrite the previous result.

```julia
record = DerivedArtifactRecord(
    object.object_id,
    object.revision_id,
    :visualization;
    inputs = [DerivedInputRef(mesh.object_id, mesh.revision_id; content_id = mesh.content_id)],
    run_id = run.id,
    activity_id = activity.id,
    operation = :plot,
    parameters = (; cmap = "viridis"),
    retention = :visualization,
    artifact = ArtifactRef(:png; path = "preview.png"),
)
```

`report(record)` explains why the artifact exists from role, operation,
inputs, and parameters. It does not load payload bytes.

## Roles and retention

Roles are `:primary`, `:checkpoint`, `:derived`, `:debug`,
`:visualization`, and `:annotation`.

Retention is consumed by [`plan_purge`](archive-purge.md):

| Retention | Default purge class |
| --- | --- |
| `:pinned` | always retained |
| `:forensic` | retained while `keep_forensic_logs` |
| `:visualization` | `:purgeable_visualization` unless `keep_debug_logs` |
| `:replaceable` | `:replaceable` unless `keep_debug_logs` |
| `:debug` / `:ephemeral` | `:purgeable_debug` unless `keep_debug_logs` |

Pass the records into purge:

```julia
plan_purge(graph, roots; derived = records)
compact_archive(graph, roots; derived = records)
```

## Ancestry

Inputs are exact object/revision/`ContentId` references.
`derived_ancestry` walks derived-from-derived chains.
`validate(records, graph)` fails closed on dangling inputs, missing
run/activity, content-identity mismatch, or cycles.

Package SemVer and payload arrays are not part of this contract.
