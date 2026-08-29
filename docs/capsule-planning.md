# Reproduction capsule planning

Issue #79 is the first implementation slice of the reproduction-capsule epic
#35. It is deliberately a **pure planning API**: no AH5 file is written and the
source archive graph is never mutated.

## Three separate questions

A capsule plan keeps three contracts separate instead of collapsing them into
one boolean:

1. **Retention** — what #31 says must survive from the selected revision root.
2. **Integrity** — what #42 can identify and verify for the selected scientific
   state at the requested verification strength.
3. **Readiness** — whether the resulting planned capsule can truthfully support
   `:inspect`, `:replay`, `:restart`, or `:rerun`.

This means `CapsulePlan.valid` and `CapsulePlan.ready` have different meanings.
A plan may be structurally valid and integrity-clean while still not being
replay-ready, for example because the producing run did not capture a software
environment or because required scientific content remains external.

```julia
plan = plan_capsule(
    graph,
    revision_id,
    schemas;
    target = :inspect,
    verification = :metadata,
)

isvalid(plan)             # retention + integrity closure is trustworthy
isready(plan)             # requested target is satisfied
readiness(plan, PipelineTarget(:replay))
```

## Revision scope

The selected state comes from the existing #33 `RevisionManifest`. Unrelated
branches are not scanned for integrity or readiness. Reachability then uses #31
with `RetentionRoot(revision_id)` so the future compacted capsule also preserves
required revision/run/provenance closure.

`plan.retention` exposes the deterministic `PurgePlan`, including retained and
omitted revisions/runs and per-object reachability classifications.

## Integrity coverage of retained content

Capsule construction is stricter than ordinary archive inspection. Every
retained scientific object must have a strong current `sha256:<64 hex>`
`ContentId`, and every retained object must be represented by the selected
revision integrity report.

This intentionally exposes a boundary between #31 and #42: reachability can
retain additional objects through run/activity/event provenance that are not
part of the selected snapshot's #75 integrity closure. Such a plan fails closed
with `:capsule_retained_object_not_integrity_covered` rather than silently
publishing an unverifiable capsule. A later slice can extend integrity coverage
for those target-specific provenance dependencies.

External dependencies similarly remain explicit. They must carry a strong
identity and be covered by the external integrity report. Even a successfully
sample- or full-verified external file remains external; existing replay/rerun
readiness therefore conservatively reports that a self-contained capsule still
requires external provisioning.

## Planning API

```julia
plan_capsule(
    graph,
    revision_id,
    schemas;
    target = :inspect,
    externals = ExternalRequirement[],
    external_integrity = ExternalIntegrityRecord[],
    verification = :metadata,
    policy = RetentionPolicy(),
)
```

Supported targets are `:inspect`, `:replay`, `:restart`, and `:rerun`.
Verification uses the existing `:metadata`, `:sample`, and `:full` levels.

`report`, `validate`, `readiness`, and `to_namedtuple` expose the source
revision, requested target, verification level, retention counts,
classifications, external dependencies, integrity report, and readiness result.

## Next slice

Once a `CapsulePlan` is valid, the next #35 layer can call #31 compaction and
write a new JLD2-backed AH5 capsule using the existing schema and integrity
persistence contracts. That writer must preserve the source archive identity
and root revision ids and must not mutate the source archive.

Portable-document embedding, software-environment/execution-context manifests,
and trusted native payload replay remain separate later layers.
