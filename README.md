# OodiCore.jl

`OodiCore.jl` is the lightweight shared core of the Oodi numerical pipeline.

It exists so that CAD/geometry packages, meshing packages, `Oodi.jl` itself,
and future pipeline tools (MCP servers, report exporters, agent-facing
automation) can all speak the same small, generic "introspection" language
without depending on each other or on any heavy numerical/graphics
libraries.

## Why this package exists

Oodi is becoming an LLM-native numerical framework. The long-term pipeline
looks like this:

```text
intent → geometry → validation → mesh → quality diagnostics → discretization
→ operator/problem construction → solve → verification → report → revision
```

For an LLM agent (or a human) to drive that pipeline, every major object
along the way needs to answer three questions in a consistent way:

```julia
report(x)              # What is this object?
validate(x)             # Is it internally valid?
readiness(x, target)    # Can it move to the requested next pipeline stage?
```

`OodiCore.jl` owns that shared interface. It defines `report`, `validate`,
and `readiness` as empty generic functions, plus a handful of lightweight
report/diagnostic/target/artifact types used to implement them. It also owns
the shared semantic tree (`SemanticNode`, `NodeRef`), local declarative
schemas, and the dependency-free scientific-archive vocabulary (identities,
references, schema versions, portable document envelopes). Physical
AH5/HDF5/XDMF I/O lives in a dedicated `AH5.jl` package so provider-free
cores never load HDF5. See [`docs/semantic-tree-poc.md`](docs/semantic-tree-poc.md),
[`docs/declarative-contracts.md`](docs/declarative-contracts.md),
[`docs/archive-ownership.md`](docs/archive-ownership.md), and
[`docs/archive-envelope.md`](docs/archive-envelope.md).

## Why shared generic functions avoid name conflicts

If every package defined its own local `report`/`validate`/`readiness`
function, then loading two such packages together (e.g. a CAD package and a
meshing package inside `Oodi.jl`) would produce a name conflict: Julia would
not know which `report` you meant, and `using` both packages would warn
about ambiguous exports or silently shadow one method with another.

By defining these functions in exactly one small package with no heavy
dependencies, every other package in the ecosystem can safely depend on
`OodiCore.jl` and add methods to the *same* generic function. This is
Julia's standard multiple-dispatch idiom for shared interfaces, sometimes
called an "interface package."

## How downstream packages should extend the contract

Always import the generic function before adding methods:

```julia
import OodiCore: report, validate, readiness
```

Never create local functions with these names in downstream packages.

### Example

```julia
using OodiCore

struct MyMesh
    nelements::Int
end

import OodiCore: report, validate, readiness

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

OodiCore also implements `validate(node::SemanticNode, schema::NodeSchema)`
for local schema checks, and `validate` / `report` for the archive
envelope types.

Abstract types:

- `AbstractOodiReport`
- `AbstractValidationReport <: AbstractOodiReport`
- `AbstractReadinessReport <: AbstractOodiReport`
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
  types; this wrapper does not store them. No HDF5. See
  [`docs/archive-envelope.md`](docs/archive-envelope.md).

Tree operations:

- `add_child!(parent, child)` — append a child and preserve child order.
  `push!` is an alias.
- `attribute(node, key)` / `attribute(node, key, default)` — read an
  attribute.
- `set_attribute!(node, key, value)` — set or add an attribute.

Declarative helpers:

- `script_node(name; language = :julia, source, inputs, outputs, effects)`
  — opaque scripting node. OodiCore never executes the source.
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
  tree have no OodiCore serialization protocol. Symbol-valued fields
  (`severity`, `code`, `subject`, `kind`, target `name`, ...) are kept as
  `Symbol`s; a JSON-encoding step at the boundary is expected to turn
  them into strings.

## What should and should not go into OodiCore

`OodiCore.jl` should stay small and dependency-light forever. It is safe to
add:

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
  provenance *record types* (no file I/O).

It must **not** contain:

- CAD logic,
- meshing logic,
- FEM/discretization logic,
- solver logic,
- file-format backends, including HDF5, XDMF, and `.ah5` writers,
- plotting/rendering backends,
- Netgen/OpenCascade wrappers,
- `Oodi.jl` operator or problem definitions,
- dependencies on any of the above.

Shared archive I/O belongs in `AH5.jl`. Domain packages register payload
codecs through weak-dependency extensions and must not start package-local
HDF5 archive frameworks. See
[`docs/archive-ownership.md`](docs/archive-ownership.md).

If a proposed addition needs a heavy dependency, or logic specific to one
domain (CAD, meshing, solving), it belongs in that domain's own package, not
here.

## Installation

`OodiCore.jl` is not yet registered. Add it as a path or git dependency
from its own repository, e.g.:

```julia
pkg> add https://github.com/ahojukka5/OodiCore.jl
# or
pkg> dev /path/to/OodiCore.jl
```

## Running tests

```julia
pkg> test OodiCore
```
