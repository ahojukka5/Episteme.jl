# AGENTS.md — Episteme.jl

Guidance for AI agents and humans working on or with this package.

## 1. What this package is

`Episteme.jl` is the semantic runtime and persistent scientific backbone for
composable, reproducible, and eventually autonomous research.

Domain packages own scientific payloads and operation semantics. Episteme owns
the shared semantics, schemas/contracts, identities and history vocabulary,
the orchestration protocol, and JLD2-backed AH5 persistence.

The accepted v1 product is:

```text
Episteme.jl = semantics + schemas + history/provenance
            + orchestration protocol
            + JLD2-backed AH5 persistence
```

JLD2 and the `.ah5` writer are planned focused implementation steps. HDF5.jl
remains later optional extension work for direct/bulk/parallel HDF5 needs.

See [`docs/research/episteme-architecture.md`](docs/research/episteme-architecture.md)
and [`docs/archive-ownership.md`](docs/archive-ownership.md).

## 2. What it owns

Episteme owns the common introspection generics:

- `report(x)`
- `validate(x)`
- `readiness(x, target)`

These are declared here so domain packages extend the same functions instead of
creating locally scoped lookalikes.

It also owns shared, domain-neutral supporting types and protocols:

- reports and diagnostics (`DiagnosticMessage`, `ValidationReport`, etc.),
- the generic semantic tree (`SemanticNode`, `NodeRef`),
- local declarative node schemas (`NodeSchema`, `AttributeSchema`,
  `ValidationRule`, `NodeValidationRule`),
- opaque scripting contracts (`script_node`),
- scientific-archive identities, references, schema-version vocabulary,
  portable document envelopes, provenance/history records, and the
  durable run/commit/restart contract (status, staging, write phases,
  restart refs).

Shared infrastructure kinds use the `:episteme` / `episteme/*` namespace.
Domain kinds stay in the namespace of the domain package that owns them.

These facilities must remain domain-neutral. Episteme may understand generic
structural properties such as a finite positive scalar, but it must not know
the scientific meaning of a package-specific model, discretization, solver,
experiment, or analysis object.

## 3. Rule for domain packages

Domain packages must import and extend shared generic functions rather than
shadowing them:

```julia
import Episteme: report, validate, readiness

report(x::MyType) = ObjectReport(...)
validate(x::MyType) = ValidationReport(...)
readiness(x::MyType, target::PipelineTarget) = ReadinessReport(...)
```

Domain-specific report types may subtype `AbstractEpistemeReport`,
`AbstractValidationReport`, or `AbstractReadinessReport` as appropriate.

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
building a central registry of scientific concepts in Episteme.

## 4. Dependencies

Dependencies must support Episteme's cross-domain role rather than pull domain
science into the shared layer.

Do not add domain-specific simulation, geometry, meshing, solver, accelerator,
visualization, device, or model-serving stacks merely because one consumer uses
them. JLD2 is part of the accepted persistence story. HDF5.jl and MPI remain
optional future extensions for bulk and parallel archive I/O.

Dependencies must flow one way: domain packages may depend on Episteme;
Episteme must not depend on domain packages.

## 5. Do not add domain logic

Episteme must not contain domain-specific scientific or numerical semantics.
Keep these concerns in the package that owns the domain:

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

Local schema validation is in scope only when the rule is structurally generic:
required fields, portable value kinds, finiteness, ranges, non-empty values,
enums, node-local cross-field orderings, and similarly local invariants.

Cross-object scientific equations and constraints belong to the domain package
that owns their meaning and to its own evaluator/planner when needed.

## 6. Keep shared types structured, serializable, and readable

Any new shared type should:

- be a plain immutable `struct` with simple fields when practical,
- avoid opaque function closures when a symbolic/introspectable representation
  is possible,
- have a `to_namedtuple` method when appropriate,
- remain useful to humans and agents without inspecting internal Julia state.

Validation rules in particular are data (`kind + parameters`), not closures, so
agents and tool layers can inspect the same rules the runtime enforces.

## 7. Introspection functions are read-only

`report`, `validate`, and `readiness` must never mutate the object they inspect.
They answer questions; they do not change state.

## 8. Mutating functions must use explicit `!` naming

If a function mutates its argument, use a trailing `!` per Julia convention.
Do not blur mutation with the read-only introspection API.

## 9. Designed for future tool-server exposure

Shared reports, semantic nodes, schemas, validation rules, archive records, and
script contracts are deliberately structured so tool-server layers can expose
them with minimal translation.

The shared script representation is an important trust boundary:

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

Episteme stores this contract but does not implicitly execute arbitrary source.
Execution belongs to a trusted orchestration path that binds inputs/outputs and
enforces allowed effects.

## 10. Extending validation

Episteme provides a small standard set of symbolic local rule kinds such as
`:finite`, `:gt`, `:ge`, `:lt`, `:le`, `:nonempty`, and `:one_of`.

A domain package may add a genuinely reusable symbolic rule by extending:

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

Represent them as `NodeValidationRule(:my_node_rule; fields = (:a, :b), ...)`.
Name participating attributes explicitly so missing or ill-typed values can
produce stable diagnostics rather than secondary exceptions.

## 11. Out of scope for now

The following introspection generics remain outside the current contract unless
a later architectural decision adds them:

```julia
summary(x)
diagnose(x)
explain(x)
suggest_fixes(x)
provenance(x)
artifacts(x)
repair!
```

Archive record types are in scope as structured data even when the higher-level
runtime operation using them has not landed yet.

Also out of scope in the current implementation:

- `execute!` / `commit!` / `branch!` / `rerun!` runtime (lifecycle *records*
  and `validate` / `readiness` for them are in scope),
- orchestration execution paths not yet implemented,
- optional parallel/bulk archive I/O extensions not yet implemented,
- speculative multi-backend storage abstractions without a real second backend,
- domain constraint solvers and expression evaluators,
- automatic or implicit execution of arbitrary scripts,
- security sandboxing for arbitrary user code.

If a task needs one of these, keep only the cross-domain representation and
protocol in Episteme; keep the scientific semantics in the domain package that
owns them.
