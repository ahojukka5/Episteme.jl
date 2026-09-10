# Standalone metadata capsules

`write_capsule_archive` materializes a valid `CapsulePlan` as a new AH5 file.
It preserves the selected state and retained run, event, write and log metadata
without modifying the source graph. Scientific payload bytes and raw log bytes
remain outside this first physical capsule slice.

```julia
using Episteme, JLD2

plan = plan_capsule(graph, revision_id, schemas; externals = requirements)
result = write_capsule_archive(
    "capsule.ah5", graph, plan, schemas;
    source_archive_id = "source-archive-id",
    externals = requirements,
)

core = inspect_archive(result.path)
capsule = inspect_archive(result.path, CapsuleManifest)
history = inspect_archive(result.path, ArchiveEventHistory)
restored = reconstruct_graph(history)
```

The reader needs Episteme and JLD2, but neither the source archive nor domain
packages. External requirements remain explicit, with their strong content
identities and artifact locations. Forensic inspection reads those declarations;
it does not fetch external payloads or re-verify their current bytes.

## Plan binding and publication

Before creating an archive, the writer reselects the source revision, recomputes
compaction using the plan's retention policy, and checks retained and omitted
sets. It also validates the integrity manifest and binds it to the source and
compacted metadata. A stale plan must be regenerated.

Only schema definitions referenced by retained committed or staged envelopes
are embedded. Unused versions and unused external declarations are excluded.
Existing destinations are refused. Intermediate archive layers are written in
a temporary directory beside the destination; the complete bundle is inspected
before publication, and temporary files are removed if a layer fails.

## Identity and completeness

The optional `:capsule_manifest` feature lives at the reserved
`episteme/capsule` root. Its record contains the new archive identity, source
archive identity, root revision, requested target, verification level, and
retained/omitted object, revision and run counts. The capsule identity must
differ from the source identity, including when a custom `ArchiveProfile` is
provided. Omitted counts describe the original source; the standalone reader
can check retained counts against the embedded graph.

`payloads_embedded` is always `false`. A valid plan targeting replay, restart or
rerun can still produce inspectable metadata, but the resulting capsule does
not claim to contain the scientific payloads or environment needed to execute
that target. `CapsuleArchiveResult` records publication and source preservation;
it does not declare execution readiness.

The existing [planning coverage rules](capsule-planning.md) still apply:
retained scientific objects outside the selected revision's integrity closure
must be addressed before the plan can be materialized. Payload packaging,
migrations and signatures remain later layers. Optional
[software-environment records](software-environments.md) can be supplied through
`software_environments=registry`; the capsule preserves those records and checks
that its retained provenance references resolve before publication.
