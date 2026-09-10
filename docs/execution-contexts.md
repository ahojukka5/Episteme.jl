# Execution context records

`ExecutionContext` records caller-supplied facts that can affect a result even
when the software environment is identical. Episteme does not query hardware,
capture environment variables, or infer missing historical facts. Context
identity is separate from software-environment and payload-schema identity.

```julia
using Episteme

context = ExecutionContext(
    hardware=(cpu_architecture="x86_64",),
    devices=((id="gpu-0", architecture="gfx90a"),),
    numerics=(precision="Float64", accumulation="Float64",
        deterministic=false, fast_math=false),
    parallelism=(rank_count=1, thread_count=1),
    ranks=((rank=0, device_ids=("gpu-0",), thread_count=1),),
    features=("host-staged-halo",),
)
run = RunRecord(RunId("example"); execution_context=context.id)
registry = ExecutionContextRegistry((context,))
restored = from_namedtuple(ExecutionContextRegistry, to_namedtuple(registry))
@assert find_execution_context(restored, run.execution_context).id == context.id
```

The following groups accept NamedTuples with only the listed fields. Omitted
fields remain `nothing`. Device and rank collections are normalized by logical
identity; feature and device-id lists are sorted and deduplicated. Caller-owned
arrays are copied into immutable tuples.

| Group | Allowed fields |
| --- | --- |
| `hardware` | `cpu_architecture`, `cpu_model`, `memory_bytes` |
| `devices` (sequence) | `id`, `architecture`, `model`, `memory_bytes` |
| `numerics` | `precision`, `accumulation`, `deterministic`, `fast_math`, `backend`, `provider`, `solver`, `compiler` |
| `parallelism` | `rank_count`, `thread_count`, `partition`, `allocation_id` |
| `ranks` (sequence) | `rank`, `device_ids`, `thread_count` |
| `rng` | `algorithm`, `version`, `seed`, `state_content`, `replay` |

Counts and memory capacities are positive integers; rank indices and event
sequences are nonnegative. Numerical switches are booleans. Device ids are
logical names chosen by the caller, and every recorded rank/device reference
must resolve within the context. Rank indices must be below a recorded rank
count. A partial rank list is permitted when other ranks were not recorded.

Additional fields are `features`, typed `plan_id` and `revision_id` references,
`event_sequence`, and `captured_at` (`YYYY-MM-DDTHH:MM:SS[.sss]Z`, in UTC). These
are optional, including when one context is shared across runs. All recorded
facts, including timestamps and references, participate in the context identity.
Empty sequences are recorded empty collections; `nothing` means not recorded.

## RNG replay

`rng.seed` accepts a nonnegative integer and stores its exact decimal value.
`replay="seed"` requires the seed plus an algorithm and version. The domain
defines how to interpret that seed; it must not silently substitute another
generator. `replay="state"` requires algorithm, version, and a `ContentId` for
domain-owned portable continuation state. Episteme stores the reference, not a
live RNG, communicator, device, provider, or arbitrary Julia object.

`replay="unspecified"` or an omitted replay field makes no replay claim. A
record does not establish bitwise reproducibility across different hardware,
numerical policies, or parallel schedules. The domain must qualify its claim.

## Input boundary

Unrecognized fields, dictionaries, unsupported value types, credential-shaped
text, credential assignments, control characters, and common user-home path
forms are rejected. Diagnostics do not echo rejected values. There is no
generic environment or command-line field. These checks supplement explicit
field selection; they cannot recognize every possible secret encoded as text.
Callers must supply scientifically relevant facts, not opaque metadata dumps.

`validate` and `report` expose unrecorded groups without filling them from the
current machine. Portable restoration recomputes identity and rejects altered
records.

## AH5 persistence and inspection

Load JLD2 explicitly to activate archive I/O:

```julia
using JLD2
mktempdir() do dir
    path = joinpath(dir, "execution.ah5")
    write_run_archive(path, ArchiveGraph(ArchiveObject[]; runs=[run]);
        execution_contexts=registry)
    view = inspect_archive(path, ExecutionContextRegistry)
    @assert isvalid(view)
    @assert find_execution_context(view.registry, context.id).id == context.id
end
```

All archive writer layers accept `execution_contexts=registry`, including
integrity and capsule writers. The optional `execution_context_records` feature
stores indexed metadata under `episteme/execution_contexts`. Supplied registries
must cover recorded object, run, staged-object, restart, and event references.
An omitted registry preserves the historical absence of context records.

The specialized inspector verifies content-derived identity, the provenance
summary, and authoritative references in declared history layers. It reads
generic provenance metadata without loading scientific payloads.
`report(view).metadata.contexts` provides concise hardware, precision, rank,
and RNG-replay summaries; unknown facts remain `nothing`.
Missing contexts and malformed records fail inspection; archives without the optional
feature report explicit unknown provenance. Capsule publication verifies the
supplied registry before publishing the new file.

An RNG state content reference identifies domain-owned bytes; metadata
inspection does not read or verify those bytes. A domain can store an
`ExternalRequirement` with the matching content identity and use
`capture_external_integrity` / `verify_external(...; level=:full)` before
restoring its state. It must resolve and verify the referenced state before
claiming a successful continuation. Missing or modified bytes do not become
valid merely because the execution-context metadata is intact.
