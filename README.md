# Episteme.jl

`Episteme.jl` is the semantic runtime and persistent scientific backbone for
composable, reproducible, and eventually autonomous research.

Domain packages (CAD/geometry, meshing, `Oodi.jl`, QPU, Hubbard, LLM serving,
and future tools such as MCP servers) keep their payloads and operation
semantics. They speak one shared introspection and archive language instead of
depending on each other or on heavy numerical/graphics libraries.

This repository is the renamed/re-scoped former `OodiCore.jl` (issue
[#51](https://github.com/ahojukka5/OodiCore.jl/issues/51)). The Julia package
name is `Episteme`; the package UUID is unchanged. The GitHub repository may
still be `ahojukka5/OodiCore.jl` until that host-side rename is performed.

The accepted v1 product ([#48](https://github.com/ahojukka5/OodiCore.jl/issues/48)) is:

```text
Episteme.jl = semantics + schemas + history/provenance
            + orchestration protocol
            + JLD2-backed AH5 persistence
```

This package currently ships the semantics, schemas, and archive *vocabulary*.
JLD2-backed AH5 persistence and the orchestration protocol are the next
implementation steps. They are **not** in this rename.

## Why this package exists

Independently owned scientific packages need a shared place to describe objects,
validate them, compose a whole-model document, and (later) record inspectable
history. For an LLM agent or a human to drive that work, every major object
along the way needs to answer three questions consistently:

```julia
report(x)              # What is this object?
validate(x)             # Is it internally valid?
readiness(x, target)    # Can it move to the requested next pipeline stage?
```

`Episteme.jl` owns that shared interface. It defines `report`, `validate`,
and `readiness` as empty generic functions, plus a handful of lightweight
report/diagnostic/target/artifact types used to implement them. It also owns
the shared semantic tree (`SemanticNode`, `NodeRef`), local declarative
schemas, and the scientific-archive vocabulary (identities, references,
schema versions, portable document envelopes).

Physical `.ah5` I/O is planned as Episteme's JLD2-backed archive/profile, not
as a standalone `AH5.jl` package. HDF5.jl remains later optional
`EpistemeHDF5Ext` work. See
[`docs/research/episteme-architecture.md`](docs/research/episteme-architecture.md),
[`docs/archive-ownership.md`](docs/archive-ownership.md),
[`docs/semantic-tree-poc.md`](docs/semantic-tree-poc.md),
[`docs/declarative-contracts.md`](docs/declarative-contracts.md), and
[`docs/archive-envelope.md`](docs/archive-envelope.md).

## Why shared generic functions avoid name conflicts

If every package defined its own local `report`/`validate`/`readiness`
function, then loading two such packages together (e.g. a CAD package and a
meshing package inside `Oodi.jl`) would produce a name conflict: Julia would
not know which `report` you meant, and `using` both packages would warn
about ambiguous exports or silently shadow one method with another.

By defining these functions in exactly one package, every other package in the
ecosystem can safely depend on `Episteme.jl` and add methods to the *same*
generic function. This is Julia's standard multiple-dispatch idiom for shared
interfaces, sometimes called an "interface package."

## How downstream packages should extend the contract

Always import the generic function before adding methods:

```julia
import Episteme: report, validate, readiness
```

Never create local functions with these names in downstream packages.

### Example

```julia
using Episteme

struct MyMesh
    nelements::Int
end

import Episteme: report, validate, readiness

report(mesh::MyMesh) = ObjectReport(
    :mesh,
    "Mesh with $(mesh.nelements) elements.",
    (; nelements = mesh.nelements),
    DiagnosticMessage[],
    ArtifactRef[],
)

validate(mesh::MyMesh) = ValidationReport(
    :mesh,
    mesh.nelements > 0,
    mesh.nelements > 0 ? DiagnosticMessage[] :
        [error_diagnostic(:empty_mesh, "Mesh has no elements.")],
    (; nelements = mesh.nelements),
)

readiness(mesh::MyMesh, target::PipelineTarget) = ReadinessReport(
    :mesh,
    target,
    mesh.nelements > 0,
    mesh.nelements > 0 ? DiagnosticMessage[] :
        [error_diagnostic(:not_ready, "Mesh cannot be used because it is empty.")],
    (; nelements = mesh.nelements),
)
```

Given this, any agent or user can now do:

```julia
julia> m = MyMesh(0);

julia> validate(m)
ValidationReport(subject=:mesh, valid=false)
  [error:empty_mesh] Mesh has no elements.

julia> readiness(m, PipelineTarget(:gmg))
ReadinessReport(subject=:mesh, target=:gmg, ready=false)
  [error:not_ready] Mesh cannot be used because it is empty.
```

without needing to know anything about `MyMesh` internals.

## Public API

Generic functions (define no default method — implement in downstream
packages):

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

Episteme also implements `validate(node::SemanticNode, schema::NodeSchema)`
for local schema checks, and `validate` / `report` for the archive
envelope types.

Abstract types:

- `AbstractEpistemeReport`
- `AbstractValidationReport <: AbstractEpistemeReport`
- `AbstractReadinessReport <: AbstractEpistemeReport`
- `AbstractDiagnostic`
- `AbstractPipelineTarget`

Concrete types:

- `DiagnosticMessage` — one structured diagnostic (`severity`, `code`,
  `message`, `context`). Build with `info_diagnostic`, `warning_diagnostic`,
  `error_diagnostic`.
- `ValidationReport` — result of `validate`. Query with `Base.isvalid`.
- `PipelineTarget` — a named pipeline stage descriptor, e.g.
  `PipelineTarget(:meshing)`, `PipelineTarget(:gmg; levels = 3)`.
- `ReadinessReport` — result of `readiness`. Query with `Base.isready`.
- `ObjectReport` — a general-purpose default report type for simple objects.
- `ArtifactRef` — a lightweight reference to an external artifact (file,
  image, log, ...) without embedding its data.
- `SemanticNode` / `NodeRef` — the shared semantic tree and references. If
  Julia can hold a value, the tree can hold it. Display uses ordinary Julia
  `show`. See [`docs/semantic-tree-poc.md`](docs/semantic-tree-poc.md).
- `ValidationRule` / `AttributeSchema` / `NodeSchema` / `NodeValidationRule`
  — introspectable local schemas. Attribute rules inspect one value;
  node-local rules inspect relationships inside one node. See
  [`docs/declarative-contracts.md`](docs/declarative-contracts.md).
- `ObjectId` / `RevisionId` / `ContentId` / `WorkflowHeadId` — distinct
  archive identities. Equal strings do not make them the same kind of id.
- `ArchiveObject` / `ArchiveReference` / `SchemaRef` / `ArchiveGraph` —
  the shared logical archive envelope. Package payloads stay in domain
  types; this wrapper does not store them. No file I/O yet. See
  [`docs/archive-envelope.md`](docs/archive-envelope.md).

Tree operations:

- `add_child!(parent, child)` — append a child and preserve child order.
  `push!` is an alias.
- `attribute(node, key)` / `attribute(node, key, default)` — read an
  attribute.
- `set_attribute!(node, key, value)` — set or add an attribute.

Declarative helpers:

- `script_node(name; language = :julia, source, inputs, outputs, effects)`
  — opaque scripting node of kind `episteme/script`. Episteme never executes
  the source.
- `validated_node(schema, name; ...)` — fail-fast construction against a
  schema.
- `check_validation_rule` / `check_node_validation_rule` — extension points
  for additional symbolic rule kinds.

Serialization:

- `to_namedtuple(x)` — converts reports, diagnostics, targets, artifacts,
  schemas (`ValidationRule`, `AttributeSchema`, `NodeSchema`,
  `NodeValidationRule`), and archive envelope records into a plain
  `NamedTuple` suitable for JSON encoding or logging. It does **not**
  convert `SemanticNode` or `NodeRef`; arbitrary runtime values in the
  tree have no Episteme serialization protocol. Symbol-valued fields
  (`severity`, `code`, `subject`, `kind`, target `name`, ...) are kept as
  `Symbol`s; a JSON-encoding step at the boundary is expected to turn
  them into strings.

## What should and should not go into Episteme

It is safe to add:

- generic function declarations shared across the ecosystem,
- lightweight abstract report/result types,
- simple diagnostic/message types,
- simple readiness target types,
- artifact/provenance reference types,
- the generic semantic tree and references,
- local declarative schemas and validation rules,
- small helper constructors,
- readable `show` methods,
- serialization-friendly structures for reports, diagnostics, targets,
  artifacts, and schemas,
- scientific-archive identity, reference, namespace, schema-version, and
  provenance *record types*,
- later: Plan/Run/Activity/Event/Revision records, orchestration protocol,
  and JLD2-backed AH5 persistence (separate PRs).

It must **not** contain:

- CAD logic,
- meshing logic,
- FEM/discretization logic,
- solver logic,
- QPU / Hubbard / LLM domain semantics,
- plotting/rendering backends,
- Netgen/OpenCascade wrappers,
- `Oodi.jl` operator or problem definitions,
- dependencies on any of the above,
- `AbstractStore` or Mongo/Postgres backends.

Domain packages register payload codecs with Episteme's future AH5 profile
and must not start package-local HDF5 archive frameworks. A JLD2 persistence
spike (issue #47) lives in
[`research/jld2-ah5-spike/`](research/jld2-ah5-spike/).

If a proposed addition is logic specific to one domain (CAD, meshing,
solving), it belongs in that domain's own package, not here.

## Installation

`Episteme.jl` is not yet registered. The next General registration should be
for `Episteme`, not the unmerged `OodiCore` attempt (issue #23). Add it as a
path or git dependency from this repository, e.g.:

```julia
pkg> add https://github.com/ahojukka5/OodiCore.jl
# or
pkg> dev /path/to/OodiCore.jl   # local checkout; package name is Episteme
```

Until the GitHub repository is renamed, the clone URL still contains
`OodiCore.jl`. After `add`/`dev`, `using Episteme` is the Julia name.

## Running tests

```julia
pkg> test Episteme
```
