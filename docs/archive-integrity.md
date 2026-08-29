# AH5 revision-integrity persistence

Issue #77 persists the clean, successful revision-integrity manifests from #75
as an optional extension of the AH5 v1 profile.

## Backward-compatible optional feature

The core AH5 v1 roots and `ArchiveInspection` contract do not change.
Archives written without integrity metadata remain byte-layout compatible with
the existing profile and are inspected normally.

An archive that stores integrity manifests advertises the optional feature
`:integrity_manifest` and writes them beneath the fixed
`episteme/integrity` root. In this implementation the feature is deliberately
**not allowed in `required_features`**: an ordinary v1 reader that does not
know the optional extension may still inspect the core archive safely, but it
must not claim to have inspected the integrity records.

The optional records are requested explicitly:

```julia
core = inspect_archive(path)
integrity = inspect_archive(path, RevisionIntegrityManifest)
```

If the feature is not declared, the specialized inspector returns a valid
empty view. If the feature is declared but its root is missing or corrupt, the
specialized view fails closed.

## Writing

Use the positional overload to persist one or more validated manifests:

```julia
write_archive(path, manifest; graph=graph, schemas=schemas)
```

Only clean successful manifests are accepted. Invalid manifests, duplicate
revision ids, dependency diagnostics, or currently unsupported lossy artifact
metadata are refused before publication. The fixed integrity root is also
checked against custom AH5 core roots before the file is created.

The normal archive is created by the existing JLD2 writer first and the
optional integrity root is then appended with JLD2. If that append fails, the
new file is removed rather than leaving a partially published archive.

## Forensic representation

Integrity records use only `plain=true`-safe primitive columns. Each stored
revision records:

- revision id and requested external verification level;
- dependency kind and availability;
- object/revision/schema identities;
- expected `ContentId`;
- external artifact kind/path/URI/description when present;
- strongest external verification level actually established;
- bytes checked.

No payload bytes, domain types, live handles, or package-local objects are
stored in this optional root.

## Trust boundary

Persistence records the result of a prior integrity check; generic inspection
does not recompute hashes or re-open external artifacts. A fresh verification
still requires rebuilding or checking the revision integrity manifest at the
requested strength.

Payload persistence, reproduction-capsule packaging, migrations, and digital
signatures remain separate layers.
