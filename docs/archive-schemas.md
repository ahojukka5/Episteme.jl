# Embedded payload schemas and compatibility metadata

This is the logical embedded-schema contract from issue
[#39](https://github.com/ahojukka5/Episteme.jl/issues/39). An archive
must carry the exact machine-readable schema revisions needed to
interpret its portable/shared records and any domain payload that opts
into schema-based generic inspection.

Physical `/episteme/schemas` spelling is in
[`archive-profile.md`](archive-profile.md). Migration *execution* is issue
[#41](https://github.com/ahojukka5/Episteme.jl/issues/41).

JLD2 `/_types` describes Julia representation. It is not the scientific
schema registry and is not consulted for schema identity.

## Identity

A schema revision is a [`SchemaRef`](archive-envelope.md): owning
namespace, immutable schema id, and semantic schema version. Package
SemVer is recorded on `SchemaDefinition.package_version` as provenance
only. Changing it does not mint a new schema.

```julia
SchemaRef(:delone, "mesh", "1.0.0") != SchemaRef(:delone, "mesh", "2.0.0")
SchemaDefinition(schema; namespace, package_version = "0.4.0")
SchemaDefinition(schema; namespace, package_version = "9.9.9").schema == schema
```

## What is embedded

`SchemaDefinition` is the exact revision stored in the archive:

| Fact | Where |
| --- | --- |
| owner | `ArchiveNamespace` (UUID + display name; see [namespaces](archive-namespaces.md)) |
| schema id/version | `SchemaRef` |
| compatibility | `:exact_read`, `:backwards_compatible`, `:migration_required`, `:unsupported` |
| fields | `SchemaField` — name, `LogicalType` / rank / shape, required, cardinality, units/frame/support/location, reference target, `ValidationRule`s |
| semantic-node shape | optional `NodeSchema` (the #34/#12 portable node contract) |
| replacement | optional `replaces` / `replaced_by` `SchemaRef`s |
| migration pointer | optional `SchemaMigrationRef` (source, target, implementation id) |

Embed only the revisions the archive needs. Chunking, compression, and
HDF5 paths are not part of the schema.

```julia
SchemaField(
    LogicalArraySpec(:coordinates, LogicalType(:real; units = "m", frame = "box"), 2; shape = (3, nothing));
    support = "mesh",
    location = "vertex",
)
```

## Registry and inspection

`SchemaRegistry` holds those definitions. `list_schemas(registry)` (also
with an `ArchiveGraph` or `RevisionManifest`) returns `SchemaListing`
rows: identity, compatibility, portable `SchemaField`s (logical type,
units/frame, rank/shape, cardinality, support/location, reference target,
rules, documentation), the optional portable `NodeSchema` (attribute
names/types, required/`allow_ref`, rules, `allow_extra`, node-local
rules), and migration/replacement pointers. It does not load payloads or
import domain packages.

`validate(schemas, namespaces)` and `validate(graph, schemas, namespaces)`
apply #38 identity rules: a registered package UUID is required, aliases
are accepted, and two definitions cannot share a short name with different
UUIDs.

`known_schemas(registry)` projects identity+compatibility into an
[`ArchiveCatalog`](archive-envelope.md) for the existing envelope lookup
API. That catalog still does not contain JLD2 type names.

## Validation

`validate` reports structured diagnostics and does not throw:

| Code | Meaning |
| --- | --- |
| `:missing_schema` | object names a `SchemaRef` that is not embedded |
| `:unsupported_schema` | embedded compatibility is `:unsupported` |
| `:migration_required` | compatibility is `:migration_required` |
| `:missing_migration_ref` | that compatibility is set but no `SchemaMigrationRef` is stored |
| `:corrupt_schema` | definition is empty, duplicate, self-replacing, or has contradictory replacement/migration links |
| `:duplicate_schema` | the same `SchemaRef` is embedded twice |
| `:namespace_identity_conflict` | same short namespace name with different package UUIDs |
| `:namespace_identity_missing` | registered owner UUID omitted from a schema namespace |
| `:payload_schema_violation` | a portable NamedTuple/SemanticNode payload breaks the declared fields or `NodeSchema` |

`validate(graph, registry)` checks the graph envelope plus that every
object schema is embedded and readable. `validate(payload, definition)`
and `validate(node, definition)` check portable content against one
definition. Live `SemanticNode` trees may still hold values that have no
portable schema; those fail closed on capture (#34), not here.

`readiness(registry, PipelineTarget(:inspect))` is true when the
registry itself is valid.

## What this is not

- running domain migrations (#41)
- treating JLD2 struct reconstruction as scientific compatibility
- requiring every live Julia value to have a portable schema
