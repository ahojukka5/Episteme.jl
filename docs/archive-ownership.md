# Shared scientific archive ownership

This is the ownership and dependency decision for issue
[#25](https://github.com/ahojukka5/OodiCore.jl/issues/25) under epic
[#24](https://github.com/ahojukka5/OodiCore.jl/issues/24). The logical
envelope from [#26](https://github.com/ahojukka5/OodiCore.jl/issues/26)
is documented in [`archive-envelope.md`](archive-envelope.md). Physical
`.ah5` I/O remains AH5.jl work.

## Decision

Split the shared archive into two packages:

1. **OodiCore.jl** owns the dependency-free *logical* archive vocabulary:
   object and revision identities, references, namespace and schema-version
   identifiers, portable declarative-document envelopes, and the
   inspectable provenance/schema/integrity *record types* needed by more
   than one domain.
2. **AH5.jl** is the dedicated shared archive *implementation*. It owns
   the `.ah5` profile, HDF5 physical encoding, generic XDMF
   serialization/view runtime, transactions, integrity verification,
   migration *runners*, generic inspection, compatibility fixtures, and
   the runtime codec/migration/projection registry.

OodiCore must not depend on HDF5, XML, MPI, or any domain package. Domain
packages must not grow package-local HDF5 archive frameworks. Lieb, Chappe,
Stinespring, Oodi, and the rest persist through AH5.jl.

This is the later architectural expansion contemplated by `AGENTS.md`:
archive identity and provenance *types* may live in OodiCore; file-format
backends still do not.

## Why this split

OodiCore is already the shared contract package. Downstream packages
either depend on it directly or, like Chappe, load it only through a weak
extension. Archive identities, references, and schema-version rules are
the same kind of domain-neutral data as `NodeRef` and `NodeSchema`. Issue
[#26](https://github.com/ahojukka5/OodiCore.jl/issues/26) can therefore
proceed here without waiting for a new repository and without requiring
HDF5 in tests.

Physical I/O cannot live here. `AGENTS.md` forbids file-format backends
and heavy native dependencies. Putting HDF5.jl in OodiCore would force
every `using OodiCore` path — including provider-free Chappe and
core-only Lieb — to load HDF5. Putting the writer in Oodi.jl would force
Lieb and Stinespring to depend on a FEM solver package merely to read
common identities.

A third option — one new package that owns both the envelope *and*
optional HDF5 extensions — keeps OodiCore smaller, but then every package
that only needs identities would depend on AH5, and #26 would be blocked
on creating that repository. The two-layer split keeps identities in the
package that already exists and still gives every domain one reusable I/O
layer.

## Ownership diagram

```text
                    +------------------+
                    |    OodiCore.jl   |
                    |  stdlib only     |
                    |                  |
                    |  report/validate |
                    |  SemanticNode    |
                    |  NodeSchema      |
                    |  archive types   |
                    +--------+---------+
                             ^
                             | depends on
                             |
                    +--------+---------+
                    |      AH5.jl      |
                    |                  |
                    |  .ah5 profile    |
                    |  HDF5 reader/    |
                    |  writer          |
                    |  inspect/verify  |
                    |  codec registry  |
                    +--------+---------+
                             ^
              weakdep + ext  |  never the reverse
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
domain package  ->  OodiCore     (hard or weak, package choice)
AH5.jl          ->  OodiCore     (hard)
domain package  ->  AH5.jl       (weak + package extension)
AH5XDMFExt      ->  AH5 + XML    (optional view layer)
AH5MPIExt       ->  AH5 + MPI    (optional parallel I/O)
```

Forbidden edges:

```text
OodiCore        ->  AH5 / HDF5 / XML / MPI / any domain package
AH5.jl          ->  Monge / Sorby / Delone / Oodi / Stinespring /
                    Lieb / Chappe / future orchestration
domain A        ->  domain B     merely to read archive identities
domain package  ->  HDF5.jl      as a hard core dependency
```

Dependencies flow one way: into OodiCore's consumers. AH5.jl is one such
consumer. Domain packages consume both, but AH5 never consumes a domain
package.

## What each layer owns

### OodiCore.jl — logical vocabulary

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

OodiCore still does not:

- open, create, or mutate HDF5 files
- execute migrations
- register or invoke payload codecs
- understand a CAD box, mesh, Hubbard sector, QPU job, or LLM checkpoint
- introduce `provenance(x)` or `artifacts(x)` as new introspection
  generics; those names remain reserved and unimplemented

Logical envelope tests belong in this repository and must not require
HDF5.

### AH5.jl — physical archive implementation

Create this package under the same owner before any HDF5 writer, `.ah5`
profile, or XDMF view lands. It depends on OodiCore and, for its core
I/O path, on HDF5.jl.

AH5.jl owns:

- the `.ah5` profile, in-file signature, and format version (#40)
- physical HDF5 encoding: datatype mapping, dataset/group paths,
  chunking, compression, append layout, and reserved shared paths
  (#38 physical side)
- append, transaction, completion, and restart markers (#27)
- revision-graph persistence and checkout (#30, #33)
- purge/compaction (#31)
- generic XDMF/XMF serialization and shared view conventions (#28),
  preferably behind an optional XML extension so Hubbard/QPU/LLM
  archives need not load LightXML
- parallel/collective HDF5, preferably behind an optional MPI extension
  (#29)
- embedded schema *storage* and validation that declared schema bytes
  are present and match their content identity (#39)
- integrity verification and external-artifact hashing (#42)
- migration *runners* that look up a registered domain migration,
  record provenance, and write a new archive or new immutable objects
  (#41)
- event-timeline and optional log-stream layout (#44)
- reproduction-capsule packaging (#35)
- generic `inspect` that works with no domain package installed
- reference fixtures and compatibility tests for the physical format

`using AH5` is an intentional I/O choice. Packages that only author or
validate in-memory models never load it.

AH5 must not learn domain meaning in order to do that work. It does not
know how an Oodi field or Stinespring posterior changes between schema
versions, which Delone arrays are geometry versus topology, or which
Oodi field association is node, cell, or facet. Those facts are
registered by the owning domain package.

XDMF remains a view layer over AH5 datasets, not a second archive
schema. Existing Oodi `write_xdmf` / `OodiWriteXDMFExt` is visualization
interchange for an Oodi mesh-plus-fields pair. It is not the scientific
archive and must not grow into a competing HDF5 framework. Later #28
work should project AH5 objects into `.xmf` views rather than inventing
another container.

### Domain packages — payload schemas and codecs

Monge, Sorby, Delone, Oodi, Stinespring, Lieb, Chappe, and future
packages own:

- their scientific payload types and schema definitions, including the
  logical array/dataset facts listed under OodiCore above
- package-qualified kinds such as `lieb/hubbard-sector` or `oodi/field`
- read/write codecs that encode those payloads into AH5 datasets
- schema-migration *implementations* (`oodi/field` 1.0 → 2.0, Delone
  mesh 2 → 3, and so on), registered with AH5 and executed by its runner
- XDMF/visualization *projection recipes*: which of their datasets are
  geometry, topology, or fields, and the node/cell/facet association
- which workflow events are worth recording
- whether OodiCore is a hard dependency or a weak extension

They do not own a second object/revision/reference envelope, a second
`.ah5` profile, or a private HDF5 transaction protocol.

## Boundaries that must not blur

These three splits are easy to collapse later and must stay explicit.

### Domain migrations versus the AH5 runner

Issue #41 defines a migration as a deterministic, domain-owned
transformation from one schema id/version to another. AH5 owns only the
shared machinery around that transformation:

- registry keyed by package namespace + schema id + source/target
  versions
- chain/cycle/ambiguity checks
- dry-run/plan
- provenance (implementation identity, source/target hashes)
- writing a new archive or new immutable objects; never silently
  rewriting the only copy

The function that knows what `oodi/field` 1.0 means, and how to produce
a 2.0 object from it, lives in Oodi (typically `OodiAH5Ext`). The same
rule applies to Delone meshes, Stinespring posteriors, Lieb sectors, and
every other payload. AH5 looks up the registered migration and runs it.
If no owning package/plugin is loaded, AH5 reports which one is required
and stops. It must not grow a table of domain-specific rewrite rules.

### XDMF serialization versus domain projection

AH5 owns the generic XDMF/XMF writer, shared naming/reference
conventions, and the view runtime that emits lightweight `.xmf` over
existing AH5 datasets. It does not decide scientific visualization
meaning.

The owning domain package registers the projection recipe for its
payloads: which Delone datasets are coordinates versus connectivity,
which Oodi field association is node/cell/facet, which Sorby
representation is a valid visualization projection, and which objects
are not XDMF-visible at all. Without that recipe, AH5 can still inspect
the archive; it must not invent a mesh or field interpretation in order
to write XMF.

### Logical schema versus physical HDF5 layout

A stored scientific object remains interpretable from portable schema
data even when the HDF5 layout later changes. Logical facts belong with
the payload schema, not with the container:

- field/dataset name
- logical scalar type
- rank, shape, and cardinality
- required versus optional
- units, coordinate frame, support, and location
- reference target
- declared semantic constraints

AH5 owns only physical encoding of those facts: HDF5 datatype mapping,
dataset/group paths, chunking, compression, filters, and append layout.
Changing chunking or compression must not change the scientific object
identity under #42. A future schema must describe the data contract, not
the HDF5 file.

OodiCore may hold the generic record types for those logical facts.
Domain packages fill them in. AH5 stores the bytes and maps them onto
HDF5. Generic inspect can print names, types, shapes, units, and
references from the embedded schema with no domain package and no
knowledge of chunk layout.

## How domain packages depend without loading HDF5

Match the existing weak-dependency pattern used by Chappe for OodiCore
and by Oodi for `write_xdmf`:

```toml
# in Lieb.jl / Chappe.jl / Stinespring.jl Project.toml
[weakdeps]
OodiCore = "7c15cd61-9c6a-4671-bc94-9960963998ac"
AH5 = "<uuid assigned when AH5.jl is created>"

[extensions]
LiebOodiCoreExt = "OodiCore"   # optional, if the core is provider-free
LiebAH5Ext = "AH5"
```

Then:

```julia
using Lieb            # no OodiCore required if it is a weakdep; no HDF5
using Lieb, OodiCore  # identities and declarative nodes only
using Lieb, AH5       # loads LiebAH5Ext; AH5 brings HDF5
```

Packages that already hard-depend on OodiCore (typical for Monge, Delone,
Oodi) still keep AH5 as a weak dependency. `using Oodi` must not load
HDF5. `using Oodi, AH5` loads the archive extension.

Provider-free and core CI jobs stay as they are: no HDF5, no MPI, no
vendor runtime, and no AH5 unless that job is explicitly the archive
extension contract.

## Schema and codec registration

AH5.jl must not import domain packages. Registration is pushed from the
domain side when both packages are loaded:

```julia
# conceptual; exact API is AH5.jl work, not this issue
AH5.register_codec!(
    namespace,          # e.g. :lieb or package UUID
    schema_id,          # e.g. "lieb/hubbard-sector"
    schema_version,     # immutable schema version, not package SemVer
    reader,
    writer,
)
AH5.register_migration!(namespace, source_schema, target_schema, migrate)
AH5.register_xdmf_projection!(namespace, schema_id, schema_version, project)
```

The `LiebAH5Ext` (or equivalent) module calls those APIs from `__init__`
or an explicit `register!` entry point. A missing codec, migration, or
projection is not an archive identity failure:

- generic inspection reads the `.ah5` profile, namespaces, embedded
  logical schemas, software-environment summaries, and revision index
  from OodiCore types stored in the file
- payload *interpretation* into live Lieb types requires `using Lieb, AH5`
- a needed migration or XDMF projection names the missing package/plugin
  instead of guessing domain meaning
- an unknown namespace or schema is reported as such; it is not parsed
  as if it were a core type

Embedded schemas (#39) are the reason inspection works without the owning
package. Prefer serializing OodiCore `NodeSchema` / `AttributeSchema` /
`ValidationRule` data plus the logical array/dataset facts above through
`to_namedtuple`. Domain-specific rule kinds stay symbolic; their
evaluators stay in the domain package. AH5 stores that portable schema
and maps it onto HDF5; it does not replace logical shape, units, or
support with chunk/compression/path metadata.

## Where follow-up issues live

Logical contract first, then physical persistence. #26 is unblocked in
this repository.

| Issue | OodiCore (types / rules) | AH5.jl (I/O / runners) |
| --- | --- | --- |
| #26 envelope, identities, references, schema-version rules | primary | persist those records |
| #27 transactions / completion / restart | completion-state types | HDF5 markers and recovery |
| #28 XDMF views | none | generic writer/conventions; domain registers the projection recipe |
| #29 integrity and parallel-HDF5 qualification | none | primary, after domain codecs exist |
| #30 revision history | revision identity types | graph storage |
| #31 purge / compaction | reachability as data | rewrite / new archive |
| #32 derived / debug artifacts | provenance record types | storage and retention flags |
| #33 checkout / lazy manifest | manifest types | selective HDF5 reads |
| #34 portable declarative document | primary | encoding inside `.ah5` |
| #35 reproduction capsules | capsule manifest types | packaging |
| #37 software-environment manifests | record types | `/provenance/software` storage |
| #38 namespaces | identity and reservation rules | HDF5 path layout |
| #39 embedded schemas | logical schema facts + `NodeSchema` serialization | physical `/schemas` storage; not HDF5 layout |
| #40 `.ah5` profile and generic inspect | profile metadata types | primary |
| #41 schema migrations | source/target identifiers | runner only; domain owns each transformation |
| #42 content hashes / verification | canonicalization rules | hash compute and verify |
| #43 execution-context fingerprint | record types and denylist data | storage |
| #44 event timeline / log streams | event record types | chunked append layout |

Issue #26 must remain testable without HDF5. Physical path spelling in
#38 and #40 is AH5.jl design work; OodiCore only needs stable namespace
and profile *identifiers*.

## Domain archive epics

The domain epics listed under #24 (Monge #328, Sorby #583, Delone #420,
Oodi #395, Stinespring #163, Lieb #65, Chappe #207) should:

- depend on this split rather than starting a package-local HDF5 layer
- put payload schemas next to the domain operations they describe
- register codecs, schema migrations, and XDMF projection recipes
  through an `*AH5Ext` extension
- treat existing visualization writers (VTU, XDMF, native checkpoints) as
  interchange or external artifacts, not as the provenance database

A future orchestration/composition package may persist whole-model
documents composed from package-owned fragments. It depends on OodiCore
and AH5.jl like any other consumer. It does not become the owner of
domain payloads or of the `.ah5` profile.

## Non-goals of this decision

- implementing envelope types, codecs, or an HDF5 writer
- creating the AH5.jl repository in this pull request
- choosing exact HDF5 paths, chunking, or hash algorithms
- forcing every domain package to hard-depend on OodiCore or AH5
- replacing Oodi's existing mesh/field visualization exporters

## Related study

Issue [#47](https://github.com/ahojukka5/OodiCore.jl/issues/47) studies
JLD2 as a Julia-native codec inside AH5.jl. It does not add JLD2 or HDF5
to OodiCore. Findings and the adopt-with-constraints recommendation are
in [`research/jld2-ah5-spike/FINDINGS.md`](../research/jld2-ah5-spike/FINDINGS.md).

Issue [#48](https://github.com/ahojukka5/OodiCore.jl/issues/48) is the
long-term Episteme architecture study. Decision: **REVISE** (keep
OodiCore; add `Episteme.jl` for composition and the orchestration
protocol; leave physical I/O in AH5.jl). See
[`docs/research/episteme-architecture.md`](research/episteme-architecture.md).
Do not start the Episteme refactor until that note is accepted.
