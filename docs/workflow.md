# Workflow lifecycle

Episteme records scientific workflow transitions as inspectable history.
Domain packages own payloads and operations. Episteme owns identity,
readiness, staging, commit, and provenance.

The in-memory lifecycle is:

```text
plan → readiness → execute! → stage → validate → commit! → archive
```

`execute!` never moves a workflow head. `commit!` is the only head-mover.
Physical `.ah5` persistence remains `write_archive` / `inspect_archive`.

## Identities

Keep these distinct:

| Identity | Meaning |
| --- | --- |
| `ObjectId` | stable logical object (a mesh, a field) |
| `RevisionId` | one committed workflow snapshot |
| `ContentId` | logical bytes/content, independent of revision |

Two revisions may share a `ContentId`. A later file at a familiar path with
a different `ContentId` is not the same input.

## Validation versus readiness

- `validate(x)` asks whether `x` is internally consistent.
- Domain `validate(payload)` is scientific/structural validity for that type.
- `readiness(x, target)` asks whether `x` may enter a named next operation.

Passing `validate` does not mean the object is ready for every later stage,
and it does not mean “all science is correct.”

## Declare an operation

```julia
spec = OperationSpec(
    Symbol("example/discretize");
    name = :discretize,
    inputs = (:geometry,),
    outputs = (:mesh,),
    input_ports = [OperationPort(:geometry; schema = geom_schema)],
    readiness_target = :discretize,
)
```

Episteme does not implement `:discretize`. The owning package adds:

```julia
import Episteme: apply_operation

function apply_operation(::Val{Symbol("example/discretize")}, spec, inputs; plan, kwargs...)
    geom = inputs[:geometry].payload
    mesh = my_discretize(geom)
    return OperationOutcome(;
        outputs = [staged_result(
            plan_output_id(plan, spec, :mesh),
            mesh;
            namespace = ns,
            kind = schema_kind(mesh_schema),
            schema = mesh_schema,
            content_id = content_id,
            references = [ArchiveReference(:geometry, inputs[:geometry].object.object_id;
                revision_id = inputs[:geometry].object.revision_id)],
        )],
    )
end
```

Do not serialize Julia functions as the workflow contract.

## Plan

A `Plan` is an intended workflow, not a scheduler. Bindings make
producer/consumer edges and external roots explicit:

```julia
plan = Plan(
    PlanId("plate-solve");
    operations = [discretize, solve],
    bindings = [
        PlanBinding(:geometry; object_id = geom_id, revision_id = rev1, content_id = cid),
        PlanBinding(:mesh; source = :discretize, object_id = mesh_id),
        PlanBinding(:field; source = :solve, object_id = field_id),
    ],
)

readiness(plan, PipelineTarget(:execute))
readiness(plan, graph, PipelineTarget(:execute; head = :main, store = store))
```

`plan_operation_order` is the inspectable dependency order. Cycles fail
readiness. Missing, stale, or wrong-revision roots fail before `execute!`.
An input bound to `object@revision` uses only that revision's payload; a
missing exact payload fails closed and never substitutes the moving
ObjectId payload.

## Execute, stage, commit

```julia
store = WorkingStore()
run = execute!(graph, plan; head = :main, store = store)
# run.status === :completed, graph.heads unchanged, outputs in run.staged

rec = commit!(graph, run.id; head = :main, store = store)
# one new RevisionRecord, staged rows promoted, selected head moved
```

If execution fails, committed history is unchanged. Staged rows are not
`ArchiveGraph.objects` until commit.

## Restart and recovery

`RestartRequirement` / `CheckpointRef` name exact object/content identity.
`restart!` fails closed when that identity does not match.

`WriteTransaction` phases (`:begin`, `:appending`, `:committing`,
`:committed`, `:aborted`, `:uncertain`) are logical, not file handles.
`recover_writes!` completes a commit only when objects, revision, run, and
head already agree; otherwise it rolls the partial commit back.

Tests may pass `interrupt_after` to `execute!` / `commit!` and catch
`ExecutionInterrupted`.

## Provenance queries

After commit:

```julia
producing_run(graph, object)
producing_activity(graph, object)
used_inputs(graph, object)
previous_revision(graph, object_id, revision_id)
dependents(graph, object_id, revision_id)
inspect(graph, revision_id)
branch_from(revision_id; id = WorkflowHeadId("alt"), name = :alt)
```

`inspect` / `checkout` are lazy historical manifests (no payload load).
`branch_from` returns a new head bookmark; it does not copy directories.

## Reproduction comparison

`compare_reproduction(left, right; kind = :exact_content)` compares
`ContentId`s. Domain packages extend
`compare_reproduction(::Val{:numeric}, left, right)` for tolerance-qualified
agreement. Episteme does not invent a universal floating-point tolerance.

## What this is not

- a distributed DAG scheduler
- automatic `.ah5` writes on every execute
- domain meshing, FEM, or solver semantics
- `rerun!` (committed rerun remains later work)
- bitwise identity for HPC floating-point workflows
