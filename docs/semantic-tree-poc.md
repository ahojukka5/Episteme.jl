# Semantic tree PoC

This PoC adds a deliberately small, domain-neutral semantic tree representation
to `OodiCore.jl`.

The design rule is simple:

> OodiCore owns the representation; downstream packages own the vocabulary and
> semantics.

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
println(sexpr(model))
```

Canonical output:

```lisp
(geometry demo
  (monge/rectangle plate
    (height 5.0)
    (width 20.0)
  )
  (monge/extrude block
    (distance 3.0)
    (profile (ref plate))
  )
)
```

Attributes are sorted by key for deterministic output. Child order is
preserved because it may be semantically meaningful to the downstream
package.

## Deliberately out of scope

This first PoC does **not** add:

- an S-expression parser,
- schemas or domain validation,
- reference resolution,
- dependency-DAG construction,
- evaluation/lowering protocols,
- CAD, meshing, FEM, solver, or visualization concepts,
- MCP integration.

Those should only be added when the Monge PoC demonstrates a concrete need.
The next intended experiment is for `Monge.jl` to construct a tiny geometry
model with these primitives and evaluate it using Monge's own semantics.
