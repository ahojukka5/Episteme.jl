# Guide

These are the common record operations. Each path names the function and the
file it is defined in. The fences are ordinary Julia, not doctests.

The illustrations in the first six sections were run with
`julia --project=docs` from this checkout after `Pkg.instantiate()`. Output
is not pasted here. The `execute!` / `commit!` section was not executed for
this page. Its call shape is the one in `src/archive_execution.jl`; a
working fixture of the same shape is `test/archive_execution.jl`.

## Build a semantic node

`SemanticNode`, `add_child!`, `attribute`, and `set_attribute!` are defined
in `src/semantic_tree.jl`. Episteme does not interpret `kind`. Attribute
keys are stored in canonical order. Child order is kept. A `NodeRef` is not
resolved here.

```julia
using Episteme

parent = SemanticNode(:record, :parent; label = "root")
child = SemanticNode(:record, :child; count = 2)
add_child!(parent, child)
set_attribute!(child, :count, 3)
attribute(child, :count)
```

## Check a local schema

`NodeSchema`, `AttributeSchema`, `ValidationRule`, `validated_node`, and
`validate(node, schema)` are defined in `src/declarative.jl`.
`validated_node` builds the node and throws if the schema fails.
`validate` returns a `ValidationReport` and does not throw for an invalid
node. The built-in rule kinds used below are `:finite` and `:gt`.

```julia
using Episteme

schema = NodeSchema(
    Symbol("example/size"),
    AttributeSchema(
        :size,
        :real;
        rules = (ValidationRule(:finite), ValidationRule(:gt; value = 0.0)),
    ),
)
node = validated_node(schema, :sample; size = 1.5)
isvalid(validate(node, schema))
```

## Store a script contract

`script_node` is defined in `src/declarative.jl`. The node stores the source
and the declared inputs, outputs, and effects. Constructing it does not run
the source.

```julia
using Episteme

script_node(
    :lookup;
    language = :julia,
    source = "lookup(context)",
    inputs = (NodeRef(:id),),
    outputs = (:value,),
    effects = (:network,),
)
```

## Capture a portable document

`capture_portable` and `portable_sexpr` are defined in
`src/portable_document.jl`. Capture accepts a live tree whose leaves are in
the portable universe and returns a `PortableSemanticDocument`. It does not
write a file. `DocumentId` is defined in `src/archive_envelope.jl`.

```julia
using Episteme

root = SemanticNode(:note, :n; text = "hello")
document = capture_portable(DocumentId("doc-1"), root)
portable_sexpr(document)
```

## Report an in-memory archive graph

`ArchiveGraph`, `report`, and `validate` for a graph are defined in
`src/archive_envelope.jl`. An empty graph is a valid envelope with no
objects and no heads. This does not open a file.

```julia
using Episteme

graph = ArchiveGraph(ArchiveObject[])
report(graph)
isvalid(validate(graph))
```

`readiness(graph, target)` in the same file accepts the target names
`:execute`, `:commit`, and `:restart`. Any other name is not ready.

## Ask for an archive file without JLD2

`write_archive` and `inspect_archive` are defined as fail-closed stubs in
`src/archive_persistence.jl`. Without `using JLD2`, each call throws an
`ErrorException` whose message names `JLD2` and `episteme_jld2_ext`. Neither
call creates a file. The two lines below are separate calls: the second is
not reached if the first is evaluated in the same script. The real methods
are in `ext/episteme_jld2_ext.jl` and the files it includes.

```julia
using Episteme

write_archive("not-written.ah5")
inspect_archive("not-written.ah5")
```

## Run and commit in memory

`OperationSpec` and `Plan` are defined in `src/archive_history.jl`.
`execute!` and `commit!` are defined in `src/archive_execution.jl`.

`execute!(graph, plan; head, store)` records a run and stages outputs. It
does not move a workflow head. Domain behaviour is a method of

```julia
apply_operation(::Val{kind}, spec, inputs; context...)
```

also defined in `src/archive_execution.jl`. The default method returns a
failed `OperationOutcome` with code `:unknown_operation`. Payloads sit in a
`WorkingStore` (`store_payload!`, `fetch_payload` in the same file). The
archive envelope does not store domain bytes.

`commit!(graph, run_id; head)` promotes that run's staging set, mints one
revision, and moves one head. `recover_writes!` repairs in-flight write
transactions on the same in-memory graph. `restart!` starts a new run from
an incomplete run's `RestartRequirement`. None of these functions open an
`.ah5` file.

This call shape was not executed while writing this page:

```julia
run = execute!(graph, plan; head = :main, store = store)
revision = commit!(graph, run.id; head = :main, store = store)
```

`docs/workflow.md` is the contract for the same sequence:
plan, readiness, `execute!`, stage, validate, `commit!`, then an explicit
`write_archive` when a file is required.

## Other record operations

These are the next calls once a graph or a schema chain exists. They were
not executed for this page.

- `plan_purge` and `compact_archive` in `src/archive_purge.jl` compute
  reachability and a new graph. They do not mutate the source graph.
- `inspect`, `checkout`, `select`, and `branch_from` in
  `src/archive_checkout.jl` are lazy in-memory revision manifests. They do
  not load payloads and do not read a file.
- `canonical_content_id` in `src/content_integrity.jl` returns a `ContentId`
  of the form `sha256:<hex>`.
- `plan_migration` and `migrate_object` in `src/schema_migration.jl` plan
  and apply a semantic schema chain in memory. The source object is not
  rewritten. `materialize_migration` in `src/archive_persistence.jl` is the
  file form and, like `write_archive`, requires `JLD2`.
