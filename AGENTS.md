# AGENTS.md — Episteme.jl

Guidance for AI agents (and humans) working on or with this package.

## 1. What this package is

`Episteme.jl` is the semantic runtime and persistent scientific backbone for
composable, reproducible, and eventually autonomous research.

It is not an Oodi-specific core, and it is not a forever-minimal contracts
package. Domain packages (Monge, Delone, Oodi, Stinespring, Lieb, Chappe, …)
own scientific payloads and operation semantics. Episteme owns the shared
semantics, schemas/contracts, identities and history vocabulary, the future
orchestration protocol, and eventually JLD2-backed AH5 persistence.

The accepted v1 product is:

```text
Episteme.jl = semantics + schemas + history/provenance
            + orchestration protocol
            + JLD2-backed AH5 persistence
```

This repository is the renamed/re-scoped former `OodiCore.jl` (issue #51).
The GitHub repository path may still be `ahojukka5/OodiCore.jl` until that
host-side rename is done. The Julia package name is `Episteme`; the UUID
is unchanged.

JLD2 and the `.ah5` writer are the **next** implementation PRs, not current
code. HDF5.jl remains later optional `EpistemeHDF5Ext` work. Do not add
them here unless the current task is that persistence PR.

See [`docs/research/episteme-architecture.md`](docs/research/episteme-architecture.md)
and [`docs/archive-ownership.md`](docs/archive-ownership.md).

## 2. What it owns

Episteme owns the common introspection generics:

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

These are declared here, and only here, so downstream packages extend the same
functions instead of creating locally scoped lookalikes.

It also owns small generic supporting types and protocols:

- reports and diagnostics (`DiagnosticMessage`, `ValidationReport`, etc.),
- the generic semantic tree (`SemanticNode`, `NodeRef`),
- local declarative node schemas (`NodeSchema`, `AttributeSchema`,
  `ValidationRule`, `NodeValidationRule`),
- an opaque cross-product scripting representation (`script_node`),
- the scientific-archive vocabulary (object/revision identities, references,
  namespace and schema-version identifiers, portable document envelopes, and
  inspectable provenance/integrity record types).

Shared infrastructure kinds use the `:episteme` / `episteme/*` namespace
(`episteme/script` today; `episteme/document` and `episteme/plan` when those
types land). Domain kinds stay with the owning package (`monge/*`,
`delone/*`, `oodi/*`, `lieb/*`, …).

These facilities must remain domain-neutral. Episteme may know that a local
field is a finite positive real, but it must not know what a CAD box, mesh
size, finite-element space, or solver tolerance means.

Physical AH5/HDF5/XDMF I/O does **not** live here yet. It will land as
Episteme's JLD2-backed AH5 profile, not as a standalone `AH5.jl` package.

## 3. Rule for downstream packages

Downstream packages (CAD/geometry, meshing, `Oodi.jl`, MCP servers, report
exporters, etc.) must import and extend shared generic functions rather than
shadowing them:

```julia
import Episteme: report, validate, readiness

report(x::MyType) = ObjectReport(...)
validate(x::MyType) = ValidationReport(...)
readiness(x::MyType, target::PipelineTarget) = ReadinessReport(...)
```

Domain-specific report types are welcome and encouraged; they should subtype
`AbstractEpistemeReport`, `AbstractValidationReport`, or
`AbstractReadinessReport` as appropriate.

For declarative model nodes, domain packages own their vocabulary and may use
Episteme's local schema machinery:

```julia
schema = NodeSchema(
    Symbol("mydomain/node"),
    AttributeSchema(
        :size,
        :real;
        allow_ref = true,
        rules = (ValidationRule(:finite), ValidationRule(:gt; value = 0.0)),
    ),
)
```

Keep domain schemas next to the domain operations they describe rather than
building a central Episteme registry of Monge/Delone/Oodi concepts.

## 4. Dependencies

Do not add CAD kernels, meshing kernels, GPU packages, solver packages, or
plotting packages. Do not depend on `Oodi.jl` or on other domain packages.

JLD2 becomes a hard dependency in a later focused persistence PR. HDF5.jl,
MPI, and XML stay out of `using Episteme` unless a later extension needs
them (`EpistemeHDF5Ext` for bulk `/data` and parallel HDF5).

Dependencies must flow one way, into Episteme's consumers.

## 5. Do not add domain logic

No CAD logic, meshing logic, FEM/discretization logic, solver logic, QPU,
Hubbard, or LLM semantics belong here.

Local schema validation is in scope only when the rule is structurally generic:
required fields, portable value kinds, finiteness, ranges, non-empty values,
enums, node-local cross-field orderings, and similarly local invariants.

Cross-object or domain equations are not local schema validation. For example:

```text
hole.center_xy == box.center_xy
volume(box) <= 2
box.z == volume(box)/(box.x*box.y)
```

belong to the domain package that owns those semantics and eventually to its
constraint/expression evaluator.

## 6. Keep shared types structured, serializable, and readable

Any new shared type should:

- be a plain immutable `struct` with simple fields,
- avoid opaque function closures when a symbolic/introspectable representation
  is possible,
- have a `to_namedtuple` method when appropriate,
- remain useful to humans and agents without inspecting internal Julia state.

Validation rules in particular are data (`kind + parameters`), not closures, so
agents and MCP tooling can inspect the same rules the runtime enforces.

## 7. Introspection functions are read-only

`report`, `validate`, and `readiness` must never mutate the object they inspect.
They answer questions; they do not change state.

## 8. Mutating functions must use explicit `!` naming

If a function mutates its argument, use a trailing `!` per Julia convention.
Do not blur mutation with the read-only introspection API.

## 9. Designed for future MCP/tool-server exposure

Shared reports, semantic nodes, schemas, validation rules, and script contracts
are deliberately simple and serializable so future MCP/tool-server layers can
expose them with minimal translation work.

The shared script representation is an especially important boundary:

```julia
script_node(
    :lookup;
    language = :julia,
    source = "lookup(context)",
    inputs = (NodeRef(:id),),
    outputs = (:value,),
    effects = (:network,),
)
```

Episteme stores this contract but **never executes source code**. Script
execution is a trusted-code concern for the orchestration layer, which must
explicitly bind inputs/outputs and enforce allowed effects.

## 10. Extending validation

Episteme provides a small standard set of symbolic local rule kinds such as
`:finite`, `:gt`, `:ge`, `:lt`, `:le`, `:nonempty`, and `:one_of`.

A downstream package may add a genuinely reusable/domain-specific symbolic rule
by extending:

```julia
import Episteme: check_validation_rule
check_validation_rule(::Val{:my_rule}, value, parameters) = ...
```

The rule must still be represented as `ValidationRule(:my_rule; ...)`, not an
opaque closure embedded in a schema.

Node-local cross-field rules use the same pattern:

```julia
import Episteme: check_node_validation_rule
check_node_validation_rule(::Val{:my_node_rule}, node, parameters) = ...
```

Represent those as `NodeValidationRule(:my_node_rule; fields = (:a, :b), ...)`.
Name participating attributes in `fields` (or `left`/`right`) so missing or
ill-typed values skip the rule instead of producing secondary exceptions.

## 11. Out of scope for now

The following introspection generics remain outside Episteme unless a later
architectural decision expands the contract:

```julia
summary(x)
diagnose(x)
explain(x)
suggest_fixes(x)
provenance(x)
artifacts(x)
repair!
```

Archive *record types* (identities, references, schema versions, software
environment and execution-context fingerprints, content-hash rules) are in
scope as data. They are not an implementation of `provenance(x)` or
`artifacts(x)`, and they must not open files until the persistence PR.

Also out of scope in the current code (planned later, not here):

- `PlanId` / `ActivityId` / `DocumentId` / `AgentId` and Plan/Run/Activity/Event/Revision records,
- `execute!` / `commit!` / orchestration,
- JLD2 / `.ah5` writer / HDF5.jl,
- `AbstractStore` or Mongo/Postgres backends,
- domain constraint solvers,
- expression evaluation semantics,
- dependency-DAG/reference resolution,
- automatic or implicit script execution,
- security sandboxing for arbitrary user code.

If a task seems to require one of these, keep the representation/protocol in
Episteme only when it is truly cross-product; keep the semantics in the owning
downstream package. See [`docs/archive-ownership.md`](docs/archive-ownership.md).
