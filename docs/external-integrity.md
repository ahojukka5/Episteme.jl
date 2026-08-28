# External artifact integrity verification

This is the local-file verification slice of parent issue #42, tracked by #73.
It builds on canonical content identity without requiring large authoritative
external files to be rehashed on every archive inspection.

## Capture once, verify explicitly

`capture_external_integrity(requirement)` performs one full streaming SHA-256
pass and stores an immutable `ExternalIntegrityRecord` containing:

- object and artifact references;
- the full byte `ContentId`;
- expected byte size;
- deterministic sample ranges and their fingerprint.

If `ExternalRequirement.content_id` is already declared, capture fails unless
it matches the observed full byte hash.

## Verification levels

`verify_external(record; level=...)` always reports both the requested level
and the strongest level actually established, plus `bytes_checked`.

| Level | What is checked | Content bytes hashed |
| --- | --- | ---: |
| `:metadata` | local-file availability and exact byte size | 0 |
| `:sample` | metadata plus deterministic sampled ranges | sampled bytes only |
| `:full` | metadata plus full streaming SHA-256 | entire file |

A successful metadata or sample check is intentionally **not** reported as a
full verification. Same-size changes outside sampled ranges can pass a sample
check; a full check detects them.

Missing external data (`:external_artifact_missing`) is distinct from an
observed byte mismatch (`:external_sample_mismatch` or
`:external_hash_mismatch`) and from a size mismatch
(`:external_size_mismatch`).

## Scope boundary

This slice verifies local `ArtifactRef.path` files only. It does not fetch
remote URIs, persist integrity manifests in AH5, or aggregate a complete
revision/capsule dependency-integrity report. Those remain later #42 work.
