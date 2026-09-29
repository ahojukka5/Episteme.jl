# ---------------------------------------------------------------------------
# Canonical logical content hashing (#71 / parent #42)
+#
+# Content identity is defined from logical values, not Julia storage types,
+# JLD2/HDF5 paths, chunking, compression, or package release metadata.
+# ---------------------------------------------------------------------------

const CANONICAL_HASH_ALGORITHMS = (:sha256,)
const CANONICAL_CONTENT_VERSION = "episteme-canonical-v1"
const _CANONICAL_HEX = codeunits("0123456789abcdef")
const _CANONICAL_DIGEST_CHUNK = 4096
const _CANONICAL_BIT_INTEGERS = Union{
    Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
}

"""
    CanonicalHashPolicy(; algorithm=:sha256, version=CANONICAL_CONTENT_VERSION)

Versioned canonical-content policy. The policy version is part of the bytes
that are hashed, so future canonicalization changes cannot silently reuse old
content identities.
"""
struct CanonicalHashPolicy
    algorithm::Symbol
    version::String
end

function CanonicalHashPolicy(;
    algorithm::Symbol = :sha256,
    version::AbstractString = CANONICAL_CONTENT_VERSION,
)
    algorithm in CANONICAL_HASH_ALGORITHMS || throw(ArgumentError(
        "unsupported canonical hash algorithm :$algorithm",
    ))
    normalized = String(strip(version))
    isempty(normalized) && throw(ArgumentError("canonical-content version must not be empty"))
    return CanonicalHashPolicy(algorithm, normalized)
end

"""
    canonical_content(value)

Extension hook for domain packages. Return a portable, domain-neutral logical
projection of `value`; caches, physical paths, handles, and other incidental
representation details must be omitted.

Episteme provides projections for its shared schema and portable-document
records. Unsupported domain values fail closed until their owning package
extends this function.
"""
function canonical_content(value)
    throw(ArgumentError(
        "no canonical logical-content projection is registered for $(typeof(value))",
    ))
end

canonical_content(ref::NodeRef) = (; target = ref.target)
canonical_content(value::PortableEncoded) = (; kind = value.kind, data = value.data)
canonical_content(value::PortableDict) = (; entries = Tuple(value.entries))
canonical_content(value::PortableNode) = (
    kind = value.kind,
    name = value.name,
    attributes = Tuple(value.attributes),
    children = Tuple(value.children),
)
canonical_content(value::PortableSemanticDocument) = (
    schema = to_namedtuple(value.schema),
    fragments = Tuple(value.fragments),
    metadata = value.metadata,
)
canonical_content(value::SchemaRef) = to_namedtuple(value)

# package_version and namespace display_name are provenance/human labels, not
# semantic schema content. Keep the exact schema id/version, stable owner
# identity, logical fields/rules, compatibility, and migration relations.
function canonical_content(value::SchemaDefinition)
    nt = to_namedtuple(value)
    return (
        schema = nt.schema,
        namespace = (
            id = nt.namespace.id,
            package_uuid = nt.namespace.package_uuid,
        ),
        compatibility = nt.compatibility,
        fields = nt.fields,
        node_schema = nt.node_schema,
        documentation = nt.documentation,
        replaces = nt.replaces,
        replaced_by = nt.replaced_by,
        migration = nt.migration,
    )
end

"""
    canonical_bytes(value; policy=CanonicalHashPolicy()) -> Vector{UInt8}

Deterministic byte encoding of logical content. The encoding uses explicit
value tags and byte lengths and normalizes incidental Julia representation:
integer width, real storage width, dictionary insertion order, NamedTuple
field order, and array element type do not affect the resulting bytes.
"""
function canonical_bytes(value; policy::CanonicalHashPolicy = CanonicalHashPolicy())
    io = IOBuffer()
    _canonical_tag!(io, "episteme-canonical")
    _canonical_string!(io, policy.version)
    _canonical_write!(io, value, policy)
    return take!(io)
end

"""
    canonical_digest(value; policy=CanonicalHashPolicy()) -> Vector{UInt8}

Cryptographic digest of canonical logical content. The transcript is fed to
SHA-256 as it is written, and the digest matches `SHA.sha256` of
`canonical_bytes` for the same value and policy.
"""
function canonical_digest(value; policy::CanonicalHashPolicy = CanonicalHashPolicy())
    policy.algorithm === :sha256 || throw(ArgumentError(
        "unsupported canonical hash algorithm :$(policy.algorithm)",
    ))
    io = _CanonicalDigestIO()
    _canonical_tag!(io, "episteme-canonical")
    _canonical_string!(io, policy.version)
    _canonical_write!(io, value, policy)
    return _canonical_digest_finish!(io)
end

# Fixed scratch. Ordered values must not retain the canonical transcript.
mutable struct _CanonicalDigestIO <: IO
    ctx::SHA.SHA2_256_CTX
    buffer::Vector{UInt8}
    filled::Int
end

function _CanonicalDigestIO()
    return _CanonicalDigestIO(
        SHA.SHA2_256_CTX(),
        Vector{UInt8}(undef, _CANONICAL_DIGEST_CHUNK),
        0,
    )
end

function _canonical_digest_flush!(io::_CanonicalDigestIO)
    io.filled == 0 && return io
    SHA.update!(io.ctx, io.buffer, io.filled)
    io.filled = 0
    return io
end

function _canonical_digest_finish!(io::_CanonicalDigestIO)
    _canonical_digest_flush!(io)
    return collect(SHA.digest!(io.ctx))
end

function Base.write(io::_CanonicalDigestIO, byte::UInt8)
    if io.filled == length(io.buffer)
        _canonical_digest_flush!(io)
    end
    io.filled += 1
    @inbounds io.buffer[io.filled] = byte
    return 1
end

function Base.unsafe_write(io::_CanonicalDigestIO, src::Ptr{UInt8}, nb::UInt)
    remaining = Int(nb)
    offset = 0
    buf = io.buffer
    while remaining > 0
        space = length(buf) - io.filled
        if space == 0
            _canonical_digest_flush!(io)
            space = length(buf)
        end
        chunk = min(space, remaining)
        GC.@preserve buf unsafe_copyto!(
            pointer(buf, io.filled + 1), src + offset, chunk,
        )
        io.filled += chunk
        offset += chunk
        remaining -= chunk
    end
    return nb
end

"""
    canonical_content_id(value; policy=CanonicalHashPolicy()) -> ContentId

Strong logical content identity, encoded as `sha256:<lowercase hex>`.
"""
function canonical_content_id(value; policy::CanonicalHashPolicy = CanonicalHashPolicy())
    digest = canonical_digest(value; policy = policy)
    return ContentId(string(policy.algorithm, ":", bytes2hex(digest)))
end

function _canonical_tag!(io, tag::AbstractString)
    write(io, codeunits(tag))
    write(io, UInt8(';'))
    return io
end

function _canonical_udecimal_width(value::Unsigned)
    iszero(value) && return 1
    ten = oftype(value, 10)
    n = 0
    y = value
    while !iszero(y)
        n += 1
        y = div(y, ten)
    end
    return n
end

function _canonical_unsigned_magnitude(value::Signed)
    if value == typemin(typeof(value))
        return unsigned(typemin(typeof(value)))
    end
    return unsigned(-value)
end

function _canonical_decimal_width(value::Signed)
    if value < zero(value)
        return 1 + _canonical_udecimal_width(_canonical_unsigned_magnitude(value))
    end
    return _canonical_udecimal_width(unsigned(value))
end

_canonical_decimal_width(value::Unsigned) = _canonical_udecimal_width(value)

function _canonical_write_udecimal!(io, value::Unsigned)
    ten = oftype(value, 10)
    if iszero(value)
        write(io, UInt8('0'))
        return io
    end
    place = one(value)
    limit = div(typemax(typeof(value)), ten)
    while place <= limit
        next = place * ten
        next > value && break
        place = next
    end
    while true
        digit, value = divrem(value, place)
        write(io, UInt8(0x30 + digit))
        isone(place) && break
        place = div(place, ten)
    end
    return io
end

function _canonical_write_decimal!(io, value::Signed)
    if value < zero(value)
        write(io, UInt8('-'))
        _canonical_write_udecimal!(io, _canonical_unsigned_magnitude(value))
    else
        _canonical_write_udecimal!(io, unsigned(value))
    end
    return io
end

_canonical_write_decimal!(io, value::Unsigned) = _canonical_write_udecimal!(io, value)

function _canonical_bytestring!(io, bytes)
    _canonical_write_decimal!(io, length(bytes))
    write(io, UInt8(':'))
    write(io, bytes)
    return io
end

function _canonical_string!(io, value::AbstractString)
    bytes = codeunits(String(value))
    return _canonical_bytestring!(io, bytes)
end

function _canonical_write!(io, ::Nothing, policy)
    _canonical_tag!(io, "nothing")
    return io
end

function _canonical_write!(io, value::Bool, policy)
    _canonical_tag!(io, value ? "bool:1" : "bool:0")
    return io
end

function _canonical_write!(io, value::_CANONICAL_BIT_INTEGERS, policy)
    _canonical_tag!(io, "integer")
    _canonical_write_decimal!(io, _canonical_decimal_width(value))
    write(io, UInt8(':'))
    _canonical_write_decimal!(io, value)
    return io
end

function _canonical_write!(io, value::Integer, policy)
    _canonical_tag!(io, "integer")
    _canonical_string!(io, string(value))
    return io
end

function _canonical_write_hex16!(io, bits::UInt64)
    for shift in (60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0)
        write(io, _CANONICAL_HEX[Int((bits >> shift) & 0x0f) + 1])
    end
    return io
end

function _canonical_write!(io, value::Union{Float16,Float32,Float64}, policy)
    _canonical_tag!(io, "real64")
    x = Float64(value)
    if isnan(x)
        _canonical_string!(io, "nan")
    elseif isinf(x)
        _canonical_string!(io, signbit(x) ? "-inf" : "+inf")
    elseif x == 0.0
        _canonical_string!(io, "0")
    else
        _canonical_write_decimal!(io, 16)
        write(io, UInt8(':'))
        _canonical_write_hex16!(io, reinterpret(UInt64, x))
    end
    return io
end

function _canonical_write!(io, value::Complex, policy)
    _canonical_tag!(io, "complex")
    _canonical_write!(io, real(value), policy)
    _canonical_write!(io, imag(value), policy)
    return io
end

function _canonical_write!(io, value::AbstractString, policy)
    _canonical_tag!(io, "string")
    _canonical_string!(io, value)
    return io
end

function _canonical_write!(io, value::Symbol, policy)
    _canonical_tag!(io, "symbol")
    _canonical_string!(io, String(value))
    return io
end

function _canonical_write!(io, value::Pair, policy)
    _canonical_tag!(io, "pair")
    _canonical_write!(io, first(value), policy)
    _canonical_write!(io, last(value), policy)
    return io
end

function _canonical_write!(io, value::Tuple, policy)
    _canonical_tag!(io, "tuple")
    _canonical_write_decimal!(io, length(value))
    write(io, UInt8(';'))
    for item in value
        _canonical_write!(io, item, policy)
    end
    return io
end

function _canonical_write!(io, value::NamedTuple, policy)
    _canonical_tag!(io, "namedtuple")
    names = sort!(collect(keys(value)); by = String)
    _canonical_write_decimal!(io, length(names))
    write(io, UInt8(';'))
    for name in names
        _canonical_write!(io, name, policy)
        _canonical_write!(io, value[name], policy)
    end
    return io
end

function _canonical_write!(io, value::AbstractArray, policy)
    ndims(value) == 0 && throw(ArgumentError("zero-dimensional arrays are not canonical portable values"))
    _canonical_tag!(io, "array")
    _canonical_write_decimal!(io, ndims(value))
    write(io, UInt8(';'))
    for dim in size(value)
        _canonical_write!(io, Int(dim), policy)
    end
    _canonical_write_decimal!(io, length(value))
    write(io, UInt8(';'))
    for item in value
        _canonical_write!(io, item, policy)
    end
    return io
end

function _canonical_sort_key(value, policy)
    io = IOBuffer()
    _canonical_write!(io, value, policy)
    return bytes2hex(take!(io))
end

function _canonical_write!(io, value::AbstractDict, policy)
    _canonical_tag!(io, "dict")
    entries = collect(pairs(value))
    keyed = [(_canonical_sort_key(first(entry), policy), entry) for entry in entries]
    sort!(keyed; by = first)
    for i in 2:length(keyed)
        first(keyed[i - 1]) == first(keyed[i]) && throw(ArgumentError(
            "dictionary contains distinct keys with the same canonical logical identity",
        ))
    end
    _canonical_write_decimal!(io, length(keyed))
    write(io, UInt8(';'))
    for (_, entry) in keyed
        _canonical_write!(io, first(entry), policy)
        _canonical_write!(io, last(entry), policy)
    end
    return io
end

function _canonical_write!(io, value, policy)
    projected = canonical_content(value)
    projected === value && throw(ArgumentError(
        "canonical_content($(typeof(value))) returned the original unsupported value",
    ))
    return _canonical_write!(io, projected, policy)
end
