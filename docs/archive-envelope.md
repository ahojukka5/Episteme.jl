# Shared archive envelope

This is the logical object/reference/schema-version contract from issue
[#26](https://github.com/ahojukka5/OodiCore.jl/issues/26). It lives entirely
in OodiCore and does not open files. Physical `.ah5` encoding is AH5.jl;
see [`archive-ownership.md`](archive-ownership.md).

The envelope lets independently owned package payloads share one archive
without depending on each other or on package-native runtime handles.

## Four identities

These are different types on purpose. Equal byte strings do not make them
the same kind of identity.

| Type | Meaning |
| --- | --- |
| `ObjectId` | Stable logical object. Revisions of the same mesh share it. |
| `RevisionId` | One immutable snapshot or workflow revision. Never reused. |
| `ContentId` | Logical content identity. Layout/chunking/compression do not belong here; hash rules are #42. |
| `WorkflowHeadId` | Movable bookmark. The id stays put when the head points at a new revision. |

`RunId`, `SoftwareEnvironmentId`, and `ExecutionContextId` are additional
reference ids. This package stores the ids only. Software manifests are
#37 and execution fingerprints are #43.

```julia
object = ObjectId("mesh-1")
content = ContentId("mesh-1")
object != content          # distinct types
object.value == content.value
```

## Envelope

`ArchiveObject` is the shared wrapper. Domain packages put only portable
payload fields in `extras`.

```julia
mesh = ArchiveObject(
    ObjectId("mesh-1"),
    RevisionId("rev-mesh");
    namespace = ArchiveNamespace(:delone; display_name = "Delone.jl"),
    kind = Symbol("delone/mesh"),
    schema = SchemaRef(:delone, "mesh", "1.0.0"),
    references = [ArchiveReference(:geometry, ObjectId("geom-1"))],
    extras = (; nelements = 12),
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
OodiCore never interprets `extras`.

`WorkflowHead` is a bookmark `(id, name, revision_id)`. Moving the head
does not change historical objects.

`ArchiveGraph` holds objects and heads. Insertion order is not
authoritative. `ordered_objects`, `ordered_references`, and
`ordered_heads` sort by identity so later HDF5 group order cannot leak
into the logical model.

## References

`ObjectRef` and `ArchiveReference` identify a target by `ObjectId`,
optionally pinned to a `RevisionId`. They are not HDF5 paths. Appending
an unrelated object does not invalidate an existing reference.

`validate(graph)` reports `:dangling_reference` when the target object or
pinned revision is absent. An unpinned reference resolves if any revision
of that object exists. Producer revisions and workflow heads are checked
the same way.

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
compression.

## What this is not

- package payload schemas (domain packages)
- HDF5 layout, `.ah5` profile, or XDMF (AH5.jl)
- schema migration implementations (#41)
- content-hash algorithms (#42)
- software-environment manifests (#37)
- execution-context capture (#43)
- portable `SemanticNode` documents (#34)

`report` and `validate` on envelope types are read-only. `to_namedtuple`
covers the envelope records for later JSON or AH5 encoding.
