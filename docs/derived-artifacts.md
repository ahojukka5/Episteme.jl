# Derived-artifact and debug provenance

Issue [#32](https://github.com/ahojukka5/Episteme.jl/issues/32) gives
postprocessed, diagnostic, and debug products a shared provenance
envelope. Domain packages still own payload types. The in-memory record
is `DerivedArtifactRecord`; the optional AH5 layer persists those records
without embedding scientific payload bytes.

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

Retention is ancestry-safe over the supplied records. A pinned or
forensic product keeps required derived inputs even when those inputs
are declared `:visualization`, `:replaceable`, or `:debug`. If a
required input is still omitted, `compact_archive` fails closed rather
than publishing a retained child without its provenance.

## Ancestry

Inputs are exact object/revision references. When the archived input
has a `ContentId`, `DerivedInputRef` must carry the same identity.
`derived_ancestry` walks derived-from-derived chains.
`validate(records, graph)` fails closed on dangling inputs, missing
run/activity, missing or mismatched content identity, or cycles.

Package SemVer and payload arrays are not part of this contract.

## AH5 persistence

The optional feature is `:derived_artifact_records` at the fixed root
`episteme/derived_artifacts`. A derived-artifact archive also includes
authoritative state and run/activity records, because every derived
product names exact inputs and a producing run/activity.

```julia
write_derived_archive(path, graph, records; schemas = schemas)
view = inspect_archive(path, ArchiveDerivedHistory)
graph2 = reconstruct_graph(view)
derived_ancestry(view.artifacts[end], view)
plan_purge(graph2, roots; derived = view.artifacts)
```

Parameters, units, value-shape, diagnostic context, and `ArtifactRef`
metadata must be portable. Credential-like values are refused before
publication. Large embedded or external products stay behind
`ArtifactRef`; the writer does not load or copy those bytes.

Old AH5 files that do not declare the feature remain readable and return
an empty specialized view. A declared feature with missing or corrupt
records fails closed. Event/write/log history and physical bulk `/data`
embedding remain separate layers.
