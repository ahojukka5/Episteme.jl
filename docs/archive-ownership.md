# Shared scientific archive ownership

Accepted topology: issue
[#48](https://github.com/ahojukka5/OodiCore.jl/issues/48) /
[PR #50](https://github.com/ahojukka5/OodiCore.jl/pull/50).
The package rename is issue
[#51](https://github.com/ahojukka5/OodiCore.jl/issues/51).
The logical envelope from
[#26](https://github.com/ahojukka5/OodiCore.jl/issues/26)
is documented in [`archive-envelope.md`](archive-envelope.md).

This page supersedes the #25 two-package split (`OodiCore.jl` + standalone
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

JLD2 / `.ah5` writers are **not** in the rename PR. Current code still does
not open files.

See [`research/episteme-architecture.md`](research/episteme-architecture.md).

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
                    |  (later: JLD2    |
                    |   AH5 profile)   |
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
Episteme           ->  JLD2         (hard, later persistence PR)
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

### Episteme.jl — semantics, vocabulary, later AH5 profile

Safe to add here, as ordinary immutable structs and symbolic rules:

- object, revision, workflow-head, and content-identity types
- typed cross-object references and dangling-reference diagnostics
- namespace and package-identity records (stable UUID plus display name)
- schema-id / schema-version / compatibility-class records
- portable logical payload-schema facts needed for long-term
  interpretation: field/dataset name, logical scalar type,
  rank/shape/cardinality, required/optional, units/frame/support,
  reference target, and declared semantic constraints
- portable declarative-document envelope types (issue #34)
- software-environment and execution-context *record types* (#37, #43)
- canonical content-hash *rules* expressed as data (#42)
- migration source/target identifiers (#41)
- `to_namedtuple` for those records
- later: Plan/Run/Activity/Event/Revision records, JLD2-backed `.ah5`
  writer, inspect/verify/migrate/checkout

Episteme still does not (in current code, and never as domain meaning):

- know a geometry box, mesh, many-body state, experiment job, or model checkpoint
- execute untrusted script source
- introduce `provenance(x)` or `artifacts(x)` as new introspection
  generics; those names remain reserved and unimplemented

Logical envelope tests belong in this repository and must not require
HDF5. They also must not require JLD2 until the persistence PR.

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

Issue #41 defines a migration as a deterministic, domain-owned
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
under #42. A future schema must describe the data contract, not the HDF5
file.

## How domain packages depend

```toml
# typical domain Project.toml
[deps]
Episteme = "7c15cd61-9c6a-4671-bc94-9960963998ac"
```

```julia
using Episteme          # identities, tree, schemas; no JLD2 in this rename
# later persistence PR: using Episteme  also loads JLD2
# later HPC: using Episteme, HDF5   loads EpistemeHDF5Ext
```

Provider-free cores still must not load CAD, mesh, FEM, MPI, or a vendor
SDK. After the persistence PR, `using Episteme` *will* load JLD2; that is
the accepted v1 product.

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

## Where follow-up issues live

Logical contract first, then physical persistence in Episteme.

| Issue | Episteme types / rules | Later AH5 profile in Episteme |
| --- | --- | --- |
| #26 envelope, identities, references, schema-version rules | done | persist those records |
| #27 transactions / completion / restart | status, staging, write phases, restart refs | JLD2 markers, file locks, recovery |
| #28 XDMF views | none | generic writer; domain registers the projection recipe |
| #29 integrity and parallel-HDF5 qualification | none | `EpistemeHDF5Ext` after domain codecs exist |
| #30 revision history | revision identity types | graph storage |
| #31 purge / compaction | reachability as data | rewrite / new archive |
| #32 derived / debug artifacts | provenance record types | storage and retention flags |
| #33 checkout / lazy manifest | manifest types | selective reads |
| #34 portable declarative document | types | encoding inside `.ah5` |
| #35 reproduction capsules | capsule manifest types | packaging |
| #37 software-environment manifests | record types | `/provenance/software` storage |
| #38 namespaces | identity and reservation rules | path layout |
| #39 embedded schemas | logical schema facts + `NodeSchema` serialization | physical `/schemas` storage |
| #40 `.ah5` profile and generic inspect | profile metadata types | primary |
| #41 schema migrations | source/target identifiers | runner only; domain owns each transformation |
| #42 content hashes / verification | canonicalization rules | hash compute and verify |
| #43 execution-context fingerprint | record types and denylist data | storage |
| #44 event timeline / log streams | EventRecord, EventBatch, LogStreamRecord, event_timeline | JLD2/HDF5 append layout |

## Domain archive epics

The domain epics listed under #24 (Monge #328, Sorby #583, Delone #420,
Oodi #395, Stinespring #163, Lieb #65, Chappe #207) should:

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

Issue [#47](https://github.com/ahojukka5/OodiCore.jl/issues/47) studied
JLD2 as the Julia-native codec. Findings are in
[`research/jld2-ah5-spike/FINDINGS.md`](../research/jld2-ah5-spike/FINDINGS.md).
JLD2 is not a dependency of this package until the persistence PR.

Issue [#48](https://github.com/ahojukka5/OodiCore.jl/issues/48) is the
long-term architecture study (accepted). Issue
[#51](https://github.com/ahojukka5/OodiCore.jl/issues/51) is the rename.
Issue [#23](https://github.com/ahojukka5/OodiCore.jl/issues/23) is the
unmerged General registration of `OodiCore`; the next registration should
be for `Episteme`.
