# Reproduction capsules

`write_capsule_archive` materializes a valid `CapsulePlan` as a new AH5 file.
It compacts the selected revision's reachability closure and records schemas,
provenance, external artifact references, and a content manifest. Portable
scientific state and portable declarative documents are embedded when the
caller supplies them and their canonical content identity matches the
envelope. The source graph is not modified.

```julia
using Episteme, JLD2

plan = plan_capsule(graph, revision_id, schemas; externals = requirements)
result = write_capsule_archive(
    "capsule.ah5", graph, plan, schemas;
    source_archive_id = "source-archive-id",
    externals = requirements,
    payloads = payloads,
    documents = document,
    software_environments = environments,
    execution_contexts = contexts,
)
verified = verify_capsule(result.path)

core = inspect_archive(result.path)
capsule = inspect_archive(result.path, CapsuleManifest)
history = inspect_archive(result.path, ArchiveEventHistory)
restored = reconstruct_graph(history)
```

Generic inspection needs Episteme and JLD2, not the scientific packages that
produced native values. It checks portable payload hashes against the stored
integrity rows and does not deserialize Julia-native payloads.
`verify_capsule(path; native_policy=true)` is the explicit gate for that
deserialization: the stored byte hash and canonical content identity are
checked first. External requirements stay explicit. Inspection does not fetch
them or re-verify their current bytes.

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
`episteme/capsule` root. Format 2 also stores portable payloads, portable
documents, and explicitly trusted native bytes at sibling roots. The manifest
contains the new archive identity, source archive identity, one root revision,
the requested target, the verification level, retained and omitted counts, and
one row per included, external, unavailable, redacted, or omitted item.
`payloads_embedded` is true only when a scientific payload row is included.
The capsule identity must differ from the source identity. Omitted counts
describe the original source.

`manifest.readiness` is what the embedded content supports:
`inspectable`, `replayable`, `restartable`, and `rerunnable`. A requested
target is not treated as achieved. Replay requires portable state, or native
state that has passed `verify_capsule` with `native_policy=true`, plus the
recorded software environment and no external dependencies. Restart can hold
when checkpoint payloads are embedded even if other dependencies are external.
Rerun additionally requires replayable state, a portable specification, and
recorded non-dirty dependency versions. Missing dependencies, redacted or
absent payloads, and modified source downgrade those claims. OS images,
language runtimes, and containers are recorded as omitted and are not
packaged. Raw log bytes are not packaged. A legacy format 1 manifest remains
metadata-only and cannot claim execution readiness.

The existing [planning coverage rules](capsule-planning.md) still apply:
retained scientific objects outside the selected revision's integrity closure
must be addressed before the plan can be materialized. Optional
[software-environment](software-environments.md) and
[execution-context](execution-contexts.md) records are filtered to the
provenance the retained closure actually references. Migrations and signatures
remain later layers.
