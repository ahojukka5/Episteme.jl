# Shared scientific archive ownership

Accepted topology: one package, Episteme, after the rename of
`OodiCore.jl`. The logical envelope
is documented in [`archive-envelope.md`](archive-envelope.md).

This page supersedes the earlier two-package split (`OodiCore.jl` + standalone
`AH5.jl`). Logical-vs-physical remains a *subsystem* split inside Episteme.

## Decision

**Episteme.jl** is the scientific backbone. It owns:

1. The *logical* archive vocabulary now: object and revision identities,
   references, namespace and schema-version identifiers, portable
   declarative-document envelopes, and inspectable provenance/schema/integrity
   *record types*.
2. The AH5 archive/profile *next*: JLD2-backed `.ah5` persistence as a hard
   dependency of Episteme v1. HDF5.jl later as `EpistemeHDF5Ext` for bulk
   `/data` and MPI/parallel-HDF5. There is no standalone `AH5.jl` package.

Domain packages own scientific payloads, operation semantics, codecs, and
schema-migration *functions*. They must not grow package-local HDF5 archive
frameworks.

JLD2 / `.ah5` writers land in the persistence PRs. The profile writer
(`write_archive`) and generic `inspect_archive` belong to the [AH5 profile](archive-profile.md).

The historical architecture study is not stored in this package. The
current contract is this page and [`archive-profile.md`](archive-profile.md).

## v1 mental model

```text
Episteme.jl = semantics + schemas + history/provenance
            + orchestration protocol
            + JLD2-backed AH5 persistence
```

Shared infrastructure kinds use `:episteme` / `episteme/*`
(`episteme/script` today; `episteme/document` and `episteme/plan` when those
types land). Domain kinds stay with the owning package (`monge/*`,
`delone/*`, `oodi/*`, `lieb/*`, …).

## Ownership diagram

```text
                    +------------------+
                    |   Episteme.jl    |
                    |                  |
                    |  report/validate |
                    |  SemanticNode    |
                    |  NodeSchema      |
                    |  archive types   |
                    |  JLD2 AH5 profile|
                    +--------+---------+
                             ^
                             | depends on
                             |
     +-----------+-----------+-----------+-----------+
     |           |           |           |           |
 +---+---+   +---+---+   +---+---+   +---+---+   +---+---+
 | Monge |   | Delone|   |  Oodi |   | Lieb  |   |Chappe |
 | Sorby |   |       |   |       |   |Stines.|   |  ...  |
 +-------+   +-------+   +-------+   +-------+   +-------+
     domain payload schemas and codecs stay here
```

Allowed edges:

```text
domain package     ->  Episteme     (hard or weak, package choice)
Episteme           ->  JLD2         (weak; episteme_jld2_ext, v1 persistence)
EpistemeHDF5Ext    ->  Episteme + HDF5.jl   (later; bulk /data, MPI)
EpistemeXDMFExt    ->  Episteme + XML       (optional view layer)
EpistemeMPIExt     ->  Episteme + MPI       (optional; typically with HDF5Ext)
```

Forbidden edges:

```text
Episteme           ->  any domain package
domain A           ->  domain B     merely to read archive identities
domain package     ->  HDF5.jl      as a private archive framework
```

Dependencies flow one way: into Episteme's consumers.

## What each layer owns

### Episteme.jl — semantics, vocabulary, and AH5 profile

Safe to add here, as ordinary immutable structs and symbolic rules:

- object, revision, workflow-head, and content-identity types
- typed cross-object references and dangling-reference diagnostics
- namespace and package-identity records (stable UUID plus display name)
- schema-id / schema-version / compatibility-class records
- portable logical payload-schema facts needed for long-term
  interpretation: field/dataset name, logical scalar type,
  rank/shape/cardinality, required/optional, units/frame/support,
  reference target, and declared semantic constraints
- [portable declarative-document](portable-documents.md) envelope types
- software-environment and execution-context *record types* ([software-environment manifests](software-environments.md), [execution-context records](execution-contexts.md))
- canonical content-hash *rules* expressed as data ([content integrity](content-integrity.md))
- migration source/target identifiers ([schema migration](schema-migration.md))
- `to_namedtuple` for those records
- Plan/Run/Activity/Event/Revision records
- JLD2-backed `.ah5` writer and generic `inspect_archive`

Episteme still does not (in current code, and never as domain meaning):

- know a geometry box, mesh, many-body state, experiment job, or model checkpoint
- execute untrusted script source
- introduce `provenance(x)` or `artifacts(x)` as new introspection
  generics; those names remain reserved and unimplemented

Logical envelope tests belong in this repository and must not require
HDF5. Profile I/O tests may use JLD2.

### Domain packages — payload schemas and codecs

Monge, Sorby, Delone, Oodi, Stinespring, Lieb, Chappe, and future
packages own:

- their scientific payload types and schema definitions
- package-qualified kinds such as `example/model-state` or `example/field`
- read/write codecs that encode those payloads into the AH5 profile
- schema-migration *implementations* (`oodi/field` 1.0 → 2.0, Delone
  mesh 2 → 3, and so on), registered with Episteme and executed by its
  later runner
- XDMF/visualization *projection recipes*
- which workflow events are worth recording
- whether Episteme is a hard dependency or a weak extension

They do not own a second object/revision/reference envelope, a second
`.ah5` profile, or a private HDF5 transaction protocol.

## Boundaries that must not blur

These three splits are easy to collapse later and must stay explicit.

### Domain migrations versus the Episteme runner

A [schema migration](schema-migration.md) is as a deterministic, domain-owned
transformation from one schema id/version to another. Episteme owns only the
shared machinery around that transformation:

- registry keyed by package namespace + schema id + source/target
  versions
- chain/cycle/ambiguity checks
- dry-run/plan
- provenance (implementation identity, source/target hashes)
- writing a new archive or new immutable objects; never silently
  rewriting the only copy

The function that knows what `oodi/field` 1.0 means, and how to produce
a 2.0 object from it, lives in Oodi (typically `OodiEpistemeExt`). The same
rule applies to Delone meshes, Stinespring posteriors, Lieb sectors, and
every other payload. Episteme looks up the registered migration and runs it.
If no owning package/plugin is loaded, it reports which one is required
and stops. It must not grow a table of domain-specific rewrite rules.

### XDMF serialization versus domain projection

Episteme's optional XDMF layer owns the generic XDMF/XMF writer, shared
naming/reference conventions, and the view runtime that emits lightweight
`.xmf` over existing AH5 datasets. It does not decide scientific visualization
meaning.

The owning domain package registers the projection recipe for its
payloads. Without that recipe, Episteme can still inspect the archive; it
must not invent a mesh or field interpretation in order to write XMF.

Existing Oodi `write_xdmf` / `OodiWriteXDMFExt` is visualization interchange
for an Oodi mesh-plus-fields pair. It is not the scientific archive and must
not grow into a competing HDF5 framework.

### Logical schema versus physical layout

A stored scientific object remains interpretable from portable schema
data even when the physical layout later changes. Logical facts belong with
the payload schema, not with the container:

- field/dataset name
- logical scalar type
- rank, shape, and cardinality
- required versus optional
- units, coordinate frame, support, and location
- reference target
- declared semantic constraints

The AH5 profile owns only physical encoding of those facts. Changing
chunking or compression must not change the scientific object identity
under [content integrity](content-integrity.md). A future schema must describe the data contract, not the HDF5
file.

## How domain packages depend

```toml
# typical domain Project.toml
[deps]
Episteme = "7c15cd61-9c6a-4671-bc94-9960963998ac"
```

```julia
using Episteme          # identities, tree, schemas: stdlib only
using Episteme, JLD2    # AH5 profile I/O; loads episteme_jld2_ext
# later HPC: using Episteme, HDF5   loads EpistemeHDF5Ext
```

Provider-free cores still must not load CAD, mesh, FEM, MPI, or a vendor
SDK. JLD2 is a `[weakdeps]` package, so `using Episteme` loads no
non-stdlib code and a consumer that calls no archive API pays nothing for
the persistence track. `using JLD2` activates `episteme_jld2_ext`, which owns
every writer and reader that opens a file; without it those entry points
fail closed with an error naming the function.

## Schema and codec registration

Episteme must not import domain packages. Registration is pushed from the
domain side when both packages are loaded (conceptual; exact API is later
work):

```julia
register_codec!(namespace, schema_id, schema_version, reader, writer)
register_migration!(namespace, source_schema, target_schema, migrate)
register_xdmf_projection!(namespace, schema_id, schema_version, project)
```

A missing codec, migration, or projection is not an archive identity failure:

- generic inspection reads the `.ah5` profile, namespaces, embedded
  logical schemas, software-environment summaries, and revision index
  from Episteme types stored in the file
- payload *interpretation* into live domain types requires the domain package
- an unknown namespace or schema is reported as such

## Where the remaining work lives

Logical contract first, then physical persistence in Episteme.

| Area | Episteme types / rules | Later AH5 profile in Episteme |
| --- | --- | --- |
| envelope, identities, references, schema-version rules | done | persist those records |
| transactions / completion / restart | status, staging, write phases, restart refs | JLD2 markers, file locks, recovery |
| XDMF views | XdmfDataset, XdmfGrid, attributes, sets, collections | read-only numeric qualification and metadata writer; domain owns the recipe ([contract](archive-views.md)) |
| integrity and parallel-HDF5 qualification | none | `EpistemeHDF5Ext` after domain codecs exist |
| revision history | revision identity types | graph storage |
| purge / compaction | RetentionRoot, plan_purge, compact_archive | physical rewrite / new `.ah5` |
| derived / debug artifacts | provenance record types | optional `episteme/derived_artifacts` records |
| checkout / lazy manifest | RevisionManifest, inspect, in-memory checkout | selective payload reads |
| portable declarative document | PortableSemanticDocument capture, sexpr view | encoding inside `.ah5` |
| reproduction capsules | capsule manifest types | packaging |
| software-environment manifests | record types | `/provenance/software` storage |
| namespaces | identity, reservation, aliases, listing | path layout |
| embedded schemas | SchemaDefinition, SchemaRegistry, listing | `/episteme/schemas` in the [AH5 profile](archive-profile.md) |
| `.ah5` profile and generic inspect | ArchiveProfile, write_archive, inspect_archive | primary |
| schema migrations | source/target identifiers | runner only; domain owns each transformation |
| content hashes / verification | canonicalization rules | hash compute and verify |
| execution-context fingerprint | record types and denylist data | storage |
| event timeline / log streams | EventRecord, EventBatch, LogStreamRecord, event_timeline | JLD2/HDF5 append layout |

## Domain archive epics

Domain packages that persist scientific state (Monge, Sorby, Delone, Oodi,
Stinespring, Lieb, Chappe) should:

- depend on Episteme rather than starting a package-local HDF5 layer
- put payload schemas next to the domain operations they describe
- register codecs, schema migrations, and XDMF projection recipes
  through an `*EpistemeExt` extension
- treat existing visualization writers (VTU, XDMF, native checkpoints) as
  interchange or external artifacts, not as the provenance database

## Non-goals of this page

- implementing JLD2 or an HDF5 writer in the rename PR
- creating an `AH5.jl` repository
- choosing exact HDF5 paths, chunking, or hash algorithms
- forcing every domain package to hard-depend on Episteme
- replacing Oodi's existing mesh/field visualization exporters

## Related study

A spike studied
JLD2 as the Julia-native codec. The historical spike is not stored in
this package. JLD2 is a weak dependency for the v1 `.ah5` profile.
`using JLD2` activates the file I/O methods in `episteme_jld2_ext`.

The long-term architecture study was accepted, and the package was renamed
from `OodiCore` to `Episteme`. The General registration of `OodiCore` was never merged; the next
registration should be for `Episteme`.
