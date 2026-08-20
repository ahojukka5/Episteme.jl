# ---------------------------------------------------------------------------
# Portable declarative documents (#34)
#
# Fail-closed interchange subset of live SemanticNode trees. Capture does not
# eval, does not change #12, and does not persist files.
# ---------------------------------------------------------------------------

"""
    PortableEncoded(kind, data)

Inspectable stand-in for a package-registered portable value. Generic
readers can show `kind` and `data` without the defining type.
`portable_decode` reconstructs the original value when a codec exists.
"""
struct PortableEncoded
    kind::Symbol
    data::NamedTuple
end

"""
    PortableNode(kind, name, attributes, children)

Canonical portable node. Attribute values are members of the portable
universe, not arbitrary Julia runtime objects.
"""
struct PortableNode
    kind::Symbol
    name::Union{Nothing,Symbol}
    attributes::Vector{Pair{Symbol,Any}}
    children::Vector{PortableNode}
end

function PortableNode(
    kind::Symbol,
    name::Union{Nothing,Symbol},
    attributes,
    children,
)
    attrs = _portable_attribute_pairs(attributes)
    kids = _typed_vector(PortableNode, children, "portable children")
    return PortableNode(kind, name, attrs, kids)
end

function _portable_attribute_pairs(attributes)
    pairs = Pair{Symbol,Any}[]
    for item in attributes
        item isa Pair || throw(ArgumentError("portable attributes must be Pair values"))
        first(item) isa Symbol || throw(ArgumentError("portable attribute names must be Symbol"))
        push!(pairs, first(item) => last(item))
    end
    keys = first.(pairs)
    length(unique(keys)) == length(keys) ||
        throw(ArgumentError("PortableNode attributes must have unique names"))
    return sort!(pairs; by = pair -> String(first(pair)))
end

"""
    PortableSemanticDocument(id, fragments; schema=episteme_document_schema(),
                             metadata=(;))

Authored portable document. Fragments are package-owned portable roots.
This is an interchange/inspection capability, not the default working-archive
persistence path and not a live composition/runtime tree.
"""
struct PortableSemanticDocument
    id::DocumentId
    schema::SchemaRef
    fragments::Vector{PortableNode}
    metadata::NamedTuple
end

function PortableSemanticDocument(
    id::DocumentId,
    fragments;
    schema::SchemaRef = episteme_document_schema(),
    metadata::NamedTuple = (;),
)
    schema_kind(schema) === EPISTEME_DOCUMENT_KIND || throw(ArgumentError(
        "document schema kind must be $EPISTEME_DOCUMENT_KIND, got $(schema_kind(schema))",
    ))
    return PortableSemanticDocument(
        id,
        schema,
        _typed_vector(PortableNode, fragments, "document fragments"),
        metadata,
    )
end

"""
    portable_encode(value) -> Union{Nothing,NamedTuple}

Extension point for package-registered portable values. Return
`(kind = Symbol("pkg/type"), data = (; ...))` or `nothing` if this type
has no portable codec. The default is `nothing`.
"""
portable_encode(::Any) = nothing

"""
    portable_decode(Val(kind), data) -> Any

Reconstruct a registered portable value from its inspectable `data`.
The default returns a [`PortableEncoded`](@ref) stand-in.
"""
portable_decode(::Val{K}, data::NamedTuple) where {K} = PortableEncoded(K, data)
portable_decode(kind::Symbol, data::NamedTuple) = portable_decode(Val(kind), data)

Base.:(==)(a::PortableEncoded, b::PortableEncoded) = a.kind == b.kind && a.data == b.data
Base.:(==)(a::PortableNode, b::PortableNode) =
    a.kind == b.kind &&
    a.name == b.name &&
    a.attributes == b.attributes &&
    a.children == b.children
Base.:(==)(a::PortableSemanticDocument, b::PortableSemanticDocument) =
    a.id == b.id && a.schema == b.schema && a.fragments == b.fragments && a.metadata == b.metadata

"""
    is_portable_value(value) -> Bool

True when `value` is in the portable universe or has a registered codec.
Does not mutate `value`.
"""
is_portable_value(value) = _capture_value!(DiagnosticMessage[], value, "", nothing) !== :__unsupported__

function _node_path(node::SemanticNode, index::Int)
    node.name === nothing ? "#$index" : String(node.name)
end

function _child_path(parent_path::AbstractString, child::SemanticNode, index::Int)
    return parent_path * "/" * _node_path(child, index)
end

function _capture_integer!(diagnostics, value, path, attribute)
    try
        return Int(value)
    catch
        push!(diagnostics, error_diagnostic(
            :unsupported_portable_value,
            "integer $(typeof(value)) at $path does not fit in Int";
            node = path,
            attribute = attribute,
            julia_type = string(typeof(value)),
        ))
        return :__unsupported__
    end
end

function _capture_value!(diagnostics, value, path, attribute)
    value isa Bool && return value
    value isa Char && return _reject_portable!(
        diagnostics, value, path, attribute, "characters are not portable scalars",
    )
    if value isa Integer && !(value isa Bool)
        return _capture_integer!(diagnostics, value, path, attribute)
    end
    value isa Float64 && return value
    value isa AbstractString && return String(value)
    value isa Symbol && return value
    value === nothing && return nothing
    value isa NodeRef && return value
    value isa PortableEncoded && return value
    value isa AbstractArray && ndims(value) >= 1 &&
        return _capture_array!(diagnostics, value, path, attribute)
    value isa Tuple && return _capture_tuple!(diagnostics, value, path, attribute)
    value isa NamedTuple && return _capture_namedtuple!(diagnostics, value, path, attribute)
    value isa AbstractDict && return _capture_dict!(diagnostics, value, path, attribute)

    encoded = portable_encode(value)
    if encoded isa NamedTuple && haskey(encoded, :kind) && haskey(encoded, :data)
        encoded.kind isa Symbol || return _reject_portable!(
            diagnostics, value, path, attribute, "codec kind must be a Symbol",
        )
        encoded.data isa NamedTuple || return _reject_portable!(
            diagnostics, value, path, attribute, "codec data must be a NamedTuple",
        )
        data, ok = _capture_namedtuple_data!(diagnostics, encoded.data, path, attribute)
        ok || return :__unsupported__
        return PortableEncoded(encoded.kind, data)
    end
    return _reject_portable!(diagnostics, value, path, attribute)
end

function _reject_portable!(diagnostics, value, path, attribute, detail = nothing)
    message = detail === nothing ?
        "value of type $(typeof(value)) at $path is not portable" :
        "value of type $(typeof(value)) at $path is not portable ($detail)"
    push!(diagnostics, error_diagnostic(
        :unsupported_portable_value,
        message;
        node = path,
        attribute = attribute,
        julia_type = string(typeof(value)),
    ))
    return :__unsupported__
end

function _capture_array!(diagnostics, value, path, attribute)
    ndims(value) == 0 && return _reject_portable!(
        diagnostics, value, path, attribute, "zero-dimensional arrays are not portable",
    )
    items = Any[]
    ok = true
    for item in value
        captured = _capture_value!(diagnostics, item, path, attribute)
        if captured === :__unsupported__
            ok = false
        else
            push!(items, captured)
        end
    end
    ok || return :__unsupported__
    eltype(value) === Bool && return reshape(Bool[items...], size(value))
    eltype(value) <: Integer && !(eltype(value) <: Bool) &&
        return reshape(Int[items...], size(value))
    eltype(value) === Float64 && return reshape(Float64[items...], size(value))
    eltype(value) <: AbstractString && return reshape(String[items...], size(value))
    eltype(value) === Symbol && return reshape(Symbol[items...], size(value))
    return reshape(collect(Any, items), size(value))
end

function _capture_tuple!(diagnostics, value, path, attribute)
    items = Any[]
    ok = true
    for item in value
        captured = _capture_value!(diagnostics, item, path, attribute)
        if captured === :__unsupported__
            ok = false
        else
            push!(items, captured)
        end
    end
    ok || return :__unsupported__
    return Tuple(items)
end

function _capture_namedtuple!(diagnostics, value, path, attribute)
    data, ok = _capture_namedtuple_data!(diagnostics, value, path, attribute)
    return ok ? data : :__unsupported__
end

function _capture_namedtuple_data!(diagnostics, value::NamedTuple, path, attribute)
    names = sort(collect(keys(value)); by = String)
    captured = Pair{Symbol,Any}[]
    ok = true
    for name in names
        item = _capture_value!(diagnostics, value[name], path, attribute)
        if item === :__unsupported__
            ok = false
        else
            push!(captured, name => item)
        end
    end
    ok || return (;), false
    return (; (first(p) => last(p) for p in captured)...), true
end

function _capture_dict!(diagnostics, value, path, attribute)
    entries = Pair{Any,Any}[]
    ok = true
    for (key, item) in value
        if !(key isa Symbol || key isa AbstractString)
            push!(diagnostics, error_diagnostic(
                :unsupported_portable_value,
                "dict key of type $(typeof(key)) at $path is not portable";
                node = path,
                attribute = attribute,
                julia_type = string(typeof(key)),
            ))
            ok = false
            continue
        end
        captured_key = key isa Symbol ? key : String(key)
        captured_item = _capture_value!(diagnostics, item, path, attribute)
        if captured_item === :__unsupported__
            ok = false
        else
            push!(entries, captured_key => captured_item)
        end
    end
    ok || return :__unsupported__
    sort!(entries; by = pair -> string(first(pair)))
    return entries
end

function _capture_node!(diagnostics, node::SemanticNode, path::AbstractString)
    attrs = Pair{Symbol,Any}[]
    for (key, value) in node.attributes
        captured = _capture_value!(diagnostics, value, path, key)
        captured === :__unsupported__ && continue
        push!(attrs, key => captured)
    end
    children = PortableNode[]
    for (i, child) in enumerate(node.children)
        push!(children, _capture_node!(diagnostics, child, _child_path(path, child, i)))
    end
    return PortableNode(node.kind, node.name, attrs, children)
end

function _portable_roots(roots)
    collected = SemanticNode[]
    if roots isa SemanticNode
        push!(collected, roots)
    else
        for root in roots
            root isa SemanticNode || throw(ArgumentError(
                "portable document fragments must be SemanticNode values",
            ))
            push!(collected, root)
        end
    end
    return collected
end

function _capture_fragments(roots)
    diagnostics = DiagnosticMessage[]
    fragments = PortableNode[]
    for (i, root) in enumerate(_portable_roots(roots))
        push!(fragments, _capture_node!(diagnostics, root, _node_path(root, i)))
    end
    return fragments, diagnostics
end

"""
    validate_portable(roots) -> ValidationReport

Check whether live `SemanticNode` roots are in the portable universe.
Unsupported values produce `:unsupported_portable_value` diagnostics with
node/attribute location. Does not mutate the live tree.
"""
function validate_portable(roots)
    fragments, diagnostics = _capture_fragments(roots)
    return ValidationReport(
        :portable_document,
        isempty(diagnostics),
        diagnostics,
        (; fragments = length(fragments)),
    )
end

function _throw_portable(diagnostics)
    first = diagnostics[1]
    throw(ArgumentError(first.message))
end

"""
    capture_portable(id, roots; schema=episteme_document_schema(), metadata=(;))
        -> PortableSemanticDocument

Fail-closed capture of live trees into a portable document. Throws if any
leaf is outside the portable universe and has no registered codec.
"""
function capture_portable(
    id::DocumentId,
    roots;
    schema::SchemaRef = episteme_document_schema(),
    metadata::NamedTuple = (;),
)
    fragments, diagnostics = _capture_fragments(roots)
    isempty(diagnostics) || _throw_portable(diagnostics)
    return PortableSemanticDocument(id, fragments; schema = schema, metadata = metadata)
end

function validate(doc::PortableSemanticDocument)
    diagnostics = DiagnosticMessage[]
    schema_kind(doc.schema) === EPISTEME_DOCUMENT_KIND || push!(diagnostics, error_diagnostic(
        :schema_kind_mismatch,
        "document schema kind must be $EPISTEME_DOCUMENT_KIND";
        document_id = doc.id.value,
        schema_kind = schema_kind(doc.schema),
    ))
    seen = String[]
    for (i, fragment) in enumerate(doc.fragments)
        name = fragment.name === nothing ? "#$i" : String(fragment.name)
        if name in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_fragment_name,
                "duplicate fragment name $name";
                document_id = doc.id.value,
                name = name,
            ))
        else
            push!(seen, name)
        end
    end
    return ValidationReport(
        EPISTEME_DOCUMENT_KIND,
        isempty(diagnostics),
        diagnostics,
        (; document_id = doc.id.value, fragments = length(doc.fragments)),
    )
end

function report(doc::PortableSemanticDocument)
    return ObjectReport(
        EPISTEME_DOCUMENT_KIND,
        "Portable document $(doc.id.value) with $(length(doc.fragments)) fragments.",
        (;
            document_id = doc.id.value,
            schema = schema_kind(doc.schema),
            fragments = length(doc.fragments),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function _restore_value(value; decode::Bool)
    value isa PortableEncoded || return value
    decode || return value
    restored = portable_decode(value.kind, value.data)
    return restored
end

function restore_semantic(node::PortableNode; decode::Bool = false)
    attrs = Pair{Symbol,Any}[]
    for (key, value) in node.attributes
        push!(attrs, key => _restore_value(value; decode = decode))
    end
    children = SemanticNode[restore_semantic(child; decode = decode) for child in node.children]
    return SemanticNode(node.kind, node.name, attrs, children)
end

function restore_semantic(doc::PortableSemanticDocument; decode::Bool = false)
    return [restore_semantic(fragment; decode = decode) for fragment in doc.fragments]
end

function from_namedtuple(::Type{PortableSemanticDocument}, nt::NamedTuple)
    fragments = PortableNode[_portable_node_from_namedtuple(frag) for frag in nt.fragments]
    schema_nt = nt.schema
    schema = SchemaRef(schema_nt.namespace_id, schema_nt.schema_id, schema_nt.version)
    metadata = haskey(nt, :metadata) ? nt.metadata : (;)
    return PortableSemanticDocument(
        DocumentId(nt.id),
        fragments;
        schema = schema,
        metadata = metadata,
    )
end

function _portable_node_from_namedtuple(nt)
    nt isa NamedTuple || throw(ArgumentError("portable node must be a NamedTuple"))
    attrs = Pair{Symbol,Any}[]
    for item in nt.attributes
        push!(attrs, item.name => _value_from_namedtuple(item.value))
    end
    children = PortableNode[_portable_node_from_namedtuple(child) for child in nt.children]
    name = nt.name === nothing ? nothing : Symbol(nt.name)
    return PortableNode(Symbol(nt.kind), name, attrs, children)
end

function _value_from_namedtuple(nt::NamedTuple)
    kind = nt.portable_kind
    kind === :bool && return nt.value
    kind === :integer && return Int(nt.value)
    kind === :real && return Float64(nt.value)
    kind === :string && return String(nt.value)
    kind === :symbol && return Symbol(nt.value)
    kind === :nothing && return nothing
    kind === :noderef && return NodeRef(Symbol(nt.target))
    kind === :encoded && return PortableEncoded(Symbol(nt.kind), nt.data)
    kind === :tuple && return Tuple(_value_from_namedtuple(item) for item in nt.items)
    kind === :namedtuple && return (; (Symbol(item.name) => _value_from_namedtuple(item.value) for item in nt.items)...)
    kind === :dict && return Pair{Any,Any}[
        _dict_key_from_namedtuple(item.key) => _value_from_namedtuple(item.value) for item in nt.items
    ]
    kind === :array && return reshape(
        [_value_from_namedtuple(item) for item in nt.data],
        Tuple(Int(dim) for dim in nt.size),
    )
    throw(ArgumentError("unknown portable kind :$kind"))
end

_value_from_namedtuple(value) = throw(ArgumentError(
    "portable namedtuple values must be tagged NamedTuples, got $(typeof(value))",
))

function _dict_key_from_namedtuple(key)
    key isa NamedTuple || return key
    key.portable_kind === :symbol && return Symbol(key.value)
    key.portable_kind === :string && return String(key.value)
    throw(ArgumentError("unsupported portable dict key"))
end

function _portable_value_namedtuple(value)
    value isa Bool && return (portable_kind = :bool, value = value)
    value isa Integer && !(value isa Bool) && return (portable_kind = :integer, value = Int(value))
    value isa Float64 && return (portable_kind = :real, value = value)
    value isa AbstractString && return (portable_kind = :string, value = String(value))
    value isa Symbol && return (portable_kind = :symbol, value = String(value))
    value === nothing && return (portable_kind = :nothing, value = nothing)
    value isa NodeRef && return (portable_kind = :noderef, target = String(value.target))
    value isa PortableEncoded && return (portable_kind = :encoded, kind = String(value.kind), data = value.data)
    if value isa Tuple
        return (portable_kind = :tuple, items = Tuple(_portable_value_namedtuple.(value)))
    end
    if value isa NamedTuple
        names = sort(collect(keys(value)); by = String)
        items = Tuple((name = name, value = _portable_value_namedtuple(value[name])) for name in names)
        return (portable_kind = :namedtuple, items = items)
    end
    if value isa Vector{<:Pair}
        items = Tuple(
            (key = _portable_value_namedtuple(first(entry)), value = _portable_value_namedtuple(last(entry)))
            for entry in value
        )
        return (portable_kind = :dict, items = items)
    end
    if value isa AbstractArray
        return (
            portable_kind = :array,
            size = Tuple(size(value)),
            data = Tuple(_portable_value_namedtuple(item) for item in vec(value)),
        )
    end
    throw(ArgumentError("value of type $(typeof(value)) is not a captured portable value"))
end

to_namedtuple(encoded::PortableEncoded) = (kind = encoded.kind, data = encoded.data)

to_namedtuple(node::PortableNode) = (
    kind = node.kind,
    name = node.name === nothing ? nothing : String(node.name),
    attributes = Tuple((name = first(attr), value = _portable_value_namedtuple(last(attr))) for attr in node.attributes),
    children = Tuple(to_namedtuple.(node.children)),
)

to_namedtuple(doc::PortableSemanticDocument) = (
    id = doc.id.value,
    schema = to_namedtuple(doc.schema),
    fragments = Tuple(to_namedtuple.(doc.fragments)),
    metadata = doc.metadata,
)

function _sexpr_atom(value)
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    value isa Float64 && return string(value)
    value isa AbstractString && return repr(String(value))
    value isa Symbol && return String(value)
    value === nothing && return "nothing"
    value isa NodeRef && return "(ref $(value.target))"
    value isa PortableEncoded && return "(encoded $(value.kind) $(_sexpr_namedtuple(value.data)))"
    if value isa Tuple
        return "(" * join(_sexpr_atom.(value), " ") * ")"
    end
    if value isa NamedTuple
        return _sexpr_namedtuple(value)
    end
    if value isa Vector{<:Pair}
        inner = join(["($(_sexpr_atom(first(entry))) $(_sexpr_atom(last(entry))))" for entry in value], " ")
        return "(dict $inner)"
    end
    if value isa AbstractArray
        dims = join(string.(size(value)), " ")
        data = join(_sexpr_atom.(vec(value)), " ")
        return "(array $dims $data)"
    end
    return repr(value)
end

function _sexpr_namedtuple(value::NamedTuple)
    names = sort(collect(keys(value)); by = String)
    inner = join(["($(name) $(_sexpr_atom(value[name])))" for name in names], " ")
    return "($inner)"
end

function portable_sexpr(node::PortableNode; indent = 0)
    pad = repeat(" ", indent)
    head = node.name === nothing ? "($(node.kind)" : "($(node.kind) $(node.name)"
    lines = String[pad * head]
    for (key, value) in node.attributes
        push!(lines, pad * "  ($key $(_sexpr_atom(value)))")
    end
    for child in node.children
        push!(lines, portable_sexpr(child; indent = indent + 2))
    end
    if length(lines) == 1
        return lines[1] * ")"
    end
    return join(lines, "\n") * "\n" * pad * ")"
end

function portable_sexpr(doc::PortableSemanticDocument)
    lines = String[
        "(episteme/document $(repr(doc.id.value))",
        "  (schema $(schema_kind(doc.schema)) $(repr(doc.schema.version)))",
    ]
    for fragment in doc.fragments
        push!(lines, portable_sexpr(fragment; indent = 2))
    end
    return join(lines, "\n") * "\n)"
end
