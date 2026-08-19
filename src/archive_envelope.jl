# ---------------------------------------------------------------------------
# Shared scientific-archive envelope
#
# Logical identities, references, and schema-version rules. No HDF5, no
# package payload store, and no software-environment or execution-context
# capture. Those remain later issues, domain packages, and AH5.jl.
# ---------------------------------------------------------------------------

"""
    AbstractArchiveId

Supertype for archive identity values. Distinct subtypes keep logical object
identity, revision identity, content identity, and workflow-head identity
from being interchangeable.
"""
abstract type AbstractArchiveId end

function _archive_id_value(name::AbstractString, value::AbstractString)
    stripped = String(strip(value))
    isempty(stripped) && throw(ArgumentError("$name value must not be empty"))
    return stripped
end

"""
    ObjectId(value)

Stable logical identity of an archived scientific object, unique across
the whole archive. Namespace is not part of the id; `ObjectRef` therefore
does not carry a namespace.

Prefer an opaque value such as a UUID. Display names are not identity.
Two workflow revisions of the same object share one `ObjectId`. This is
not a content hash and not a workflow head.
"""
struct ObjectId <: AbstractArchiveId
    value::String
    ObjectId(value::AbstractString) = new(_archive_id_value("ObjectId", value))
end

"""
    RevisionId(value)

Immutable identity of one global workflow revision. A single revision may
materialize several [`ArchiveObject`](@ref)s. Ordinary writes never reuse
a `RevisionId`. Parent/input revision edges belong to issue #30; they are
not stored on the object envelope.
"""
struct RevisionId <: AbstractArchiveId
    value::String
    RevisionId(value::AbstractString) = new(_archive_id_value("RevisionId", value))
end

"""
    ContentId(value)

Identity of logical content, independent of HDF5 placement, chunking, or
compression. The canonical hash rules live in issue #42; this type only
holds the resulting identifier.
"""
struct ContentId <: AbstractArchiveId
    value::String
    ContentId(value::AbstractString) = new(_archive_id_value("ContentId", value))
end

"""
    RunId(value)

Stable identity of a scientific run that may produce several revisions.
"""
struct RunId <: AbstractArchiveId
    value::String
    RunId(value::AbstractString) = new(_archive_id_value("RunId", value))
end

"""
    WorkflowHeadId(value)

Identity of a mutable workflow bookmark. The head id stays put when the
bookmark is moved to another [`RevisionId`](@ref).
"""
struct WorkflowHeadId <: AbstractArchiveId
    value::String
    WorkflowHeadId(value::AbstractString) = new(_archive_id_value("WorkflowHeadId", value))
end

"""
    SoftwareEnvironmentId(value)

Reference to an immutable software-environment object owned by issue #37.
Episteme does not store the manifest here.
"""
struct SoftwareEnvironmentId <: AbstractArchiveId
    value::String
    function SoftwareEnvironmentId(value::AbstractString)
        return new(_archive_id_value("SoftwareEnvironmentId", value))
    end
end

"""
    ExecutionContextId(value)

Reference to a sanitized execution-context fingerprint owned by issue #43.
Episteme does not capture hardware or RNG state here.
"""
struct ExecutionContextId <: AbstractArchiveId
    value::String
    function ExecutionContextId(value::AbstractString)
        return new(_archive_id_value("ExecutionContextId", value))
    end
end

Base.string(id::AbstractArchiveId) = id.value
Base.isless(a::T, b::T) where {T<:AbstractArchiveId} = isless(a.value, b.value)

function Base.show(io::IO, id::AbstractArchiveId)
    print(io, nameof(typeof(id)), "(", repr(id.value), ")")
end

# ---------------------------------------------------------------------------
# Namespace, schema, provenance
# ---------------------------------------------------------------------------

"""
    ArchiveNamespace(id; package_uuid="", display_name="")

Owning package namespace for archived objects and schemas.

`id` is the stable short name (`:oodi`, `:lieb`). `package_uuid` is the
Julia package UUID when known, otherwise the empty string. `display_name`
is a human label such as `"Oodi.jl"`. Reserved shared namespace names are
issue #38; this type only records identity.
"""
struct ArchiveNamespace
    id::Symbol
    package_uuid::String
    display_name::String
end

function ArchiveNamespace(
    id::Symbol;
    package_uuid::AbstractString = "",
    display_name::AbstractString = "",
)
    return ArchiveNamespace(id, String(package_uuid), String(display_name))
end

"""
    SchemaRef(namespace_id, schema_id, version)

Exact payload-schema identity. Package release version is not a substitute.

`schema_id` is the package-local schema name (`"field"`, `"mesh"`). Combined
with `namespace_id` it yields [`schema_kind`](@ref), e.g. `oodi/field`.
`version` is an opaque schema version string; compatibility is never
inferred from it.
"""
struct SchemaRef
    namespace_id::Symbol
    schema_id::String
    version::String

    function SchemaRef(
        namespace_id::Symbol,
        schema_id::AbstractString,
        version::AbstractString,
    )
        sid = String(strip(schema_id))
        ver = String(strip(version))
        isempty(sid) && throw(ArgumentError("schema_id must not be empty"))
        isempty(ver) && throw(ArgumentError("schema version must not be empty"))
        return new(namespace_id, sid, ver)
    end
end

"""
    schema_kind(schema::SchemaRef)
    schema_kind(namespace_id, schema_id)

Package-qualified kind, e.g. `Symbol("oodi/field")`.
"""
schema_kind(namespace_id::Symbol, schema_id::AbstractString) =
    Symbol(String(namespace_id), "/", schema_id)
schema_kind(schema::SchemaRef) = schema_kind(schema.namespace_id, schema.schema_id)

const SCHEMA_COMPATIBILITY = (
    :exact_read,
    :backwards_compatible,
    :migration_required,
    :unsupported,
)

"""
    KnownSchema(schema, compatibility)

Catalog entry stating how a concrete [`SchemaRef`](@ref) can be used.

`compatibility` is one of `:exact_read`, `:backwards_compatible`,
`:migration_required`, or `:unsupported`. It is declared data, not inferred
from package or schema version numbers.
"""
struct KnownSchema
    schema::SchemaRef
    compatibility::Symbol
    function KnownSchema(schema::SchemaRef, compatibility::Symbol)
        compatibility in SCHEMA_COMPATIBILITY || throw(ArgumentError(
            "unknown schema compatibility :$compatibility (expected one of $SCHEMA_COMPATIBILITY)",
        ))
        return new(schema, compatibility)
    end
end

"""
    ProvenanceRefs(; software_environment=nothing, execution_context=nothing)

Minimal provenance *references* carried by an archive object.

The producing workflow revision is [`ArchiveObject.revision_id`](@ref),
not a second field here. Full software manifests (#37), execution
fingerprints (#43), and the revision DAG (#30) are separate contracts.
`nothing` means explicitly not recorded.
"""
struct ProvenanceRefs
    software_environment::Union{Nothing,SoftwareEnvironmentId}
    execution_context::Union{Nothing,ExecutionContextId}
end

function ProvenanceRefs(;
    software_environment = nothing,
    execution_context = nothing,
)
    return ProvenanceRefs(
        _optional_id(SoftwareEnvironmentId, software_environment),
        _optional_id(ExecutionContextId, execution_context),
    )
end

function _optional_id(::Type{T}, value) where {T}
    value === nothing && return nothing
    value isa T && return value
    throw(ArgumentError("expected $T or nothing, got $(typeof(value))"))
end

# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------

"""
    ObjectRef(object_id, revision_id=nothing)

Cross-object reference by archive-global [`ObjectId`](@ref), not by HDF5
path and not by namespace.

An unpinned reference (`revision_id === nothing`) is a logical-object
link: it resolves if any version of that object exists. Exact scientific
dependencies must pin a [`RevisionId`](@ref) or use issue #30's revision
inputs. A pinned reference stays valid when unrelated objects are
appended.
"""
struct ObjectRef
    object_id::ObjectId
    revision_id::Union{Nothing,RevisionId}
end

ObjectRef(object_id::ObjectId) = ObjectRef(object_id, nothing)

"""
    ArchiveReference(name, target)

A named outgoing reference from one archive object to another.

`name` is the role on the source object (`:mesh`, `:geometry`). Target
payload meaning stays with the owning package.
"""
struct ArchiveReference
    name::Symbol
    target::ObjectRef
end

function ArchiveReference(
    name::Symbol,
    object_id::ObjectId;
    revision_id::Union{Nothing,RevisionId} = nothing,
)
    return ArchiveReference(name, ObjectRef(object_id, revision_id))
end

# ---------------------------------------------------------------------------
# Canonical logical-value conventions
# ---------------------------------------------------------------------------

const LOGICAL_SCALAR_KINDS = (
    :bool,
    :integer,
    :real,
    :complex,
    :string,
    :symbol,
    :enum,
)

"""
    LogicalType(kind; units="", frame="", enum_values=())

Portable scalar convention shared by more than one domain.

`kind` is one of [`LOGICAL_SCALAR_KINDS`](@ref). `units` and `frame` are
opaque strings so Episteme does not depend on a units or geometry package.
`enum_values` is required when `kind === :enum`.
"""
struct LogicalType
    kind::Symbol
    units::String
    frame::String
    enum_values::Tuple{Vararg{Symbol}}
end

function LogicalType(
    kind::Symbol;
    units::AbstractString = "",
    frame::AbstractString = "",
    enum_values = (),
)
    kind in LOGICAL_SCALAR_KINDS || throw(ArgumentError(
        "unknown logical scalar kind :$kind (expected one of $LOGICAL_SCALAR_KINDS)",
    ))
    values = _symbol_tuple(enum_values, "enum_values")
    kind === :enum && isempty(values) &&
        throw(ArgumentError("enum logical types require non-empty enum_values"))
    kind !== :enum && !isempty(values) &&
        throw(ArgumentError("enum_values are only valid for kind = :enum"))
    return LogicalType(kind, String(units), String(frame), values)
end

function _symbol_tuple(values, what::AbstractString)
    result = Symbol[]
    for value in values
        value isa Symbol || throw(ArgumentError("$what must contain Symbol values"))
        push!(result, value)
    end
    return Tuple(result)
end

"""
    LogicalArraySpec(name, element, rank; shape=())

Logical array contract independent of HDF5 layout.

`shape` is empty when extents are unknown. Otherwise it has `rank` entries,
each an `Int` or `nothing` for a runtime-determined dimension. Chunking and
compression are not represented here.
"""
struct LogicalArraySpec
    name::Symbol
    element::LogicalType
    rank::Int
    shape::Tuple{Vararg{Union{Nothing,Int}}}
end

function LogicalArraySpec(
    name::Symbol,
    element::LogicalType,
    rank::Integer;
    shape = (),
)
    rank < 0 && throw(ArgumentError("array rank must be non-negative"))
    dims = _shape_tuple(shape)
    !isempty(dims) && length(dims) != Int(rank) && throw(ArgumentError(
        "shape length $(length(dims)) does not match rank $rank",
    ))
    return LogicalArraySpec(name, element, Int(rank), dims)
end

function _shape_tuple(shape)
    dims = Union{Nothing,Int}[]
    for dim in shape
        if dim === nothing
            push!(dims, nothing)
        elseif dim isa Integer
            Int(dim) < 0 && throw(ArgumentError("array shape entries must be non-negative"))
            push!(dims, Int(dim))
        else
            throw(ArgumentError("array shape entries must be integers or nothing"))
        end
    end
    return Tuple(dims)
end

# ---------------------------------------------------------------------------
# Envelope objects and graphs
# ---------------------------------------------------------------------------

"""
    ArchiveObject(object_id, revision_id; namespace, kind, schema, kwargs...)

Minimal shared archive envelope. It identifies an object version; it does
not store the scientific payload.

# Required
- `object_id` — archive-global logical object identity
- `revision_id` — workflow revision that materialized this version
- `namespace` — owning package namespace
- `kind` — package-qualified kind, e.g. `Symbol("oodi/field")`
- `schema` — exact payload schema id and version

# Optional
- `content_id` — logical content identity (#42 supplies hash rules)
- `run_id` — producing run
- `provenance` — software/execution references
- `references` — named [`ArchiveReference`](@ref)s

Package-owned typed models remain authoritative. AH5 later calls
package-owned codecs; do not flatten payload arrays into this wrapper.
"""
struct ArchiveObject
    object_id::ObjectId
    revision_id::RevisionId
    content_id::Union{Nothing,ContentId}
    run_id::Union{Nothing,RunId}
    namespace::ArchiveNamespace
    kind::Symbol
    schema::SchemaRef
    provenance::ProvenanceRefs
    references::Vector{ArchiveReference}
end

function ArchiveObject(
    object_id::ObjectId,
    revision_id::RevisionId;
    content_id = nothing,
    run_id = nothing,
    namespace::ArchiveNamespace,
    kind::Symbol,
    schema::SchemaRef,
    provenance::ProvenanceRefs = ProvenanceRefs(),
    references = ArchiveReference[],
)
    return ArchiveObject(
        object_id,
        revision_id,
        _optional_id(ContentId, content_id),
        _optional_id(RunId, run_id),
        namespace,
        kind,
        schema,
        provenance,
        _archive_references(references),
    )
end

function _archive_references(references)
    refs = ArchiveReference[]
    for ref in references
        ref isa ArchiveReference ||
            throw(ArgumentError("references must be ArchiveReference values"))
        push!(refs, ref)
    end
    return refs
end

"""
    WorkflowHead(id, name, revision_id)

A movable bookmark pointing at a workflow [`RevisionId`](@ref).

Replacing `revision_id` does not change historical objects. The head
identifies a revision, not a single object snapshot; several objects may
have been materialized in that revision.
"""
struct WorkflowHead
    id::WorkflowHeadId
    name::Symbol
    revision_id::RevisionId
end

"""
    ArchiveGraph(objects; heads=())

A logical collection of envelope objects and workflow heads.

Object order in `objects` is insertion order and is not semantically
authoritative. Use [`ordered_objects`](@ref) for a deterministic walk
independent of HDF5 group traversal.
"""
struct ArchiveGraph
    objects::Vector{ArchiveObject}
    heads::Vector{WorkflowHead}
end

function ArchiveGraph(objects; heads = WorkflowHead[])
    object_values = ArchiveObject[]
    for object in objects
        object isa ArchiveObject ||
            throw(ArgumentError("graph objects must be ArchiveObject values"))
        push!(object_values, object)
    end
    head_values = WorkflowHead[]
    for head in heads
        head isa WorkflowHead ||
            throw(ArgumentError("graph heads must be WorkflowHead values"))
        push!(head_values, head)
    end
    return ArchiveGraph(object_values, head_values)
end

"""
    ArchiveCatalog(; schemas=(), software_environments=(), execution_contexts=())

Known schema and provenance identities used to validate references.

This is not the embedded schema registry (#39) and not a software
manifest (#37). It only answers whether a referenced schema or provenance
id is known and how that schema may be read.
"""
struct ArchiveCatalog
    schemas::Vector{KnownSchema}
    software_environments::Vector{SoftwareEnvironmentId}
    execution_contexts::Vector{ExecutionContextId}
end

function ArchiveCatalog(;
    schemas = KnownSchema[],
    software_environments = SoftwareEnvironmentId[],
    execution_contexts = ExecutionContextId[],
)
    return ArchiveCatalog(
        _typed_vector(KnownSchema, schemas, "schemas"),
        _typed_vector(SoftwareEnvironmentId, software_environments, "software_environments"),
        _typed_vector(ExecutionContextId, execution_contexts, "execution_contexts"),
    )
end

function _typed_vector(::Type{T}, values, what::AbstractString) where {T}
    result = T[]
    for value in values
        value isa T || throw(ArgumentError("$what must contain $T values"))
        push!(result, value)
    end
    return result
end

# ---------------------------------------------------------------------------
# Ordering and lookup
# ---------------------------------------------------------------------------

_object_sort_key(obj::ArchiveObject) = (
    String(obj.namespace.id),
    obj.object_id.value,
    obj.revision_id.value,
)

_reference_sort_key(ref::ArchiveReference) = (
    String(ref.name),
    ref.target.object_id.value,
    ref.target.revision_id === nothing ? "" : ref.target.revision_id.value,
)

_head_sort_key(head::WorkflowHead) = (head.id.value, String(head.name))

"""
    ordered_objects(graph) -> Vector{ArchiveObject}

Objects sorted by namespace, object id, then revision id.
"""
ordered_objects(graph::ArchiveGraph) = sort(graph.objects; by = _object_sort_key)

"""
    ordered_references(object) -> Vector{ArchiveReference}

Outgoing references sorted by name and target identity.
"""
ordered_references(object::ArchiveObject) =
    sort(object.references; by = _reference_sort_key)

"""
    ordered_heads(graph) -> Vector{WorkflowHead}

Workflow heads sorted by head id then name.
"""
ordered_heads(graph::ArchiveGraph) = sort(graph.heads; by = _head_sort_key)

"""
    find_revisions(graph, object_id) -> Vector{ArchiveObject}

Every snapshot of `object_id`, in logical order.
"""
function find_revisions(graph::ArchiveGraph, object_id::ObjectId)
    matches = ArchiveObject[]
    for object in graph.objects
        object.object_id == object_id && push!(matches, object)
    end
    return sort(matches; by = _object_sort_key)
end

"""
    find_object(graph, object_id, revision_id) -> Union{ArchiveObject,Nothing}
"""
function find_object(graph::ArchiveGraph, object_id::ObjectId, revision_id::RevisionId)
    for object in graph.objects
        if object.object_id == object_id && object.revision_id == revision_id
            return object
        end
    end
    return nothing
end

"""
    find_objects(graph, revision_id) -> Vector{ArchiveObject}

Every object materialized in the given workflow revision, in logical order.
"""
function find_objects(graph::ArchiveGraph, revision_id::RevisionId)
    matches = ArchiveObject[]
    for object in graph.objects
        object.revision_id == revision_id && push!(matches, object)
    end
    return sort(matches; by = _object_sort_key)
end

function _reference_resolves(graph::ArchiveGraph, target::ObjectRef)
    if target.revision_id === nothing
        return any(object -> object.object_id == target.object_id, graph.objects)
    end
    return find_object(graph, target.object_id, target.revision_id) !== nothing
end

"""
    resolve_schema(schema, catalog) -> Union{KnownSchema,Nothing}

Exact schema-id/version lookup. Version compatibility is never inferred.
"""
function resolve_schema(schema::SchemaRef, catalog::ArchiveCatalog)
    for known in catalog.schemas
        known.schema == schema && return known
    end
    return nothing
end

"""
    schema_status(schema, catalog) -> Symbol

`:exact_read`, `:backwards_compatible`, `:migration_required`,
`:unsupported`, or `:missing_schema`.
"""
function schema_status(schema::SchemaRef, catalog::ArchiveCatalog)
    known = resolve_schema(schema, catalog)
    known === nothing && return :missing_schema
    return known.compatibility
end

# ---------------------------------------------------------------------------
# Validation and reports
# ---------------------------------------------------------------------------

function _kind_prefix(namespace_id::Symbol)
    return String(namespace_id) * "/"
end

function _validate_archive_object!(diagnostics, object::ArchiveObject)
    prefix = _kind_prefix(object.namespace.id)
    startswith(String(object.kind), prefix) || push!(diagnostics, error_diagnostic(
        :kind_namespace_mismatch,
        "kind $(object.kind) is not owned by namespace :$(object.namespace.id)";
        object_id = object.object_id.value,
        kind = object.kind,
        namespace = object.namespace.id,
    ))

    object.schema.namespace_id == object.namespace.id || push!(
        diagnostics,
        error_diagnostic(
            :schema_namespace_mismatch,
            "schema namespace :$(object.schema.namespace_id) does not match object namespace :$(object.namespace.id)";
            object_id = object.object_id.value,
            schema_namespace = object.schema.namespace_id,
            namespace = object.namespace.id,
        ),
    )

    schema_kind(object.schema) == object.kind || push!(diagnostics, error_diagnostic(
        :schema_kind_mismatch,
        "schema $(schema_kind(object.schema)) does not match kind $(object.kind)";
        object_id = object.object_id.value,
        schema_kind = schema_kind(object.schema),
        kind = object.kind,
    ))

    seen = Symbol[]
    for ref in object.references
        if ref.name in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_reference_name,
                "duplicate reference name :$(ref.name)";
                object_id = object.object_id.value,
                name = ref.name,
            ))
        else
            push!(seen, ref.name)
        end
    end
    return diagnostics
end

function _validate_schema_catalog!(diagnostics, object::ArchiveObject, catalog::ArchiveCatalog)
    status = schema_status(object.schema, catalog)
    if status === :missing_schema
        push!(diagnostics, error_diagnostic(
            :missing_schema,
            "schema $(schema_kind(object.schema)) version $(object.schema.version) is not in the catalog";
            object_id = object.object_id.value,
            schema_kind = schema_kind(object.schema),
            version = object.schema.version,
        ))
    elseif status === :unsupported
        push!(diagnostics, error_diagnostic(
            :unsupported_schema,
            "schema $(schema_kind(object.schema)) version $(object.schema.version) is unsupported";
            object_id = object.object_id.value,
            schema_kind = schema_kind(object.schema),
            version = object.schema.version,
        ))
    elseif status === :migration_required
        push!(diagnostics, error_diagnostic(
            :migration_required,
            "schema $(schema_kind(object.schema)) version $(object.schema.version) requires an explicit migration";
            object_id = object.object_id.value,
            schema_kind = schema_kind(object.schema),
            version = object.schema.version,
        ))
    end

    env = object.provenance.software_environment
    if env !== nothing && !(env in catalog.software_environments)
        push!(diagnostics, error_diagnostic(
            :missing_software_environment,
            "software environment $(env.value) is not in the catalog";
            object_id = object.object_id.value,
            software_environment = env.value,
        ))
    end

    ctx = object.provenance.execution_context
    if ctx !== nothing && !(ctx in catalog.execution_contexts)
        push!(diagnostics, error_diagnostic(
            :missing_execution_context,
            "execution context $(ctx.value) is not in the catalog";
            object_id = object.object_id.value,
            execution_context = ctx.value,
        ))
    end
    return diagnostics
end

function validate(object::ArchiveObject)
    diagnostics = DiagnosticMessage[]
    _validate_archive_object!(diagnostics, object)
    return ValidationReport(
        object.kind,
        isempty(diagnostics),
        diagnostics,
        (;
            object_id = object.object_id.value,
            revision_id = object.revision_id.value,
        ),
    )
end

function validate(object::ArchiveObject, catalog::ArchiveCatalog)
    diagnostics = DiagnosticMessage[]
    _validate_archive_object!(diagnostics, object)
    _validate_schema_catalog!(diagnostics, object, catalog)
    return ValidationReport(
        object.kind,
        isempty(diagnostics),
        diagnostics,
        (;
            object_id = object.object_id.value,
            revision_id = object.revision_id.value,
            schema_status = schema_status(object.schema, catalog),
        ),
    )
end

function validate(graph::ArchiveGraph)
    diagnostics = DiagnosticMessage[]
    _validate_archive_graph!(diagnostics, graph)
    return ValidationReport(:archive_graph, isempty(diagnostics), diagnostics, (;))
end

function validate(graph::ArchiveGraph, catalog::ArchiveCatalog)
    diagnostics = DiagnosticMessage[]
    _validate_archive_graph!(diagnostics, graph)
    for object in ordered_objects(graph)
        _validate_schema_catalog!(diagnostics, object, catalog)
    end
    return ValidationReport(:archive_graph, isempty(diagnostics), diagnostics, (;))
end

function _validate_archive_graph!(diagnostics, graph::ArchiveGraph)
    seen_revisions = Tuple{String,String}[]
    seen_objects = Dict{String,Tuple{Symbol,Symbol}}()
    for object in ordered_objects(graph)
        _validate_archive_object!(diagnostics, object)
        key = (object.object_id.value, object.revision_id.value)
        if key in seen_revisions
            push!(diagnostics, error_diagnostic(
                :duplicate_object_revision,
                "duplicate object/revision $(object.object_id.value) @ $(object.revision_id.value)";
                object_id = object.object_id.value,
                revision_id = object.revision_id.value,
            ))
        else
            push!(seen_revisions, key)
        end

        previous = get(seen_objects, object.object_id.value, nothing)
        if previous === nothing
            seen_objects[object.object_id.value] = (object.namespace.id, object.kind)
        else
            prev_namespace, prev_kind = previous
            if prev_namespace != object.namespace.id
                push!(diagnostics, error_diagnostic(
                    :object_id_namespace_conflict,
                    "object id $(object.object_id.value) is used in both :$prev_namespace and :$(object.namespace.id)";
                    object_id = object.object_id.value,
                    namespace = object.namespace.id,
                    other_namespace = prev_namespace,
                ))
            elseif prev_kind != object.kind
                push!(diagnostics, error_diagnostic(
                    :object_id_kind_conflict,
                    "object id $(object.object_id.value) is used as both $prev_kind and $(object.kind)";
                    object_id = object.object_id.value,
                    kind = object.kind,
                    other_kind = prev_kind,
                ))
            end
        end

        for ref in ordered_references(object)
            _reference_resolves(graph, ref.target) && continue
            target_rev = ref.target.revision_id
            push!(diagnostics, error_diagnostic(
                :dangling_reference,
                "reference :$(ref.name) does not resolve";
                object_id = object.object_id.value,
                name = ref.name,
                target_object_id = ref.target.object_id.value,
                target_revision_id = target_rev === nothing ? nothing : target_rev.value,
            ))
        end
    end

    seen_heads = String[]
    for head in ordered_heads(graph)
        if head.id.value in seen_heads
            push!(diagnostics, error_diagnostic(
                :duplicate_workflow_head,
                "duplicate workflow head $(head.id.value)";
                head_id = head.id.value,
            ))
        else
            push!(seen_heads, head.id.value)
        end
        any(object -> object.revision_id == head.revision_id, graph.objects) && continue
        push!(diagnostics, error_diagnostic(
            :dangling_workflow_head,
            "workflow head :$(head.name) points at missing revision $(head.revision_id.value)";
            head_id = head.id.value,
            name = head.name,
            revision_id = head.revision_id.value,
        ))
    end
    return diagnostics
end

function report(object::ArchiveObject)
    return ObjectReport(
        object.kind,
        "Archive object $(object.kind) $(object.object_id.value) @ $(object.revision_id.value).",
        (;
            object_id = object.object_id.value,
            revision_id = object.revision_id.value,
            content_id = object.content_id === nothing ? nothing : object.content_id.value,
            namespace = object.namespace.id,
            schema = schema_kind(object.schema),
            schema_version = object.schema.version,
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(graph::ArchiveGraph)
    return ObjectReport(
        :archive_graph,
        "Archive graph with $(length(graph.objects)) objects and $(length(graph.heads)) heads.",
        (;
            objects = length(graph.objects),
            heads = length(graph.heads),
            namespaces = Tuple(unique(obj.namespace.id for obj in ordered_objects(graph))),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

# ---------------------------------------------------------------------------
# Serialization and display
# ---------------------------------------------------------------------------

to_namedtuple(id::AbstractArchiveId) = (kind = nameof(typeof(id)), value = id.value)

to_namedtuple(ns::ArchiveNamespace) = (
    id = ns.id,
    package_uuid = ns.package_uuid,
    display_name = ns.display_name,
)

to_namedtuple(schema::SchemaRef) = (
    namespace_id = schema.namespace_id,
    schema_id = schema.schema_id,
    version = schema.version,
    kind = schema_kind(schema),
)

to_namedtuple(known::KnownSchema) = (
    schema = to_namedtuple(known.schema),
    compatibility = known.compatibility,
)

to_namedtuple(prov::ProvenanceRefs) = (
    software_environment = prov.software_environment === nothing ? nothing :
        to_namedtuple(prov.software_environment),
    execution_context = prov.execution_context === nothing ? nothing :
        to_namedtuple(prov.execution_context),
)

to_namedtuple(ref::ObjectRef) = (
    object_id = ref.object_id.value,
    revision_id = ref.revision_id === nothing ? nothing : ref.revision_id.value,
)

to_namedtuple(ref::ArchiveReference) = (
    name = ref.name,
    target = to_namedtuple(ref.target),
)

to_namedtuple(t::LogicalType) = (
    kind = t.kind,
    units = t.units,
    frame = t.frame,
    enum_values = t.enum_values,
)

to_namedtuple(spec::LogicalArraySpec) = (
    name = spec.name,
    element = to_namedtuple(spec.element),
    rank = spec.rank,
    shape = spec.shape,
)

to_namedtuple(head::WorkflowHead) = (
    id = head.id.value,
    name = head.name,
    revision_id = head.revision_id.value,
)

function to_namedtuple(object::ArchiveObject)
    return (
        object_id = object.object_id.value,
        revision_id = object.revision_id.value,
        content_id = object.content_id === nothing ? nothing : object.content_id.value,
        run_id = object.run_id === nothing ? nothing : object.run_id.value,
        namespace = to_namedtuple(object.namespace),
        kind = object.kind,
        schema = to_namedtuple(object.schema),
        provenance = to_namedtuple(object.provenance),
        references = Tuple(to_namedtuple.(ordered_references(object))),
    )
end

function to_namedtuple(graph::ArchiveGraph)
    return (
        objects = Tuple(to_namedtuple.(ordered_objects(graph))),
        heads = Tuple(to_namedtuple.(ordered_heads(graph))),
    )
end

function to_namedtuple(catalog::ArchiveCatalog)
    return (
        schemas = Tuple(to_namedtuple.(catalog.schemas)),
        software_environments = Tuple(id.value for id in catalog.software_environments),
        execution_contexts = Tuple(id.value for id in catalog.execution_contexts),
    )
end

function Base.show(io::IO, object::ArchiveObject)
    print(
        io,
        "ArchiveObject(",
        object.kind,
        ", ",
        object.object_id.value,
        " @ ",
        object.revision_id.value,
        ")",
    )
end

function Base.show(io::IO, graph::ArchiveGraph)
    print(
        io,
        "ArchiveGraph(objects=",
        length(graph.objects),
        ", heads=",
        length(graph.heads),
        ")",
    )
end
