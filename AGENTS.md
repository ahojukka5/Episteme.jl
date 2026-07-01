# AGENTS.md — OodiCore.jl

Guidance for AI agents (and humans) working on or with this package.

## 1. What this package is

`OodiCore.jl` is a lightweight shared core package for the Oodi ecosystem.
It has no domain logic of its own. Its only job is to define the contracts
that other Oodi packages implement.

## 2. What it owns

`OodiCore.jl` owns the common introspection generics:

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

These are declared here, and only here, as empty generic functions
(`function report end`, etc.). No other package in the Oodi ecosystem may
define its own local `report`, `validate`, or `readiness` function.

It also owns the small supporting types used to implement these generics:
`DiagnosticMessage`, `ValidationReport`, `ReadinessReport`, `ObjectReport`,
`PipelineTarget`, `ArtifactRef`, and the `to_namedtuple` serialization
helper.

## 3. Rule for downstream packages

Downstream packages (CAD/geometry, meshing, `Oodi.jl`, MCP servers, report
exporters, etc.) must import and extend these functions:

```julia
import OodiCore: report, validate, readiness

report(x::MyType) = ObjectReport(...)          # or a custom AbstractOodiReport subtype
validate(x::MyType) = ValidationReport(...)
readiness(x::MyType, target::PipelineTarget) = ReadinessReport(...)
```

Do not write `function report(x::MyType) ... end` as a fresh top-level
function in a downstream module without first importing `OodiCore.report`
— that creates a locally-scoped function that shadows the shared generic
instead of extending it, and breaks dispatch across the ecosystem.

Domain-specific report types (e.g. a `ShapeReport` for CAD, a
`MeshValidationReport` for meshing) are welcome and encouraged — they should
subtype `AbstractOodiReport`, `AbstractValidationReport`, or
`AbstractReadinessReport` as appropriate. `ObjectReport`/`ValidationReport`/
`ReadinessReport` are default implementations for simple cases, not the only
allowed return types.

## 4. Do not add heavy dependencies

`OodiCore.jl` must remain safe to use as a base dependency from every other
Oodi package, including ones with no numerical or geometric code at all
(e.g. an MCP tool server). Concretely:

- No dependency beyond the Julia standard library unless there is a very
  strong, specific reason, and it should still be a small, common,
  low-churn package if added.
- No CAD kernels (OpenCascade, etc.), meshing kernels (Netgen, etc.), GPU
  packages, solver packages, or plotting/rendering packages.
- No dependency on `Oodi.jl` itself, or on the CAD/meshing packages that
  depend on `OodiCore.jl` — dependencies must flow one way, into
  `OodiCore.jl`'s consumers, never back into it.

## 5. Do not add domain logic

No CAD logic, meshing logic, FEM/discretization logic, solver logic,
file-format backends, or plotting/rendering backends belong in this
package. If you find yourself wanting to add domain-specific behavior here,
it almost certainly belongs in the calling package instead, defined as a
method on the shared generics.

## 6. Keep report types structured, serializable, and readable

Any new report/diagnostic/target type added here (or as a subtype in a
downstream package) should:

- be a plain, immutable `struct` with simple, JSON-friendly field types
  (`Symbol`, `String`, `Bool`, `NamedTuple`, `Vector` of the above),
- have a `to_namedtuple` method if added here (downstream packages should
  do the equivalent for their own report subtypes),
- have a concise, readable `Base.show` method — a human or an agent reading
  a report at a REPL or in a log should immediately understand the subject,
  the pass/fail result, and the diagnostics, without needing to inspect
  fields manually.

## 7. Introspection functions are read-only

`report`, `validate`, and `readiness` must never mutate the object they are
called on. They answer questions; they do not change state. This is
essential for agents that call these functions speculatively/repeatedly
while exploring a pipeline.

## 8. Mutating functions must use explicit `!` naming

If a future function in this ecosystem does need to mutate its argument
(e.g. a hypothetical `repair!`), it must be named with a trailing `!`,
per Julia convention, and must not be confused with the read-only
`report`/`validate`/`readiness` trio. No such mutating function exists in
`OodiCore.jl` today.

## 9. Designed for future MCP/tool-server exposure

The types in this package (`DiagnosticMessage`, `ValidationReport`,
`ReadinessReport`, `ObjectReport`, `ArtifactRef`, `PipelineTarget`) are
deliberately simple, structured, and serializable via `to_namedtuple`, so
that a future MCP server or other tool-facing layer can expose `report`,
`validate`, and `readiness` calls as tools/resources with minimal
translation work. Keep this in mind when adding new fields or types: prefer
flat, simple, well-typed data over deeply nested or Julia-specific
structures.

## 10. Out of scope for now

The following are deliberately not implemented yet, and should not be added
without a deliberate decision to expand the contract:

```julia
summary(x)
diagnose(x)
explain(x)
suggest_fixes(x)
schema(x)
provenance(x)
artifacts(x)
repair!
```

If a task seems to require one of these, flag it rather than silently
adding it here.
