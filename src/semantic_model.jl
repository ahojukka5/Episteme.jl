# ---------------------------------------------------------------------------
# Semantic models: a named reference graph over SemanticNode values
#
# A model is a flat list of named nodes whose attributes may point at each
# other through `NodeRef`. Episteme checks only graph structure: stable
# names, resolvable references, the node kinds a reference may point at,
# local node schemas, and acyclic dependencies. What a node kind means, and
# how a model is lowered or executed, belongs to the package that owns the
# vocabulary.
# ---------------------------------------------------------------------------

const EPISTEME_MODEL_KIND = Symbol("episteme/model")

"""
    SemanticModel(nodes...; name=:model, kind=EPISTEME_MODEL_KIND)
    SemanticModel(nodes::AbstractVector{<:SemanticNode}; name, kind)

A named dependency graph of [`SemanticNode`](@ref) values.

The model root is an ordinary `SemanticNode` whose children are the model
nodes. Each child should carry a unique stable name; attributes that hold a
[`NodeRef`](@ref) (directly or inside a tuple, named tuple, or vector) are the
graph edges. `model[name]` returns the node with that name.

Episteme gives the nodes no meaning. Use [`validate`](@ref) with schemas and
reference kinds to check structure, and [`dependency_order`](@ref) to visit
nodes after the nodes they reference.
"""
struct SemanticModel
    root::SemanticNode

    function SemanticModel(
        nodes::AbstractVector{<:SemanticNode};
        name::Symbol = :model,
        kind::Symbol = EPISTEME_MODEL_KIND,
    )
        root = SemanticNode(kind, name)
        for child in nodes
            add_child!(root, child)
        end
        return new(root)
    end
end

SemanticModel(first_node::SemanticNode, nodes::SemanticNode...; kwargs...) =
    SemanticModel(SemanticNode[first_node, nodes...]; kwargs...)

SemanticModel(; kwargs...) = SemanticModel(SemanticNode[]; kwargs...)

"""
    model_nodes(model::SemanticModel) -> Vector{SemanticNode}

The model nodes in insertion order. The returned vector is the model's own
storage; mutate it only to build the model.
"""
model_nodes(model::SemanticModel) = model.root.children

Base.length(model::SemanticModel) = length(model_nodes(model))

function Base.getindex(model::SemanticModel, name::Symbol)
    index = findfirst(node -> node.name === name, model_nodes(model))
    index === nothing && throw(KeyError(name))
    return model_nodes(model)[index]
end

Base.getindex(model::SemanticModel, name::AbstractString) = model[Symbol(name)]

Base.haskey(model::SemanticModel, name::Symbol) =
    any(node -> node.name === name, model_nodes(model))

function Base.show(io::IO, model::SemanticModel)
    print(io, "SemanticModel(root=:", model.root.name, ", nodes=")
    print(io, [node.name for node in model_nodes(model)], ")")
end

_collect_refs!(refs, value::NodeRef) = push!(refs, value)
_collect_refs!(refs, value::Union{Tuple,NamedTuple,AbstractVector}) =
    foreach(v -> _collect_refs!(refs, v), value)
_collect_refs!(refs, value) = refs

"""
    node_refs(node::SemanticNode) -> Vector{NodeRef}

Every [`NodeRef`](@ref) held by the attributes of `node`, including refs
inside tuples, named tuples, and vectors, in attribute order. Children are not
searched: a child is part of its parent, not a graph edge.
"""
function node_refs(node::SemanticNode)
    refs = NodeRef[]
    for (_, value) in node.attributes
        _collect_refs!(refs, value)
    end
    return refs
end

_attribute_refs(node::SemanticNode) =
    [(name, ref) for (name, value) in node.attributes for ref in _collect_refs!(NodeRef[], value)]

_allowed_kinds(kinds::Symbol) = (kinds,)
_allowed_kinds(kinds) = Tuple(kinds)

function _nodes_by_name(model::SemanticModel)
    nodes_by_name = Dict{Symbol,SemanticNode}()
    for node in model_nodes(model)
        node.name === nothing && continue
        haskey(nodes_by_name, node.name) || (nodes_by_name[node.name] = node)
    end
    return nodes_by_name
end

function _dependency_names(node::SemanticNode, nodes_by_name)
    names = Symbol[ref.target for ref in node_refs(node) if haskey(nodes_by_name, ref.target)]
    return sort!(unique!(names); by = String)
end

function _cycle_diagnostics(nodes_by_name::Dict{Symbol,SemanticNode})
    diagnostics = DiagnosticMessage[]
    state = Dict{Symbol,UInt8}()
    stack = Symbol[]
    reported = Set{Symbol}()

    function visit(name::Symbol)
        state[name] = 0x01
        push!(stack, name)
        for target in _dependency_names(nodes_by_name[name], nodes_by_name)
            target_state = get(state, target, 0x00)
            if target_state == 0x00
                visit(target)
            elseif target_state == 0x01 && !(target in reported)
                start = findfirst(==(target), stack)
                cycle = [stack[start:end]..., target]
                push!(diagnostics, error_diagnostic(
                    :dependency_cycle,
                    "Model dependencies contain a cycle: " * join(string.(cycle), " -> ");
                    cycle = Tuple(cycle),
                ))
                push!(reported, target)
            end
        end
        pop!(stack)
        state[name] = 0x02
        return nothing
    end

    for name in sort!(collect(keys(nodes_by_name)); by = String)
        get(state, name, 0x00) == 0x00 && visit(name)
    end
    return diagnostics
end

"""
    validate(model::SemanticModel; schemas=nothing, references=Dict()) -> ValidationReport

Check the structure of a semantic model without interpreting it.

Always checked:

- every node has a name, names are unique, and no node reuses the root name;
- every [`NodeRef`](@ref) names a node in the model (`:unresolved_reference`);
- references form no cycle (`:dependency_cycle`).

With `schemas`, a dictionary from node kind to [`NodeSchema`](@ref), every node
kind must have a schema (`:unknown_kind`) and each node is validated against
it.

`references` states which node kinds an attribute may point at, as data:
`Dict(kind => (attribute = target_kind,))`, where `target_kind` is a kind or a
collection of kinds. A reference to a node of another kind is reported as
`:incompatible_reference`.

The report subject is `:semantic_model`. Callers that own the vocabulary add
their own diagnostics for meaning Episteme does not know.
"""
function validate(
    model::SemanticModel;
    schemas::Union{Nothing,AbstractDict} = nothing,
    references::AbstractDict = Dict{Symbol,NamedTuple}(),
)
    diagnostics = DiagnosticMessage[]
    nodes = model_nodes(model)
    root_name = model.root.name
    if root_name !== nothing && any(node -> node.name === root_name, nodes)
        push!(diagnostics, error_diagnostic(
            :duplicate_root_name,
            "The model root name :$(root_name) is already used by a model node.";
            name = root_name,
        ))
    end

    seen = Set{Symbol}()
    for node in nodes
        if node.name === nothing
            push!(diagnostics, error_diagnostic(
                :unnamed_node,
                "Every model node must have a stable name.";
                kind = node.kind,
            ))
        elseif node.name in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_node_name,
                "Model node name :$(node.name) occurs more than once.";
                node = node.name,
            ))
        else
            push!(seen, node.name)
        end
    end

    nodes_by_name = _nodes_by_name(model)
    for node in nodes
        if schemas !== nothing
            node_schema = get(schemas, node.kind, nothing)
            if node_schema === nothing
                push!(diagnostics, error_diagnostic(
                    :unknown_kind,
                    "Node :$(node.name) uses kind :$(node.kind), which has no schema.";
                    node = node.name,
                    kind = node.kind,
                ))
            else
                append!(diagnostics, validate(node, node_schema).diagnostics)
            end
        end

        expected = get(references, node.kind, (;))
        for (attribute_name, ref) in _attribute_refs(node)
            target = get(nodes_by_name, ref.target, nothing)
            if target === nothing
                push!(diagnostics, error_diagnostic(
                    :unresolved_reference,
                    "Node :$(node.name) references unknown node :$(ref.target).";
                    node = node.name,
                    attribute = attribute_name,
                    reference = ref.target,
                ))
            elseif haskey(expected, attribute_name)
                allowed = _allowed_kinds(expected[attribute_name])
                target.kind in allowed || push!(diagnostics, error_diagnostic(
                    :incompatible_reference,
                    "Node :$(node.name) attribute :$(attribute_name) points to " *
                    ":$(target.kind), expected " *
                    join((":$(kind)" for kind in allowed), " or ") * ".";
                    node = node.name,
                    attribute = attribute_name,
                    expected = length(allowed) == 1 ? only(allowed) : allowed,
                    actual = target.kind,
                ))
            end
        end
    end
    append!(diagnostics, _cycle_diagnostics(nodes_by_name))

    return ValidationReport(
        :semantic_model,
        !any(diagnostic -> diagnostic.severity === :error, diagnostics),
        diagnostics,
        (; root = root_name, nodes = length(nodes), kinds = Tuple(node.kind for node in nodes)),
    )
end

"""
    dependency_order(model::SemanticModel) -> Vector{Symbol}

Node names ordered so that every node comes after the nodes it references.

The order is deterministic: ties are broken by node name, so the same model
always gives the same order regardless of insertion order. Throws
`ArgumentError` when the model has unnamed or duplicate nodes, unresolved
references, or a dependency cycle; call [`validate`](@ref) first to get those
as diagnostics.
"""
function dependency_order(model::SemanticModel)
    structural = validate(model)
    isvalid(structural) || throw(ArgumentError(
        "cannot order an invalid semantic model: " *
        join((diagnostic.message for diagnostic in structural.diagnostics), " "),
    ))
    nodes_by_name = _nodes_by_name(model)
    visited = Set{Symbol}()
    order = Symbol[]

    function visit(name::Symbol)
        name in visited && return nothing
        push!(visited, name)
        foreach(visit, _dependency_names(nodes_by_name[name], nodes_by_name))
        push!(order, name)
        return nothing
    end

    foreach(visit, sort!(collect(keys(nodes_by_name)); by = String))
    return order
end

function report(model::SemanticModel)
    validation = validate(model)
    diagnostics = copy(validation.diagnostics)
    isempty(diagnostics) && push!(diagnostics, info_diagnostic(
        :structurally_valid,
        "Model names and references are consistent and acyclic.";
        nodes = length(model),
    ))
    return ObjectReport(
        :semantic_model,
        "Semantic model with $(length(model)) nodes.",
        validation.metadata,
        diagnostics,
        ArtifactRef[],
    )
end

function _node_to_namedtuple(node::SemanticNode)
    return (
        kind = node.kind,
        name = node.name,
        attributes = Tuple(node.attributes),
        children = Tuple(_node_to_namedtuple(child) for child in node.children),
    )
end

to_namedtuple(model::SemanticModel) = _node_to_namedtuple(model.root)
