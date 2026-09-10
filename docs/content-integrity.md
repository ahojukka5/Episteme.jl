# Canonical logical content identity

Episteme provides domain-neutral canonical hashing for shared metadata and
portable logical values. This guide describes logical content identity;
[external-file verification](external-integrity.md),
[revision dependency manifests](revision-integrity.md), and
[AH5 integrity persistence](archive-integrity.md) build on that contract.

## Identity model

`ObjectId`, `RevisionId`, and `ContentId` are distinct. Two different logical
objects may have the same `ContentId`, and unchanged content may be reused in
multiple revisions without acquiring a new content identity.

A canonical content hash is independent of physical representation details
such as JLD2/HDF5 path, chunking, compression, array eltype when the logical
values are equal, dictionary insertion order, and NamedTuple field order.

```julia
id = canonical_content_id((; values = [1, 2, 3], units = "m"))
# ContentId("sha256:...")
```

The canonical byte format is versioned by `CanonicalHashPolicy`. Changing the
canonicalization rules requires a new policy version rather than silently
reusing old identities.

## Shared normalization

The v1 encoder uses explicit type and length tags. In particular:

- integer storage width is ignored (`Int32(7)` and `Int64(7)` are equal);
- Float16/32/64 values are compared through their Float64 logical value;
- signed zero is normalized;
- arrays include rank/shape and ordered values but not Julia `eltype`;
- dictionaries are sorted by canonical key bytes and reject canonical-key
  collisions;
- NamedTuple fields are sorted by name;
- strings and symbols are length-delimited, not separator-packed.

Unsupported runtime values fail closed.

## Domain extension hook

Domain packages own the scientific projection of their payloads. They extend
`canonical_content` and return only portable logical content:

```julia
Episteme.canonical_content(x::MyPayload) = (
    geometry = x.geometry,
    values = x.values,
    units = x.units,
)
```

Caches, file paths, GPU handles, communicators, provider clients, and other
incidental runtime representation must not appear in that projection.

## Schema definitions

`SchemaDefinition` hashing includes exact schema id/version, stable namespace
identity, compatibility, fields, node schema, documentation, and
migration/replacement relations. Package release version and namespace display
name are excluded because they are provenance/human labels rather than schema
content.

## Verification and persistence

Use `capture_external_integrity` and `verify_external` for authoritative local
files. Their explicit `:metadata`, `:sample`, and `:full` levels report the
strength and byte cost actually established. A logical metadata hash alone
does not verify the external bytes that metadata describes.

`integrity_manifest` checks a selected revision's dependency closure. Successful
manifests can be persisted in AH5 through the JLD2 extension; reading a stored
result does not repeat the verification. [Metadata capsules](capsule-archives.md)
can retain this evidence, but do not embed scientific payload bytes or establish
execution readiness.

Semantic migration chains remain tracked by issue #41. Digital signatures and
PKI are outside the content-integrity contract in issue #42.
