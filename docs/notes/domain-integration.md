# Integrating and extending Episteme

Moved verbatim from the root `AGENTS.md`, which links here. Package
boundaries and invariants stay in `AGENTS.md`.

## Integrating domain packages

Keep direct Julia APIs first-class. A declarative authoring API is an
additional frontend where useful; it lowers to the same domain-owned
implementation and must not force ordinary callers to build semantic trees.
Do not duplicate scientific implementations between the two surfaces.
The canonical rule, including equivalence checks and API evolution, is
[`docs/declarative-contracts.md#direct-and-declarative-apis-are-first-class`](../declarative-contracts.md#direct-and-declarative-apis-are-first-class).

Packages choosing Episteme integration import and extend its generic
functions rather than shadowing them. Independent packages may participate
through public consumer-owned ports and integrator-owned adapters without an
Episteme dependency or central registration (SWE-013):

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

## Designed for future tool-server exposure

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

## Extending validation

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

## Out of scope for now

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

- `branch!` / `rerun!` runtime (`execute!` / `commit!` / `restart!` /
  `recover_writes!` are in-memory; they do not write `.ah5` files),
- distributed scheduling and automatic persist-on-execute,
- optional parallel/bulk archive I/O extensions not yet implemented,
- speculative multi-backend storage abstractions without a real second backend,
- domain constraint solvers and expression evaluators,
- automatic or implicit execution of arbitrary scripts,
- security sandboxing for arbitrary user code.

If a task needs one of these, keep only the cross-domain representation and
protocol in Episteme; keep the scientific semantics in the domain package that
owns them.
