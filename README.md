# Episteme.jl

`Episteme.jl` is the semantic runtime and persistent scientific backbone for
composable, reproducible, and eventually autonomous research.

Domain packages keep their payloads and operation semantics. They speak one
shared introspection and archive language instead of depending on each other.

This repository is the renamed/re-scoped former `OodiCore.jl` (issue
[#51](https://github.com/ahojukka5/Episteme.jl/issues/51)). The Julia package
name is `Episteme`; the package UUID is unchanged.

The accepted v1 product ([#48](https://github.com/ahojukka5/Episteme.jl/issues/48)) is:

```text
Episteme.jl = semantics + schemas + history/provenance
            + orchestration protocol
            + JLD2-backed AH5 persistence
```

This package currently ships the semantics, schemas, and archive *vocabulary*.
JLD2-backed AH5 persistence and the orchestration protocol are the next
implementation steps.

## Why this package exists

Independently owned scientific packages need a shared place to describe objects,
validate them, compose research workflows, and record inspectable history. For
an LLM agent or a human to drive that work, every major object needs to answer
three questions consistently:

```julia
report(x)              # What is this object?
validate(x)             # Is it internally valid?
readiness(x, target)    # Can it move to the requested next stage?
```

`Episteme.jl` owns that shared interface. It defines `report`, `validate`, and
`readiness` as generic functions, plus structured report, diagnostic, schema,
semantic-tree, identity, reference, and archive-record vocabulary.

Physical `.ah5` I/O is planned as Episteme's JLD2-backed archive/profile.
HDF5.jl remains a later optional extension for capabilities that need direct or
parallel HDF5 access. See
[`docs/research/episteme-architecture.md`](docs/research/episteme-architecture.md),
[`docs/archive-ownership.md`](docs/archive-ownership.md),
[`docs/semantic-tree-poc.md`](docs/semantic-tree-poc.md),
[`docs/declarative-contracts.md`](docs/declarative-contracts.md),
[`docs/archive-envelope.md`](docs/archive-envelope.md),
[`docs/archive-lifecycle.md`](docs/archive-lifecycle.md),
[`docs/archive-events.md`](docs/archive-events.md),
[`docs/portable-documents.md`](docs/portable-documents.md), and
[`docs/archive-checkout.md`](docs/archive-checkout.md).

## Why shared generic functions avoid name conflicts

If every package defined its own local `report`/`validate`/`readiness`
function, then loading two such packages together would produce a name
conflict. By defining these functions in exactly one package, every domain
package can add methods to the *same* generic functions using Julia multiple
dispatch.

## How domain packages extend the contract

Always import the generic function before adding methods:

```julia
import Episteme: report, validate, readiness
```

Never create local lookalikes with the same role.

### Example

```julia
using Episteme

struct MyModel
    size::Int
end

import Episteme: report, validate, readiness

report(x::MyModel) = ObjectReport(
    :model,
    "Model with size $(x.size).",
    (; size = x.size),
    DiagnosticMessage[],
    ArtifactRef[],
)

validate(x::MyModel) = ValidationReport(
    :model,
    x.size > 0,
    x.size > 0 ? DiagnosticMessage[] :
        [error_diagnostic(:invalid_size, "Size must be positive.")],
    (; size = x.size),
)

readiness(x::MyModel, target::PipelineTarget) = ReadinessReport(
    :model,
    target,
    x.size > 0,
    x.size > 0 ? DiagnosticMessage[] :
        [error_diagnostic(:not_ready, "Model is not ready.")],
    (; size = x.size),
)
```

## Public API

Generic functions:

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

Episteme also implements local semantic-node/schema validation and reporting
for shared archive-envelope records.

Abstract types:

- `AbstractEpistemeReport`
- `AbstractValidationReport <: AbstractEpistemeReport`
- `AbstractReadinessReport <: AbstractEpistemeReport`
- `AbstractDiagnostic`
- `AbstractPipelineTarget`

Selected concrete types:

- `DiagnosticMessage` — structured diagnostics with stable codes and context.
- `ValidationReport` — result of `validate`.
- `PipelineTarget` — a named next-stage descriptor.
- `ReadinessReport` — result of `readiness`.
- `ObjectReport` — a general-purpose report type.
- `ArtifactRef` — a lightweight reference to an external artifact.
- `SemanticNode` / `NodeRef` — shared semantic-tree nodes and references.
- `ValidationRule` / `AttributeSchema` / `NodeSchema` /
  `NodeValidationRule` — local declarative schema vocabulary.
- `ObjectId` / `RevisionId` / `ContentId` / `WorkflowHeadId` /
  `DocumentId` / `PlanId` / `ActivityId` / `AgentId` — distinct
  archive identities.
- `ArchiveObject` / `ArchiveReference` / `SchemaRef` / `ArchiveGraph` —
  shared logical archive-envelope records.
- `OperationSpec` / `Plan` / `RunRecord` / `ActivityRecord` /
  `EventRecord` / `RevisionRecord` — dual-history records on
  `ArchiveGraph` (snapshot revisions vs run/activity/event history).
- `StagedObject` / `WriteTransaction` / `CheckpointRef` /
  `RestartRequirement` — durable run/commit/restart contract: staging
  before `commit!`, interrupted-write phases, and exact restart refs.
- `revision_parents` / `revision_children` / `revision_ancestors` /
  `revision_descendants` — in-memory revision DAG walks.
- `promote_staged` — pure mapping of a run's staging set to envelope rows.
- `EventBatch` / `LogStreamRecord` / `event_timeline` — durable
  human-readable event timeline and optional purgeable log streams.
- `PortableSemanticDocument` / `capture_portable` / `portable_sexpr` —
  fail-closed portable declarative documents, distinct from live
  `SemanticNode` trees and from JLD2 working-archive persistence.
- `RevisionManifest` / `inspect` / `checkout` / `select` / `branch_from`
  — lazy historical-revision manifests; no payload load and no file I/O.

Tree operations:

- `add_child!(parent, child)` / `push!`
- `attribute(node, key)`
- `set_attribute!(node, key, value)`

Declarative helpers:

- `script_node(name; language, source, inputs, outputs, effects)` — opaque
  scripting contract; Episteme stores but does not implicitly execute source.
- `validated_node(schema, name; ...)` — fail-fast local construction.
- `check_validation_rule` / `check_node_validation_rule` — extension points for
  symbolic validation rules.

Serialization:

- `to_namedtuple(x)` converts supported shared records into plain,
  serialization-friendly structures. Arbitrary runtime values inside a
  `SemanticNode` are not automatically promoted into a portable interchange
  contract; use `capture_portable` for that fail-closed subset.

## What belongs in Episteme

Episteme owns domain-neutral infrastructure shared across research packages:

- semantic trees and references,
- schemas and structured validation,
- reports and diagnostics,
- archive identities, references, provenance and history vocabulary,
- declarative research-document and plan vocabulary,
- orchestration protocols that remain independent of domain science,
- JLD2-backed AH5 persistence and generic archive inspection.

It must **not** contain domain-specific scientific or numerical semantics. In
particular, keep the following in the package that owns the domain:

- physical models, equations, constitutive laws, and scientific assumptions,
- geometry, CAD, meshing, and topology algorithms,
- discretization and numerical methods such as FEM, finite-volume, spectral,
  or particle formulations,
- linear, nonlinear, eigensystem, time-integration, and optimization solvers,
- quantum-computing algorithms, device semantics, and experiment logic,
- machine-learning or model-serving algorithms and policies,
- rendering, visualization, and domain-specific export logic,
- integrations whose semantics belong to a particular external scientific
  library or service.

Likewise, do not introduce speculative infrastructure abstractions for storage
or services without a concrete second implementation that requires them.

The rule is simple: **Episteme owns the cross-domain research contract; domain
packages own the science and the algorithms.**

## Installation

`Episteme.jl` is not yet registered. Add it as a git or path dependency:

```julia
pkg> add https://github.com/ahojukka5/Episteme.jl
# or
pkg> dev /path/to/Episteme.jl
```

## Running tests

```julia
pkg> test Episteme
```
