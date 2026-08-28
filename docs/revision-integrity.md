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

## Schema integrity

Each exact schema referenced by selected objects produces one schema row. Its
`content_id` is the canonical logical hash from #71. Package release version
and physical AH5/JLD2 representation are not part of that identity.

The selected schema definition is validated before hashing, and object/schema
namespace UUID disagreement fails closed. A missing exact schema is distinct
from a missing object or unavailable external artifact.

## Deliberate non-goals

This slice does not yet persist the integrity manifest into AH5 and does not
package a reproduction capsule. Those are the next layers after #75; migration
execution and signatures remain separate concerns.
