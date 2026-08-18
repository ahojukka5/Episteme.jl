# Shared scientific archive ownership

This is the ownership and dependency decision for issue
[#25](https://github.com/ahojukka5/OodiCore.jl/issues/25) under epic
[#24](https://github.com/ahojukka5/OodiCore.jl/issues/24). It does not
implement the archive envelope or an HDF5 writer. Those remain
[#26](https://github.com/ahojukka5/OodiCore.jl/issues/26) and later
AH5.jl work.

## Decision

Split the shared archive into two packages:

1. **OodiCore.jl** owns the dependency-free *logical* archive vocabulary:
   object and revision identities, references, namespace and schema-version
   identifiers, portable declarative-document envelopes, and the
   inspectable provenance/schema/integrity *record types* needed by more
   than one domain.
2. **AH5.jl** is the dedicated shared archive *implementation*. It owns
   the `.ah5` profile, HDF5 physical layout, XDMF view generation,
   transactions, integrity verification, migration runners, generic
   inspection, compatibility fixtures, and the runtime codec registry.

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
- HDF5 group/dataset layout and reserved shared paths (#38 physical side)
- append, transaction, completion, and restart markers (#27)
- revision-graph persistence and checkout (#30, #33)
- purge/compaction (#31)
- XDMF/XMF view generation (#28), preferably behind an optional XML
  extension so Hubbard/QPU/LLM archives need not load LightXML
- parallel/collective HDF5, preferably behind an optional MPI extension
  (#29)
- embedded schema *storage* and validation against bytes in the file
  (#39)
- integrity verification and external-artifact hashing (#42)
- migration *runners* that write new archives or new immutable objects
  (#41)
- event-timeline and optional log-stream layout (#44)
- reproduction-capsule packaging (#35)
- generic `inspect` that works with no domain package installed
- reference fixtures and compatibility tests for the physical format

`using AH5` is an intentional I/O choice. Packages that only author or
validate in-memory models never load it.

XDMF remains a view layer over AH5 datasets, not a second archive
schema. Existing Oodi `write_xdmf` / `OodiWriteXDMFExt` is visualization
interchange for an Oodi mesh-plus-fields pair. It is not the scientific
archive and must not grow into a competing HDF5 framework. Later #28
work should project AH5 objects into `.xmf` views rather than inventing
another container.

### Domain packages — payload schemas and codecs

Monge, Sorby, Delone, Oodi, Stinespring, Lieb, Chappe, and future
packages own:

- their scientific payload types and schema definitions
- package-qualified kinds such as `lieb/hubbard-sector` or `oodi/field`
- read/write codecs that encode those payloads into AH5 datasets
- which workflow events are worth recording
- whether OodiCore is a hard dependency or a weak extension

They do not own a second object/revision/reference envelope, a second
`.ah5` profile, or a private HDF5 transaction protocol.

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
```

The `LiebAH5Ext` (or equivalent) module calls that API from `__init__` or
an explicit `register!` entry point. A missing codec is not an archive
identity failure:

- generic inspection reads the `.ah5` profile, namespaces, embedded
  schemas, software-environment summaries, and revision index from
  OodiCore types stored in the file
- payload *interpretation* into live Lieb types requires `using Lieb, AH5`
- an unknown namespace or schema is reported as such; it is not parsed
  as if it were a core type

Embedded schemas (#39) are the reason inspection works without the owning
package. Prefer serializing OodiCore `NodeSchema` / `AttributeSchema` /
`ValidationRule` data through `to_namedtuple` and archive-specific
array/dataset descriptors owned by AH5. Domain-specific rule kinds stay
symbolic; their evaluators stay in the domain package.

## Where follow-up issues live

Logical contract first, then physical persistence. #26 is unblocked in
this repository.

| Issue | OodiCore (types / rules) | AH5.jl (I/O / runners) |
| --- | --- | --- |
| #26 envelope, identities, references, schema-version rules | primary | persist those records |
| #27 transactions / completion / restart | completion-state types | HDF5 markers and recovery |
| #28 XDMF views | none | primary |
| #29 integrity and parallel-HDF5 qualification | none | primary, after domain codecs exist |
| #30 revision history | revision identity types | graph storage |
| #31 purge / compaction | reachability as data | rewrite / new archive |
| #32 derived / debug artifacts | provenance record types | storage and retention flags |
| #33 checkout / lazy manifest | manifest types | selective HDF5 reads |
| #34 portable declarative document | primary | encoding inside `.ah5` |
| #35 reproduction capsules | capsule manifest types | packaging |
| #37 software-environment manifests | record types | `/provenance/software` storage |
| #38 namespaces | identity and reservation rules | HDF5 path layout |
| #39 embedded schemas | `NodeSchema` serialization | `/schemas` registry storage |
| #40 `.ah5` profile and generic inspect | profile metadata types | primary |
| #41 schema migrations | source/target identifiers | runner; never silent rewrite |
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
- register codecs through an `*AH5Ext` extension
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
