# Revision-scoped dependency integrity

Revision integrity manifests are the third part of [content integrity](content-integrity.md). They combine the
selected-revision closure from [lazy checkout](archive-checkout.md), canonical logical hashes from [canonical content hashing](content-integrity.md), and
external verification from [external-artifact verification](external-integrity.md) into one fail-closed integrity view.

## Scope

`integrity_manifest` starts from a `RevisionManifest` or from an
`ArchiveGraph + RevisionId`. It never scans unrelated branches. The dependency
rows are deterministic and cover:

- archived object envelopes, carrying the expected object `ContentId`;
- exact embedded schema definitions, carrying their canonical schema hash;
- declared external dependencies, carrying their expected `ContentId` and the
  strongest `:metadata`, `:sample`, or `:full` verification level actually
  established.

Envelope-only object payload bytes are not loaded and therefore are never
reported as byte-verified. A missing object `ContentId` fails closed because a
historical state cannot later prove that payload content still matches the
recorded scientific state.

## External verification strength

The manifest-level `requested_level` applies to external artifacts. Each
external row records `verified_level` and `bytes_checked`, preserving the rule of
[external-artifact verification](external-integrity.md) that a metadata or sampled check must never be presented as full-byte
verification.

`report(manifest)` includes `external_bytes_checked`, the sum of the external
rows' byte counts. It is zero for an empty manifest or a revision containing
only embedded objects and schemas; those cases do not require external I/O.

## Schema integrity

Each exact schema referenced by selected objects produces one schema row. Its
`content_id` is the canonical logical hash from [canonical content hashing](content-integrity.md). Package release version
and physical AH5/JLD2 representation are not part of that identity.

The selected schema definition is validated before hashing, and object/schema
namespace UUID disagreement fails closed. A missing exact schema is distinct
from a missing object or unavailable external artifact.

## Persistence and capsules

[AH5 integrity persistence](archive-integrity.md) stores clean, successful
manifests through the JLD2 extension. Inspection reads the recorded result.
`verify_integrity` rebuilds the current dependency report at an explicit
`:metadata`, `:sample`, or `:full` level and checks whether each `ContentId`
was preserved. A metadata or sample live check is never reported as `:full`.
[Capsule planning](capsule-planning.md) and
[reproduction capsule publication](capsule-archives.md) consume this evidence.
A published capsule may embed portable state whose canonical identity matches
these rows. It does not promise execution readiness unless that state, the
recorded dependencies, and the manifest agree. Migration execution belongs to
[schema migration](schema-migration.md); signatures remain out of scope.
