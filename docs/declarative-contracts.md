# Shared declarative contracts

OodiCore provides two domain-neutral facilities intended for every declarative
package in the Oodi ecosystem: local node schemas and an opaque scripting
escape hatch.

Domain packages still own their vocabularies and semantics. Monge decides what
`monge/box` means, Delone decides what its mesh controls mean, and Oodi decides
what its discretization and solver nodes mean. OodiCore only provides common
representation and validation contracts.

## Local schemas are not domain constraints

A local schema describes whether one node is well-formed in isolation. Typical
questions are:

- is a required attribute present?
- is a value a real number, integer, symbol, string, list, or reference?
- is a numeric value finite?
- is it greater than zero or inside a permitted interval?
- is a string/list non-empty?
- is a value one of an allowed set?

For example, a Monge box can use the same generic mechanism that Delone later
uses for element size and Oodi uses for solver tolerances:

```julia
positive_real = (
    ValidationRule(:finite),
    ValidationRule(:gt; value = 0.0),
)

box_schema = NodeSchema(
    Symbol("monge/box"),
    AttributeSchema(:width, :real; allow_ref = true, rules = positive_real),
    AttributeSchema(:depth, :real; allow_ref = true, rules = positive_real),
    AttributeSchema(:height, :real; allow_ref = true, rules = positive_real),
)
```

The rules are data, not function closures. This is deliberate: schemas can be
serialized with `to_namedtuple`, shown to an agent, or exposed through an MCP
schema without maintaining a second description of the same API.

`allow_ref=true` means that a symbolic `NodeRef` may temporarily stand in for
the eventual concrete value. Local value rules are then deferred until the
reference/expression resolver has produced a concrete value.

Use `validate(node, schema)` for a structured `ValidationReport`, or
`validated_node(schema, name; ...)` for fail-fast construction:

```julia
block = validated_node(
    box_schema,
    :block;
    width = 0.4,
    depth = 0.5,
    height = 2.0,
)
```

Values such as `0.0`, `Inf`, or `NaN` fail the example schema.

This is intentionally different from a domain constraint system. Relations
such as

```text
hole.center_xy == box.center_xy
volume(box) <= 2
box.z == volume(box) / (box.x * box.y)
```

connect multiple semantic quantities and belong to the package that owns those
semantics. OodiCore does not implement or solve such constraints.

## Standard validation rules

OodiCore currently provides symbolic rule kinds:

- `:finite`
- `:gt`
- `:ge`
- `:lt`
- `:le`
- `:nonempty`
- `:one_of`

Downstream packages can introduce additional serializable rule kinds by
extending `check_validation_rule(Val(:rule_name), value, parameters)`. The rule
remains inspectable data even when its evaluator is package-specific.

## Scripting is a core escape hatch

Every declarative package eventually encounters behavior that is too rare,
experimental, or inherently programmatic to deserve a permanent first-class
node. External database access is a typical example.

OodiCore therefore provides `script_node`:

```julia
script = script_node(
    :catalog_dimensions;
    language = :julia,
    source = "fetch_dimensions(context)",
    inputs = (NodeRef(:catalog_id),),
    outputs = (:width, :height),
    effects = (:network,),
)
```

which has canonical form:

```lisp
(oodi/script catalog_dimensions
  (effects (list network))
  (inputs (list (ref catalog_id)))
  (language julia)
  (outputs (list width height))
  (source "fetch_dimensions(context)"))
```

The node kind is shared and the implementation language is an attribute. This
keeps scripting usable by Monge, Delone, Oodi, and future packages without
hard-coding Julia into the semantic vocabulary. `language` defaults to `:julia`
for ergonomic use from the Julia ecosystem, but the representation itself is
not Julia-specific.

### Source text is authoritative; parsed AST is execution state

Even for `language = :julia`, the semantic model stores source as text rather
than a Julia `Expr`. This is intentional.

A Julia `Expr` is an execution/parser representation, not a portable source
format. Programmatically constructed expressions can contain arbitrary runtime
Julia objects, and parsing into an `Expr` also discards exact source formatting
and comments. Persisting such an AST would therefore weaken the properties we
want from the semantic model: deterministic serialization, readable diffs,
transport across processes, and language independence.

The intended Julia execution path is instead:

```text
source::String in semantic tree
        -> explicit trusted Julia runner
        -> parse source (for example with Meta.parseall / JuliaSyntax)
        -> Expr / lowered execution state
        -> execute with declared inputs, outputs, and effects
```

A runner may cache the parsed AST, validate Julia syntax before execution, or
apply additional policy checks. That parsed representation is runtime state and
is not part of the persisted semantic tree. If a convenient Julia authoring
helper that accepts an `Expr` is added later, it should still lower to canonical
source or another explicitly portable representation before entering the tree;
it must not make arbitrary Julia objects part of the serialized model.

OodiCore never executes script source. A script is a trusted-code boundary, not
a sandbox. A later execution layer must opt in explicitly, bind declared
inputs/outputs, and decide whether declared effects such as `:network` or
`:filesystem` are allowed.

A useful lifecycle is:

```text
one-off script
    -> repeated/useful pattern
    -> first-class domain operation/expression
    -> script removed from that model
```

This keeps the permanent declarative vocabulary small without sacrificing the
ability to express unusual real-world workflows.
