# ---------------------------------------------------------------------------
# Generic semantic tree
#
# Episteme owns only the representation. Downstream packages own the
# vocabulary and semantics of the nodes they put in the tree.
# ---------------------------------------------------------------------------

"""
    NodeRef(target)

A lightweight symbolic reference from one [`SemanticNode`](@ref) to a named
node or object in the same semantic model.

`Episteme` does not resolve or interpret references. The package that owns the
relevant node vocabulary decides what a reference means and how it is used.
"""
struct NodeRef
    target::Symbol
end

NodeRef(target::AbstractString) = NodeRef(Symbol(target))

"""
    SemanticNode(kind, [name]; kwargs...)

A small, domain-neutral node for building semantic model trees.

# Fields
- `kind::Symbol`: node vocabulary entry, e.g. `Symbol("monge/rectangle")`.
- `name::Union{Nothing,Symbol}`: optional stable semantic name.
- `attributes::Vector{Pair{Symbol,Any}}`: named leaf values in canonical key order.
- `children::Vector{SemanticNode}`: ordered child nodes.

`Episteme` deliberately attaches no meaning to `kind`, `name`, attributes, or
children. CAD, meshing, discretization, solver, and visualization packages own
those semantics themselves.

If Julia can hold a value, a [`SemanticNode`](@ref) attribute can hold it.
The in-memory tree is the authoritative model. Downstream packages own type,
shape, and value validation. Display uses ordinary Julia `show`.
"""
struct SemanticNode
    kind::Symbol
    name::Union{Nothing,Symbol}
    attributes::Vector{Pair{Symbol,Any}}
    children::Vector{SemanticNode}

    function SemanticNode(
        kind::Symbol,
        name::Union{Nothing,Symbol},
        attributes::Vector{Pair{Symbol,Any}},
        children::Vector{SemanticNode},
    )
        keys = first.(attributes)
        length(unique(keys)) == length(keys) ||
            throw(ArgumentError("SemanticNode attributes must have unique names"))

        canonical_attributes = sort(copy(attributes); by = pair -> String(first(pair)))
        return new(kind, name, canonical_attributes, copy(children))
    end
end

function SemanticNode(
    kind::Symbol,
    name::Union{Nothing,Symbol} = nothing;
    kwargs...,
)
    attributes = Pair{Symbol,Any}[]
    for (key, value) in kwargs
        push!(attributes, key => value)
    end
    return SemanticNode(kind, name, attributes, SemanticNode[])
end

Base.:(==)(a::NodeRef, b::NodeRef) = a.target == b.target
Base.:(==)(a::SemanticNode, b::SemanticNode) =
    a.kind == b.kind &&
    a.name == b.name &&
    a.attributes == b.attributes &&
    a.children == b.children

"""
    add_child!(parent, child) -> parent

Append `child` to `parent.children` and return `parent`.

Child order is semantic and is preserved.
"""
function add_child!(parent::SemanticNode, child::SemanticNode)
    push!(parent.children, child)
    return parent
end

Base.push!(parent::SemanticNode, child::SemanticNode) = add_child!(parent, child)

"""
    attribute(node, key)
    attribute(node, key, default)

Read an attribute from a [`SemanticNode`](@ref). The two-argument form throws
`KeyError` when the attribute is absent; the three-argument form returns
`default`.
"""
function attribute(node::SemanticNode, key::Symbol)
    index = findfirst(pair -> first(pair) == key, node.attributes)
    index === nothing && throw(KeyError(key))
    return last(node.attributes[index])
end

function attribute(node::SemanticNode, key::Symbol, default)
    index = findfirst(pair -> first(pair) == key, node.attributes)
    return index === nothing ? default : last(node.attributes[index])
end

"""
    set_attribute!(node, key, value) -> node

Set or add an attribute while preserving canonical attribute ordering. Returns
`node` so edits can be chained.
"""
function set_attribute!(node::SemanticNode, key::Symbol, value)
    index = findfirst(pair -> first(pair) == key, node.attributes)
    if index === nothing
        push!(node.attributes, key => value)
        sort!(node.attributes; by = pair -> String(first(pair)))
    else
        node.attributes[index] = key => value
    end
    return node
end

function Base.show(io::IO, ref::NodeRef)
    print(io, "NodeRef(")
    show(io, ref.target)
    print(io, ")")
end

function Base.show(io::IO, node::SemanticNode)
    print(io, "SemanticNode(")
    show(io, node.kind)
    if node.name !== nothing
        print(io, ", ")
        show(io, node.name)
    end
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", node::SemanticNode)
    indent = get(io, :semantic_indent, 0)
    pad = repeat(" ", indent)
    print(io, pad)
    show(io, node)
    inner = IOContext(io, :compact => true, :limit => true, :semantic_indent => indent + 2)
    for (key, value) in node.attributes
        print(io, "\n", pad, "  ")
        print(io, key, " = ")
        show(inner, value)
    end
    for child in node.children
        println(io)
        show(inner, MIME"text/plain"(), child)
    end
    return
end
