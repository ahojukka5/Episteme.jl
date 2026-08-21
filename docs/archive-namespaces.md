# Package namespaces and reserved shared namespaces

This is the logical namespace contract from issue
[#38](https://github.com/ahojukka5/Episteme.jl/issues/38). It lives in
Episteme as identity records, a claim registry, listing, and `validate`.
It does not open files or choose HDF5/JLD2 group paths.

Physical path spelling is issue
[#40](https://github.com/ahojukka5/Episteme.jl/issues/40). Namespace
identity is logical and must not be equated with a group path.

## Ownership

| Role | Who | Namespace | Kinds |
| --- | --- | --- | --- |
| shared | Episteme | `:episteme` | `episteme/*` only |
| domain | a scientific package | that package's id | `id/kind` |
| extension | an optional integration | its own id | never another package's prefix |

A package may not write semantic fields, kinds, or schemas into another
package's namespace. Optional XDMF/HDF5/plugin layers get an explicit
extension namespace instead of mutating a domain schema.

Cross-package links use [`ObjectId`](archive-envelope.md) /
[`ArchiveReference`](archive-envelope.md), never physical paths. Reordering
objects or later changing AH5 group layout does not change those links.

## Identity

`ArchiveNamespace` carries three facts:

| Field | Role |
| --- | --- |
| `id` | current short name (`:delone`, `:episteme`) |
| `package_uuid` | stable identity when known (Julia package UUID) |
| `display_name` | human label (`"Delone.jl"`); never identity |

When `package_uuid` is non-empty, it is identity. A display-name or
repository rename keeps the same UUID and does not mint a new namespace.
When the UUID is unknown, `id` is identity.

```julia
ArchiveNamespace(
    :delone;
    package_uuid = "11111111-1111-4111-8111-111111111111",
    display_name = "Delone.jl",
)

episteme_namespace()  # :episteme + Episteme's package UUID
```

`kind` is package-qualified (`schema_kind(:delone, "mesh") ==
Symbol("delone/mesh")`) and must be owned by the object's namespace.

## Reserved names

`RESERVED_SHARED_NAMESPACES` is `(:episteme,)`. Only Episteme may claim
it, with `role = :shared` and UUID
`7c15cd61-9c6a-4671-bc94-9960963998ac` when a UUID is recorded.

`RESERVED_ARCHIVE_AREAS` are logical profile areas, not package
namespaces and not paths:

```text
profile provenance schemas revisions runs events heads objects content payloads
```

A package may not register one of those names as its namespace `id`.
Reserved shared names such as `:episteme` also cannot appear in another
identity's `aliases` list or as the short name of an alias claim.
Exact `.ah5` spelling remains #40.

## Aliases

A renamed short name is an alias of the same UUID, not a new identity.

```julia
registry = NamespaceRegistry([
    NamespaceClaim(
        episteme_namespace();
        role = :shared,
        aliases = (:oodicore,),
    ),
    NamespaceClaim(
        ArchiveNamespace(:oodicore; package_uuid = EPISTEME_PACKAGE_UUID);
        role = :shared,
        status = :alias,
        canonical_id = :episteme,
    ),
])

resolve_namespace(registry, :oodicore).namespace.id === :episteme
```

Display-name changes do not need an alias. Changing `id` without keeping
the UUID, or claiming another package's UUID, is a conflict.

## Listing

`list_namespaces(graph)` (also `RevisionManifest` and a registry) returns
`NamespaceListing` rows: identity, display metadata, role/status, aliases,
and the observed `kinds` / `schema_ids`. It does not load payloads.

```julia
list_namespaces(graph)
list_namespaces(inspect(graph, revision_id), registry)
```

## Validation

`validate` reports structured diagnostics and does not throw:

| Code | Meaning |
| --- | --- |
| `:reserved_namespace_claimed` | domain/extension claimed `:episteme`, including as an alias |
| `:reserved_archive_area_claimed` | package id is a reserved profile area |
| `:reserved_kind_claimed` | `episteme/*` kind under a non-Episteme namespace |
| `:kind_namespace_mismatch` | kind prefix is not the object's namespace |
| `:namespace_identity_conflict` | same short name, different package UUIDs |
| `:namespace_identity_missing` | registry UUID present; object omitted it |
| `:namespace_id_split` | same UUID, different short names, no alias |
| `:namespace_alias_unresolved` | alias `canonical_id` is missing |
| `:namespace_alias_uuid_mismatch` | alias UUID does not match canonical |
| `:namespace_alias_role_mismatch` | alias role does not match canonical |
| `:duplicate_namespace_claim` | two claims (active or alias) for one short name |
| `:shared_namespace_role_mismatch` | `:shared` used off `:episteme` |

`validate(graph, registry)` accepts UUID-preserving aliases declared in
the registry. When a claim records a package UUID, objects that use that
namespace or alias must carry the same UUID; omitting it is
`:namespace_identity_missing`. `readiness(registry, PipelineTarget(:inspect))`
is true when the registry itself is valid.

## What this is not

- HDF5/JLD2 path layout or `/episteme` group spelling (#40)
- embedded payload-schema registry (#39)
- codec registration
- a scientific meaning for anything inside a domain namespace
