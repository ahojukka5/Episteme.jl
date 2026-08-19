# Semantic tree

Episteme provides a domain-neutral semantic tree that every consumer package can
share. The in-memory Julia object tree is the authoritative model.

The design rule is simple:

> Julia types carry structure. Downstream packages carry semantics and
> validation. Episteme owns the shared tree and references.

`Episteme` does not know what a CAD rectangle, mesh, function space, weak form,
solver, or visualization is. Packages such as `Monge.jl`, `Delone.jl`,
`Oodi.jl`, and `Marey` may use the same generic tree structures to describe
their own domain objects without depending on each other.

## Tree API

```julia
using Episteme

plate = SemanticNode(
    Symbol("monge/rectangle"),
    :plate;
    width = 10.0,
    height = 5.0,
)

block = SemanticNode(
    Symbol("monge/extrude"),
    :block;
    profile = NodeRef(:plate),
    distance = 3.0,
)

model = SemanticNode(:geometry, :demo)
push!(model, plate)
push!(model, block)

set_attribute!(plate, :width, 20.0)
```

If Julia can hold a value, a `SemanticNode` attribute can hold it. Packages
communicate by sharing and traversing these objects. Attribute keys are stored
in a stable order; child order is preserved because it may be semantically
meaningful to the downstream package.

Use `add_child!` (or `push!`), `attribute`, and `set_attribute!` to edit the
tree. `Episteme` does not resolve `NodeRef` values; the package that owns the
node vocabulary decides what a reference means.

Differentiability is not a semantic type annotation. The same parameter node
may hold `1.4` or a dual-like `Real` without changing the meaning of the node.

Display uses ordinary Julia `show`. Leaf values print with their own `show`
methods. Episteme does not define a serialization or interchange format for
arbitrary runtime objects, and `to_namedtuple` has no method for
`SemanticNode` or `NodeRef`. Portable declarative documents (issue #34) are
a strict subset of this tree and may be persisted through the shared
archive vocabulary. Physical `.ah5` encoding is the later JLD2-backed AH5 profile inside Episteme.
See [`archive-ownership.md`](archive-ownership.md). Domain packages still
own codecs for their custom portable value types.

Episteme does not depend on an AD library and does not store reverse-mode
tapes, pullbacks, or backend contexts as semantic model data.

## Local schemas

Local schemas and node-local cross-field rules are part of the current
contract. See [`declarative-contracts.md`](declarative-contracts.md).

A schema can say that one node is well-formed in isolation: required fields,
portable value kinds, finiteness, ranges, enums, and node-local orderings
such as `min <= default <= max`. Domain constraints that relate several
objects, derived quantities, or physical equations stay in the owning
package.

Use `validate(node, schema)` for a structured `ValidationReport`, or
`validated_node(...)` for fail-fast construction. `script_node` is the shared
scripting escape hatch; Episteme stores the contract and never executes
source.

## Still out of scope

Episteme still does **not** own:

- a serialization or interchange protocol for arbitrary runtime objects,
- HDF5/XDMF/AH5 readers or writers,
- reference resolution,
- dependency-DAG construction,
- evaluation/lowering protocols,
- CAD, meshing, FEM, solver, or visualization concepts,
- MCP integration,
- domain constraint solving.

Those remain the responsibility of the owning downstream package or a later
orchestration layer. Downstream packages such as `Monge.jl` construct models
with these primitives and evaluate them using their own semantics.
