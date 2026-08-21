# AH5 profile, root signature, and generic inspector

This is the JLD2-backed `.ah5` profile from issue
[#40](https://github.com/ahojukka5/Episteme.jl/issues/40). `.ah5` means
Episteme's versioned scientific archive profile. It is not a new binary
format and not a separate Julia package.

JLD2 **creates** the file. JLD2 owns `/_types`. Episteme owns `/episteme`.
HDF5.jl is not required for this profile; bulk `/data` and parallel I/O
remain a later `EpistemeHDF5Ext` path that must still start from a
JLD2-created file.

## Identity

Profile identity is in-file metadata, not the filename extension.

```text
magic            AH5
profile_version  1.0.0   (independent of Episteme and payload-schema versions)
archive_id       UUID
created_at       UTC timestamp
creator          label
features         capability flags present in the file
required_features  flags a reader must understand before domain payloads
package_version  Episteme provenance only
```

Renaming `study.ah5` to `study.bin` does not drop identity.
An unrelated HDF5 file renamed `.ah5` is not an AH5 archive.

## Physical layout

Reserved package-namespace *names* from issue #38 stay logical. The
profile spells the inspectable Episteme area as JLD2 keys (HDF5 groups):

```text
/episteme/profile      ArchiveProfile
/episteme/namespaces   NamespaceListing rows
/episteme/schemas      SchemaListing rows
/episteme/history      counts and workflow head names
/episteme/provenance   software/execution identity summaries
/episteme/externals    declared external artifact requirements
/_types                JLD2 representation metadata (not schema identity)
```

`write_archive` stores `plain=true`-safe values (strings, numbers, booleans,
and vectors of those), not live domain types. Indexed listings live at
`{root}/count` and `{root}/1`, `{root}/2`, … so forensic JLD2 can read them
without reconstructing Julia structs. `inspect_archive` opens the file with
`plain=true`, reads only `/episteme/profile` first, and decodes remaining
roots only after the profile is compatible. JLD2 `/_types` remains Julia
representation metadata, not schema identity.

Feature flags name capabilities **present in the file**. The v1 writer always
creates the five inspectable groups, so published archives advertise
`:jld2_writer`, `:namespaces`, `:embedded_schemas`, `:history`,
`:provenance`, and `:externals`. `required_features` must be a subset of
`features`. Custom `ArchiveProfileRoots` are honored; the profile record
itself stays at `/episteme/profile`.

Logical graph/schema/namespace metadata is validated before the file is
created. A graph that references a missing embedded schema is refused.

## Writer and inspector

```julia
write_archive(path; graph, namespaces, schemas, externals, profile)
inspection = inspect_archive(path)
is_ah5_archive(path)
```

`inspect_archive` reports profile/version/archive id, namespaces, schema
ids/versions/compatibility and field/`NodeSchema` structure, history
counts, provenance summaries, external requirements, and structured
diagnostics. It does not load domain packages or payload bytes.

Unsupported future profile majors, unknown `required_features`, and
required flags that are not declared present fail closed
(`:unsupported_profile_version`, `:unsupported_required_feature`,
`:required_feature_missing`) before remaining roots are decoded.

XDMF views (#28) must treat the extension as advisory and qualify
datasets from in-file AH5 identity.

## What this is not

- HDF5.jl bulk `/data` or MPI/parallel writes (`EpistemeHDF5Ext`)
- payload codecs or domain migrations (#41)
- content-hash verification (#42)
- software-environment or execution-context *manifest* capture (#37, #43)
- file-path `checkout` of payload bytes (#33)
- a new container format or sidecar identity file
