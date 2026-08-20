# Shared archive envelope

This is the logical object/reference/schema-version contract from issue
[#26](https://github.com/ahojukka5/OodiCore.jl/issues/26). It lives entirely
in Episteme and does not open files. Physical `.ah5` encoding is the later
JLD2-backed AH5 profile inside Episteme; see
[`archive-ownership.md`](archive-ownership.md).

The envelope lets independently owned package payloads share one archive
without depending on each other or on package-native runtime handles.

## Identities

These are different types on purpose. Equal byte strings do not make them
the same kind of identity.

```text
DocumentId != PlanId != RunId != ActivityId != RevisionId != ObjectId != ContentId
```

| Type | Meaning |
| --- | --- |
| `ObjectId` | Archive-global logical object. Opaque (UUID-like). Not namespaced. |
| `RevisionId` | One global workflow revision. Several objects may be materialized in it. |
| `ContentId` | Logical content identity. Layout/chunking/compression do not belong here; hash rules are #42. |
| `WorkflowHeadId` | Movable bookmark pointing at a `RevisionId`. |
| `RunId` | One execution of a plan (or of an ad-hoc operation sequence). |
| `DocumentId` | Authored semantic document object. Not a revision or content hash. |
| `PlanId` | Resolved executable plan. Distinct from the source document and from a run. |
| `ActivityId` | One operation instance inside a run. Bookkeeping only; never an idempotency key. |
| `AgentId` | Human, software, or LLM actor when provenance needs attribution. Not authn/authz. |
| `SoftwareEnvironmentId` | Reference to a software-environment record (#37). |
| `ExecutionContextId` | Reference to an execution-context fingerprint (#43). |

Shared *record* types (`Plan`, `RunRecord`, `ActivityRecord`,
`EventRecord`, `RevisionRecord`) live on `ArchiveGraph` as data.
The durable run/commit/restart contract (`StagedObject`,
`WriteTransaction`, `RestartRequirement`) is documented in
[`archive-lifecycle.md`](archive-lifecycle.md). The event timeline
(`EventRecord`, `EventBatch`, `LogStreamRecord`, `event_timeline`) is
documented in [`archive-events.md`](archive-events.md). Orchestration
(`execute!` / `commit!`) and `.ah5` persistence are later PRs.

```julia
object = ObjectId("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
content = ContentId("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
object != content          # distinct types
object.value == content.value

plan = PlanId("same-bytes")
activity = ActivityId("same-bytes")
plan != activity
plan != RunId("same-bytes")
```

### `ObjectId` is archive-global

`ObjectRef` carries no namespace, so an `ObjectId` must be unique across
the whole archive, not unique only inside `:oodi` or `:lieb`. Prefer an
opaque UUID. Human labels such as `model-1` are not identity.

The same `ObjectId` may appear in more than one workflow revision (a new
version of the same object). It must not appear under two namespaces or
two kinds. `validate(graph)` reports `:object_id_namespace_conflict` or
`:object_id_kind_conflict` if it does.

### `RevisionId` is a workflow revision

`ArchiveObject.revision_id` is the workflow revision that materialized
that object version. One revision can produce a mesh and a field
together. Parent and input revision edges belong to issue #30; they are
not a second `producer_revision` field on the envelope.

`WorkflowHead` points at a `RevisionId`, not at a single object snapshot.

## Dual history

`ArchiveGraph` holds both a snapshot graph and an activity graph:

| Collection | Node | Answers |
| --- | --- | --- |
| `revisions` | `RevisionRecord` | What was the committed world at this checkout? |
| `runs` / activities / `events` | `RunRecord`, `ActivityRecord`, `EventRecord` | What happened, with which plan and env? |

Activities live on `RunRecord`, not in a second graph-wide store. A run
may have `revision_id === nothing` (failed, still running, interrupted,
cancelled, uncertain, or not yet committed). Incomplete statuses never
name a committed revision. Events are not revisions. `event_timeline` is
a denormalized audit view; event text is not scientific state.
Uncommitted snapshot payloads live on `RunRecord.staged` until a later
`commit!` promotes them. Logical write phases live on
`ArchiveGraph.writes`. Optional raw logs live on
`ArchiveGraph.log_streams`.

Object membership of a revision is `find_objects(graph, revision_id)`.
`RevisionRecord` stores `id`, `parents`, optional `run_id`, and optional
`plan_id`. It does not duplicate an object-id list. Parent edges must
resolve in the graph (`:dangling_parent`). Cycles fail (`:cycle`).
Multiple parents are a merge. Ancestry helpers `revision_parents`,
`revision_children`, `revision_ancestors`, and `revision_descendants`
walk records only; they do not open files or load payloads.
`inspect` / `checkout` return a lazy `RevisionManifest` for one
committed revision; see [`archive-checkout.md`](archive-checkout.md).

Committed revisions are immutable. A `WorkflowHead` is movable metadata:
replacing `head.revision_id` does not change historical revision or
object rows. Reused content in a later revision is a new `ArchiveObject`
row (new `RevisionId`; `ObjectId` / `ContentId` may stay the same).

Plans and authored documents are ordinary `ArchiveObject`s when persisted:

| Kind | Namespace | Schema |
| --- | --- | --- |
| `episteme/document` | `:episteme` | `episteme_document_schema(version)` |
| `episteme/plan` | `:episteme` | `episteme_plan_schema(version)` |

`Plan` is the resolved recipe; `ActivityId` is never the idempotency key.

When `graph.revisions` is empty, existing object/head graphs still
validate as before. Once revision records are present, every object and
head revision must name one of them. `RunRecord.parent_run_id`, when
set, must name another run in the graph and must not be the run itself.
If a run and its revision both carry a `plan_id`, those ids must agree.

## Envelope

`ArchiveObject` identifies an object version. It does not store the
scientific payload. Domain packages keep typed models; AH5 later calls
package-owned codecs.

```julia
mesh = ArchiveObject(
    ObjectId("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
    RevisionId("rev-2");
    namespace = ArchiveNamespace(:delone; display_name = "Delone.jl"),
    kind = Symbol("delone/mesh"),
    schema = SchemaRef(:delone, "mesh", "1.0.0"),
    references = [ArchiveReference(
        :geometry,
        ObjectId("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        revision_id = RevisionId("rev-1"),
    )],
)
```

Required facts on every object:

- owning namespace (`ArchiveNamespace`)
- package-qualified `kind` (`delone/mesh`)
- exact `SchemaRef` (namespace, schema id, version)
- optional provenance *references* (`ProvenanceRefs`)
- named `ArchiveReference`s to other objects

`kind` must be owned by the object's namespace (`oodi/field` under
`:oodi`). Schema namespace and `schema_kind(schema)` must match `kind`.

`ArchiveGraph` holds objects and heads. Insertion order is not
authoritative. `ordered_objects`, `ordered_references`, and
`ordered_heads` sort by identity so later HDF5 group order cannot leak
into the logical model. `find_objects(graph, revision_id)` lists every
object materialized in that workflow revision.

## References

`ObjectRef` and `ArchiveReference` identify a target by global
`ObjectId`, optionally pinned to a `RevisionId`. They are not HDF5 paths.

An unpinned reference (`revision_id === nothing`) is a logical-object
link: `validate` accepts it if any version of that object exists. Exact
scientific dependencies must pin a `RevisionId` or use #30's revision
inputs. Appending an unrelated object does not invalidate a pinned
reference.

`validate(graph)` reports `:dangling_reference` when the target object or
pinned revision is absent. Workflow heads fail with
`:dangling_workflow_head` when no object was materialized in that
revision.

## Schema-version rules

A `SchemaRef` is an exact identity. Package SemVer is not consulted.

```julia
schema_status(SchemaRef(:oodi, "field", "1.1.0"), catalog)
```

returns one of:

- `:exact_read`
- `:backwards_compatible`
- `:migration_required`
- `:unsupported`
- `:missing_schema`

Compatibility is declared on `KnownSchema` entries in an
`ArchiveCatalog`. It is never inferred from version numbers. A 1.1.0
object is missing if the catalog only knows 1.0.0. `validate(object,
catalog)` and `validate(graph, catalog)` turn missing, unsupported, and
migration-required statuses into errors. Referenced software-environment
or execution-context ids that are not in the catalog fail the same way.
`nothing` on a provenance field means explicitly not recorded.

The catalog is not the embedded schema registry (#39) and not a
migration runner (#41). Those issues own the full definitions.

## Shared value conventions

`LogicalType` and `LogicalArraySpec` are the portable scalar / enum /
array-shape / units / frame vocabulary needed by more than one domain:

```julia
LogicalType(:real; units = "m", frame = "box")
LogicalArraySpec(:coordinates, LogicalType(:real; units = "m"), 2; shape = (3, nothing))
```

They describe logical content, not HDF5 datatypes, paths, chunking, or
compression. They are not a place to store payload arrays.

## What this is not

- package payload schemas or payload bytes (domain packages / AH5 codecs)
- HDF5 layout, `.ah5` profile, or XDMF (later Episteme AH5 profile)
- `execute!` / `commit!` runtime and on-disk write recovery (#27 contract
  types are in [`archive-lifecycle.md`](archive-lifecycle.md))
- schema migration implementations (#41)
- content-hash algorithms (#42)
- software-environment manifests (#37)
- execution-context capture (#43)
- JLD2 working-archive I/O (portable documents are in
  [`portable-documents.md`](portable-documents.md))

`report` and `validate` on envelope types are read-only. `to_namedtuple`
covers the envelope records for later JSON or AH5 encoding. It does not
serialize package payloads.
