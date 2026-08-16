# AGENTS.md — OodiCore.jl

Guidance for AI agents (and humans) working on or with this package.

## 1. What this package is

`OodiCore.jl` is a lightweight shared core package for the Oodi ecosystem.
It has no domain logic of its own. Its only job is to define the contracts
that other Oodi packages implement or reuse.

## 2. What it owns

`OodiCore.jl` owns the common introspection generics:

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

These are declared here, and only here, so downstream packages extend the same
functions instead of creating locally scoped lookalikes.

It also owns small generic supporting types and protocols that are useful in
every product:

- reports and diagnostics (`DiagnosticMessage`, `ValidationReport`, etc.),
- the generic semantic tree (`SemanticNode`, `NodeRef`),
- local declarative node schemas (`NodeSchema`, `AttributeSchema`,
  `ValidationRule`, `NodeValidationRule`),
- an opaque cross-product scripting representation (`script_node`).

These facilities must remain domain-neutral. OodiCore may know that a local
field is a finite positive real, but it must not know what a CAD box, mesh size,
finite-element space, or solver tolerance means.

## 3. Rule for downstream packages

Downstream packages (CAD/geometry, meshing, `Oodi.jl`, MCP servers, report
exporters, etc.) must import and extend shared generic functions rather than
shadowing them:

```julia
import OodiCore: report, validate, readiness

report(x::MyType) = ObjectReport(...)
validate(x::MyType) = ValidationReport(...)
readiness(x::MyType, target::PipelineTarget) = ReadinessReport(...)
```

Domain-specific report types are welcome and encouraged; they should subtype
`AbstractOodiReport`, `AbstractValidationReport`, or
`AbstractReadinessReport` as appropriate.

For declarative model nodes, domain packages own their vocabulary and may use
OodiCore's local schema machinery:

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
building a central OodiCore registry of Monge/Delone/Oodi concepts.

## 4. Do not add heavy dependencies

`OodiCore.jl` must remain safe to use as a base dependency from every other
Oodi package, including ones with no numerical or geometric code at all.
Concretely:

- No dependency beyond the Julia standard library unless there is a very
  strong, specific reason.
- No CAD kernels, meshing kernels, GPU packages, solver packages, or plotting
  packages.
- No dependency on `Oodi.jl` itself or on packages that depend on OodiCore.

Dependencies must flow one way, into OodiCore's consumers.

## 5. Do not add domain logic

No CAD logic, meshing logic, FEM/discretization logic, solver logic,
file-format backends, or rendering backends belong here.

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

OodiCore stores this contract but **never executes source code**. Script
execution is a trusted-code concern for a higher execution/orchestration layer,
which must explicitly bind inputs/outputs and enforce allowed effects.

## 10. Extending validation

OodiCore provides a small standard set of symbolic local rule kinds such as
`:finite`, `:gt`, `:ge`, `:lt`, `:le`, `:nonempty`, and `:one_of`.

A downstream package may add a genuinely reusable/domain-specific symbolic rule
by extending:

```julia
import OodiCore: check_validation_rule
check_validation_rule(::Val{:my_rule}, value, parameters) = ...
```

The rule must still be represented as `ValidationRule(:my_rule; ...)`, not an
opaque closure embedded in a schema.

Node-local cross-field rules use the same pattern:

```julia
import OodiCore: check_node_validation_rule
check_node_validation_rule(::Val{:my_node_rule}, node, parameters) = ...
```

Represent those as `NodeValidationRule(:my_node_rule; fields = (:a, :b), ...)`.
Name participating attributes in `fields` (or `left`/`right`) so missing or
ill-typed values skip the rule instead of producing secondary exceptions.

## 11. Out of scope for now

The following remain deliberately outside OodiCore unless a later architectural
decision expands the contract:

```julia
summary(x)
diagnose(x)
explain(x)
suggest_fixes(x)
provenance(x)
artifacts(x)
repair!
```

Also out of scope:

- domain constraint solvers,
- expression evaluation semantics,
- dependency-DAG/reference resolution,
- automatic or implicit script execution,
- security sandboxing for arbitrary user code.

If a task seems to require one of these, keep the representation/protocol in
OodiCore only when it is truly cross-product; keep the semantics in the owning
downstream package or orchestration layer.
