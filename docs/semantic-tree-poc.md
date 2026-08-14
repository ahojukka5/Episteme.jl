# Semantic tree PoC

This PoC adds a deliberately small, domain-neutral semantic tree representation
to `OodiCore.jl`.

The design rule is simple:

> Julia types carry structure. Downstream packages carry semantics and
> validation. OodiCore owns the shared tree and references.

`OodiCore` does not know what a CAD rectangle, mesh, function space, weak form,
solver, or visualization is. Packages such as `Monge.jl`, `Delone.jl`,
`Oodi.jl`, and `Marey` may use the same generic tree structures to describe
their own domain objects without depending on each other.

## Minimal API

```julia
using OodiCore

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

Differentiability is not a semantic type annotation. The same parameter node
may hold `1.4` or a dual-like `Real` without changing the meaning of the node.

Display uses ordinary Julia `show`. Leaf values print with their own `show`
methods. OodiCore does not define a serialization or interchange format for
arbitrary runtime objects. Persistence can later use Julia `Serialization`,
JSON3, JLD2, or similar, with extensions owned by the package that owns a
custom type.

OodiCore does not depend on an AD library and does not store reverse-mode
tapes, pullbacks, or backend contexts as semantic model data.

## Deliberately out of scope

This first PoC does **not** add:

- schemas or domain validation,
- a serialization or interchange protocol,
- reference resolution,
- dependency-DAG construction,
- evaluation/lowering protocols,
- CAD, meshing, FEM, solver, or visualization concepts,
- MCP integration.

Those should only be added when the Monge PoC demonstrates a concrete need.
The next intended experiment is for `Monge.jl` to construct a tiny geometry
model with these primitives and evaluate it using Monge's own semantics.
