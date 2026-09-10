# Revision-scoped dependency integrity

Issue #75 is the third focused slice of parent issue #42. It combines the
selected-revision closure from #33, canonical logical hashes from #71, and
external verification from #73 into one fail-closed integrity view.

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
external row records `verified_level` and `bytes_checked`, preserving #73's
rule that a metadata or sampled check must never be presented as full-byte
verification.

`report(manifest)` includes `external_bytes_checked`, the sum of the external
rows' byte counts. It is zero for an empty manifest or a revision containing
only embedded objects and schemas; those cases do not require external I/O.

## Schema integrity

Each exact schema referenced by selected objects produces one schema row. Its
`content_id` is the canonical logical hash from #71. Package release version
and physical AH5/JLD2 representation are not part of that identity.

The selected schema definition is validated before hashing, and object/schema
namespace UUID disagreement fails closed. A missing exact schema is distinct
from a missing object or unavailable external artifact.

## Persistence and capsules

[AH5 integrity persistence](archive-integrity.md) stores clean, successful
manifests through the JLD2 extension. Inspection reads the recorded result;
fresh verification requires checking the current dependencies again.
[Capsule planning](capsule-planning.md) and
[metadata capsule publication](capsule-archives.md) consume this evidence.
Published metadata capsules do not embed scientific payload bytes or promise
execution readiness. Migration execution and signatures remain separate concerns.
