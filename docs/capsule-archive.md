# Standalone inspectable AH5 capsules

Issue #87 is the first physical materialization slice of reproduction-capsule issue #35.
It turns a valid `CapsulePlan` into a new compact AH5 archive that can be inspected
without the original working archive or domain payload packages.

## Identity

A capsule is a derived archive, not the source archive copied under another filename.
It therefore has two explicit identities:

- the AH5 profile `archive_id` is the new capsule archive identity;
- `CapsuleArchiveManifest.source_archive_id` records the source archive identity.

These ids must differ. The manifest also records the selected root revision, requested
pipeline target, verification level, retained counts, external dependency count, and
whether scientific payload bytes are embedded.

This slice always records:

```text
payloads_embedded = false
```

## Materialization pipeline

`write_capsule_archive` composes existing Episteme contracts rather than introducing a
parallel archive model:

1. the `CapsulePlan` must be valid;
2. its frozen retained-source signature is rechecked against the current source graph;
3. #31 reachability/compaction is rerun from the selected revision and must reproduce
   the planned retained/omitted sets;
4. only schema definitions required by retained committed or staged envelopes are kept;
5. only retained external requirements are kept;
6. the selected revision-integrity manifest must bind to the compacted graph, filtered
   schema registry, and filtered external set;
7. the existing state/run/event AH5 writers persist the authoritative metadata history;
8. integrity trust records and the capsule manifest are appended;
9. any failure after file creation removes the partial capsule.

The source graph is never mutated.

## Frozen source signature

`CapsulePlan.source_signature` is a canonical SHA-256 identity of the retained metadata
closure at planning time. It covers object envelopes and references, revision/head
records, run/activity/staged/restart provenance, retained events, write transactions,
log-stream metadata, and retained external requirements.

The signature is recomputed immediately before materialization. A source mutation after
planning therefore fails closed even when reachability ids and counts have not changed.
Unrelated omitted branches are not part of the signature.

## Forensic inspection

```julia
view = inspect_archive(path, CapsuleArchiveManifest)
```

A valid capsule view cross-checks:

- capsule manifest archive id against the AH5 profile;
- root revisions and retained counts against the reconstructed authoritative graph;
- state, run, event/write/log history layers;
- persisted revision-integrity records;
- integrity records against the reconstructed graph, embedded schema definitions, and
  external requirements.

Thus an independently parseable but forged state/schema layer does not remain a valid
capsule when its integrity trust record disagrees.

## Readiness

Capsule-level readiness is intentionally stricter than readiness of the reconstructed
metadata graph:

```julia
readiness(view, PipelineTarget(:inspect))  # ready when capsule is valid
readiness(view, PipelineTarget(:replay))   # not ready in this slice
readiness(view, PipelineTarget(:restart))  # not ready in this slice
readiness(view, PipelineTarget(:rerun))    # not ready in this slice
```

The latter three report `:capsule_payloads_not_embedded`. Metadata provenance may be
complete enough to explain how a run was produced, but that does not imply the capsule
contains the scientific payload bytes required to reproduce or restart it.

## External artifacts

Large authoritative artifacts may remain external. Their strong `ContentId` and
`ArtifactRef` survive into the capsule and are included in the integrity contract.
They are never silently treated as embedded payloads.

## Deliberate boundary

This slice does not embed scientific payload bytes, raw log bytes, software-environment
manifests, execution-context manifests, runtimes, drivers, migrations, or signatures.
Those capabilities can extend capsule readiness later without changing the capsule
identity/retention contract established here.
