# ---------------------------------------------------------------------------
# Generic semantic tree
#
# OodiCore owns only the representation. Downstream packages own the
# vocabulary and semantics of the nodes they put in the tree.
# ---------------------------------------------------------------------------

"""
    NodeRef(target)

A lightweight symbolic reference from one [`SemanticNode`](@ref) to a named
node or object in the same semantic model.

`OodiCore` does not resolve or interpret references. The package that owns the
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

`OodiCore` deliberately attaches no meaning to `kind`, `name`, attributes, or
children. CAD, meshing, discretization, solver, and visualization packages own
those semantics themselves.

The supported portable attribute values for S-expression output are
`nothing`, `Bool`, integers, floating-point numbers, strings, symbols,
[`NodeRef`](@ref), tuples, and vectors composed recursively from those values.
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

Child order is semantic and is preserved by canonical S-expression output.
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

const _SIMPLE_SEMANTIC_SYMBOL = r"^[A-Za-z_][A-Za-z0-9_./:+*?!<>=-]*$"

function _write_semantic_symbol(io::IO, symbol::Symbol)
    text = String(symbol)
    if occursin(_SIMPLE_SEMANTIC_SYMBOL, text)
        print(io, text)
    else
        escaped = replace(replace(text, "\\" => "\\\\"), "|" => "\\|")
        print(io, "|", escaped, "|")
    end
end

function _write_semantic_value(io::IO, value)
    if value === nothing
        print(io, "nil")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Integer || value isa AbstractFloat
        print(io, value)
    elseif value isa AbstractString
        show(io, String(value))
    elseif value isa Symbol
        _write_semantic_symbol(io, value)
    elseif value isa NodeRef
        print(io, "(ref ")
        _write_semantic_symbol(io, value.target)
        print(io, ")")
    elseif value isa Tuple || value isa AbstractVector
        print(io, "(list")
        for item in value
            print(io, " ")
            _write_semantic_value(io, item)
        end
        print(io, ")")
    else
        throw(ArgumentError(
            "Unsupported semantic-tree value of type $(typeof(value)); " *
            "use portable scalar/list values or NodeRef",
        ))
    end
end

function _write_semantic_node(io::IO, node::SemanticNode, indent::Int)
    print(io, "(")
    _write_semantic_symbol(io, node.kind)
    if node.name !== nothing
        print(io, " ")
        _write_semantic_symbol(io, node.name)
    end

    for (key, value) in node.attributes
        print(io, "\n", repeat(" ", indent + 2), "(")
        _write_semantic_symbol(io, key)
        print(io, " ")
        _write_semantic_value(io, value)
        print(io, ")")
    end

    for child in node.children
        print(io, "\n", repeat(" ", indent + 2))
        _write_semantic_node(io, child, indent + 2)
    end

    if !isempty(node.attributes) || !isempty(node.children)
        print(io, "\n", repeat(" ", indent))
    end
    print(io, ")")
end

"""
    sexpr(node) -> String

Return the canonical S-expression representation of `node` and its subtree.

Attributes are sorted by key and children retain insertion order, so the same
semantic tree always produces the same textual representation. This first PoC
implements printing only; parsing is intentionally left for a later step.
"""
function sexpr(node::SemanticNode)
    io = IOBuffer()
    _write_semantic_node(io, node, 0)
    return String(take!(io))
end

Base.show(io::IO, ::MIME"text/plain", node::SemanticNode) = print(io, sexpr(node))
