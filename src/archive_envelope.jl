# ---------------------------------------------------------------------------
# Shared scientific-archive envelope
#
# Logical identities, references, and schema-version rules. No HDF5, no
# package payload store, and no software-environment or execution-context
# capture. Those remain later issues, domain packages, and AH5.jl.
# ---------------------------------------------------------------------------

"""
    AbstractArchiveId

Supertype for archive identity values. Distinct subtypes keep object,
revision, content, workflow-head, document, plan, activity, and agent
identities from being interchangeable.
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

"""
    DocumentId(value)

Identity of an authored semantic document object. This is not a workflow
[`RevisionId`](@ref), not a [`ContentId`](@ref), and not a compiled
[`PlanId`](@ref).
"""
struct DocumentId <: AbstractArchiveId
    value::String
    DocumentId(value::AbstractString) = new(_archive_id_value("DocumentId", value))
end

"""
    PlanId(value)

Identity of a resolved, executable plan. Distinct from the source
[`DocumentId`](@ref) and from a later [`RunId`](@ref).
"""
struct PlanId <: AbstractArchiveId
    value::String
    PlanId(value::AbstractString) = new(_archive_id_value("PlanId", value))
end

"""
    ActivityId(value)

Identity of one operation instance inside a run. This is bookkeeping, not
an idempotency key; domain packages own `idempotency_key` separately.
"""
struct ActivityId <: AbstractArchiveId
    value::String
    ActivityId(value::AbstractString) = new(_archive_id_value("ActivityId", value))
end

"""
    AgentId(value)

Identity of a human, software, or LLM actor when provenance needs
attribution. This is not authentication or authorization.
"""
struct AgentId <: AbstractArchiveId
    value::String
    AgentId(value::AbstractString) = new(_archive_id_value("AgentId", value))
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

`id` is the current short name (`:oodi`, `:lieb`, `:episteme`). Identity is
`package_uuid` when that string is non-empty; otherwise `id` is identity.
`display_name` is a human label such as `"Oodi.jl"` and is never identity,
so a repository or display-name rename does not mint a new namespace.
Reservation, alias, and ownership rules are documented in
`docs/archive-namespaces.md` (issue #38).
"""
struct ArchiveNamespace
    id::Symbol
    package_uuid::String
    display_name::String

    function ArchiveNamespace(
        id::Symbol,
        package_uuid::AbstractString,
        display_name::AbstractString,
    )
        isempty(String(id)) && throw(ArgumentError("namespace id must not be empty"))
        return new(id, String(strip(package_uuid)), String(strip(display_name)))
    end
end

function ArchiveNamespace(
    id::Symbol;
    package_uuid::AbstractString = "",
    display_name::AbstractString = "",
)
    return ArchiveNamespace(id, package_uuid, display_name)
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

include("archive_history.jl")

"""
    ArchiveGraph(objects; heads=(), revisions=(), runs=(), events=(), writes=(),
                 log_streams=())

A logical collection of envelope objects, workflow heads, and dual-history
records. Snapshot history lives in `revisions`; activity history lives in
`runs` (activities) and `events`. Logical write transactions live in
`writes`. Optional raw log streams live in `log_streams`. There is no
parallel session type.

Object order in `objects` is insertion order and is not semantically
authoritative. Use [`ordered_objects`](@ref) for a deterministic walk
independent of HDF5 group traversal. Object membership of a revision is
[`find_objects`](@ref); [`RevisionRecord`](@ref) does not store that list.
"""
struct ArchiveGraph
    objects::Vector{ArchiveObject}
    heads::Vector{WorkflowHead}
    revisions::Vector{RevisionRecord}
    runs::Vector{RunRecord}
    events::Vector{EventRecord}
    writes::Vector{WriteTransaction}
    log_streams::Vector{LogStreamRecord}
end

function ArchiveGraph(
    objects;
    heads = WorkflowHead[],
    revisions = RevisionRecord[],
    runs = RunRecord[],
    events = EventRecord[],
    writes = WriteTransaction[],
    log_streams = LogStreamRecord[],
)
    return ArchiveGraph(
        _typed_vector(ArchiveObject, objects, "graph objects"),
        _typed_vector(WorkflowHead, heads, "graph heads"),
        _typed_vector(RevisionRecord, revisions, "graph revisions"),
        _typed_vector(RunRecord, runs, "graph runs"),
        _typed_vector(EventRecord, events, "graph events"),
        _typed_vector(WriteTransaction, writes, "graph writes"),
        _typed_vector(LogStreamRecord, log_streams, "graph log streams"),
    )
end

"""
    ArchiveCatalog(; schemas=(), software_environments=(), execution_contexts=())

Known schema and provenance identities used to validate references.

This is not the embedded schema registry (#39) and not a software
manifest (#37). It only answers whether a referenced schema or provenance
id is known and how that schema may be read. The embedded definitions are
[`SchemaRegistry`](@ref).
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

ordered_revisions(graph::ArchiveGraph) =
    sort(graph.revisions; by = rev -> rev.id.value)

ordered_runs(graph::ArchiveGraph) = sort(graph.runs; by = run -> run.id.value)

ordered_events(graph::ArchiveGraph) = graph.events

ordered_writes(graph::ArchiveGraph) = sort(graph.writes; by = _write_sort_key)

_write_sort_key(tx::WriteTransaction) = (
    String(tx.scope),
    tx.run_id === nothing ? "" : tx.run_id.value,
    tx.sequence,
)

"""
    ordered_run_events(graph, run_id) -> Vector{EventRecord}

Events for `run_id`, ordered by source then source-local sequence.
Events without a sequence sort last. Wall-clock timestamps are ignored.
"""
function ordered_run_events(graph::ArchiveGraph, run_id::RunId)
    matches = EventRecord[]
    for event in graph.events
        event.run_id == run_id && push!(matches, event)
    end
    return _events_in_timeline_order(matches)
end

ordered_log_streams(graph::ArchiveGraph) =
    sort(graph.log_streams; by = _log_stream_sort_key)

_log_stream_sort_key(stream::LogStreamRecord) = (
    stream.run_id.value,
    String(stream.kind),
    stream.source === nothing ? "" : stream.source,
)

function _events_in_timeline_order(events::Vector{EventRecord})
    n = length(events)
    n < 2 && return copy(events)
    idxs = collect(1:n)
    sort!(idxs; by = i -> (
        events[i].run_id.value,
        events[i].source === nothing ? "" : events[i].source,
        events[i].sequence === nothing ? typemax(Int) : events[i].sequence,
        i,
    ))
    return events[idxs]
end

"""
    event_timeline(graph; run_id=nothing) -> Vector{NamedTuple}

Generic inspection rows: time, scope, severity, kind, message, and
run/activity/revision/object/source/sequence references. No domain
payload is loaded. Sequence is the causal order; timestamp is metadata.
"""
function event_timeline(graph::ArchiveGraph; run_id = nothing)
    rid = _optional_id(RunId, run_id)
    rows = NamedTuple[]
    events = EventRecord[]
    for event in graph.events
        rid === nothing || event.run_id == rid || continue
        push!(events, event)
    end
    for event in _events_in_timeline_order(events)
        push!(rows, (
            timestamp = event.timestamp,
            scope = event.scope,
            severity = event.severity,
            kind = event.kind,
            message = event.message,
            run_id = event.run_id.value,
            activity_id = event.activity_id === nothing ? nothing : event.activity_id.value,
            revision_id = event.revision_id === nothing ? nothing : event.revision_id.value,
            object_ids = Tuple(ref.object_id.value for ref in event.object_refs),
            source = event.source,
            sequence = event.sequence,
            retention = event.retention,
        ))
    end
    return rows
end

function find_revision(graph::ArchiveGraph, revision_id::RevisionId)
    for rev in graph.revisions
        rev.id == revision_id && return rev
    end
    return nothing
end

function find_run(graph::ArchiveGraph, run_id::RunId)
    for run in graph.runs
        run.id == run_id && return run
    end
    return nothing
end

"""
    find_write(graph; scope, run_id=nothing) -> Union{WriteTransaction,Nothing}

The write transaction for `scope` and optional `run_id`, if present.
"""
function find_write(graph::ArchiveGraph; scope::Symbol, run_id = nothing)
    rid = _optional_id(RunId, run_id)
    for tx in graph.writes
        tx.scope === scope || continue
        tx.run_id == rid && return tx
    end
    return nothing
end

function _unique_parents(rev::RevisionRecord)
    parents = RevisionId[]
    seen = String[]
    for parent in rev.parents
        parent.value in seen && continue
        push!(seen, parent.value)
        push!(parents, parent)
    end
    return parents
end

function _revision_children_map(graph::ArchiveGraph)
    children = Dict{String,Vector{RevisionRecord}}()
    for rev in graph.revisions
        children[rev.id.value] = RevisionRecord[]
    end
    for rev in graph.revisions
        for parent in _unique_parents(rev)
            list = get(children, parent.value, nothing)
            list === nothing && continue
            push!(list, rev)
        end
    end
    return children
end

"""
    revision_parents(graph, revision_id) -> Vector{RevisionRecord}

Direct parents of `revision_id` that exist in the graph, in record order.
Missing parent ids are omitted; `validate` reports them as `:dangling_parent`.
"""
function revision_parents(graph::ArchiveGraph, revision_id::RevisionId)
    rec = find_revision(graph, revision_id)
    rec === nothing && return RevisionRecord[]
    parents = RevisionRecord[]
    for parent_id in _unique_parents(rec)
        parent = find_revision(graph, parent_id)
        parent === nothing || push!(parents, parent)
    end
    return parents
end

"""
    revision_children(graph, revision_id) -> Vector{RevisionRecord}

Direct children: revisions that list `revision_id` as a parent.
"""
function revision_children(graph::ArchiveGraph, revision_id::RevisionId)
    children = RevisionRecord[]
    for rev in ordered_revisions(graph)
        any(parent -> parent == revision_id, rev.parents) || continue
        push!(children, rev)
    end
    return children
end

"""
    revision_ancestors(graph, revision_id) -> Vector{RevisionRecord}

All proper ancestors, excluding `revision_id`. Order is stable by
[`RevisionId`](@ref) value. Does not load payloads or open files.
"""
function revision_ancestors(graph::ArchiveGraph, revision_id::RevisionId)
    rec = find_revision(graph, revision_id)
    rec === nothing && return RevisionRecord[]
    seen = Set{String}([revision_id.value])
    stack = RevisionId[_unique_parents(rec)...]
    found = Dict{String,RevisionRecord}()
    while !isempty(stack)
        parent_id = pop!(stack)
        parent_id.value in seen && continue
        push!(seen, parent_id.value)
        parent = find_revision(graph, parent_id)
        parent === nothing && continue
        found[parent.id.value] = parent
        append!(stack, _unique_parents(parent))
    end
    return sort!(collect(values(found)); by = rev -> rev.id.value)
end

"""
    revision_descendants(graph, revision_id) -> Vector{RevisionRecord}

All proper descendants, excluding `revision_id`. Order is stable by
[`RevisionId`](@ref) value. Does not load payloads or open files.
"""
function revision_descendants(graph::ArchiveGraph, revision_id::RevisionId)
    find_revision(graph, revision_id) === nothing && return RevisionRecord[]
    children = _revision_children_map(graph)
    seen = Set{String}([revision_id.value])
    stack = copy(get(children, revision_id.value, RevisionRecord[]))
    found = Dict{String,RevisionRecord}()
    while !isempty(stack)
        child = pop!(stack)
        child.id.value in seen && continue
        push!(seen, child.id.value)
        found[child.id.value] = child
        append!(stack, get(children, child.id.value, RevisionRecord[]))
    end
    return sort!(collect(values(found)); by = rev -> rev.id.value)
end

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
    _validate_object_namespace!(diagnostics, object)
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

function _validate_archive_graph!(diagnostics, graph::ArchiveGraph; namespace_registry = nothing)
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
    seen_head_names = Symbol[]
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
        if head.name in seen_head_names
            push!(diagnostics, error_diagnostic(
                :duplicate_workflow_head_name,
                "duplicate workflow head name :$(head.name)";
                head_id = head.id.value,
                name = head.name,
            ))
        else
            push!(seen_head_names, head.name)
        end
        _head_revision_resolves(graph, head.revision_id) && continue
        push!(diagnostics, error_diagnostic(
            :dangling_workflow_head,
            "workflow head :$(head.name) points at missing revision $(head.revision_id.value)";
            head_id = head.id.value,
            name = head.name,
            revision_id = head.revision_id.value,
        ))
    end

    _validate_history_records!(diagnostics, graph)
    _validate_namespace_identities!(
        diagnostics,
        graph.objects;
        registry = namespace_registry,
    )
    return diagnostics
end

function _validate_revision_parent_dag!(diagnostics, graph::ArchiveGraph)
    indeg = Dict{String,Int}()
    children = Dict{String,Vector{String}}()
    for rev in graph.revisions
        indeg[rev.id.value] = 0
        children[rev.id.value] = String[]
    end
    for rev in graph.revisions
        for parent_id in _unique_parents(rev)
            if find_revision(graph, parent_id) === nothing
                push!(diagnostics, error_diagnostic(
                    :dangling_parent,
                    "revision $(rev.id.value) names unknown parent $(parent_id.value)";
                    revision_id = rev.id.value,
                    parent_id = parent_id.value,
                ))
                continue
            end
            indeg[rev.id.value] += 1
            push!(children[parent_id.value], rev.id.value)
        end
    end
    n = length(indeg)
    n == 0 && return diagnostics

    queue = String[]
    for (id, deg) in indeg
        deg == 0 && push!(queue, id)
    end
    processed = 0
    while !isempty(queue)
        id = pop!(queue)
        processed += 1
        for child in children[id]
            indeg[child] -= 1
            indeg[child] == 0 && push!(queue, child)
        end
    end
    processed >= n && return diagnostics

    for (id, deg) in indeg
        deg == 0 && continue
        push!(diagnostics, error_diagnostic(
            :cycle,
            "revision parent graph contains a cycle including $(id)";
            revision_id = id,
        ))
        break
    end
    return diagnostics
end

function _plan_ids_conflict(run::RunRecord, rec::RevisionRecord)
    return run.plan_id !== nothing && rec.plan_id !== nothing && run.plan_id != rec.plan_id
end

function _head_revision_resolves(graph::ArchiveGraph, revision_id::RevisionId)
    if !isempty(graph.revisions)
        return find_revision(graph, revision_id) !== nothing
    end
    return any(object -> object.revision_id == revision_id, graph.objects)
end

function _validate_history_records!(diagnostics, graph::ArchiveGraph)
    seen_revisions = String[]
    for rev in graph.revisions
        if rev.id.value in seen_revisions
            push!(diagnostics, error_diagnostic(
                :duplicate_revision,
                "duplicate revision $(rev.id.value)";
                revision_id = rev.id.value,
            ))
        else
            push!(seen_revisions, rev.id.value)
        end
    end

    _validate_revision_parent_dag!(diagnostics, graph)

    if !isempty(graph.revisions)
        for object in graph.objects
            find_revision(graph, object.revision_id) === nothing || continue
            push!(diagnostics, error_diagnostic(
                :missing_revision_record,
                "object $(object.object_id.value) names unknown revision $(object.revision_id.value)";
                object_id = object.object_id.value,
                revision_id = object.revision_id.value,
            ))
        end
    end

    seen_runs = String[]
    seen_activities = String[]
    for run in graph.runs
        if run.id.value in seen_runs
            push!(diagnostics, error_diagnostic(
                :duplicate_run,
                "duplicate run $(run.id.value)";
                run_id = run.id.value,
            ))
        else
            push!(seen_runs, run.id.value)
        end

        if run.parent_run_id !== nothing
            if run.parent_run_id == run.id
                push!(diagnostics, error_diagnostic(
                    :self_parent_run,
                    "run $(run.id.value) lists itself as parent_run_id";
                    run_id = run.id.value,
                ))
            elseif find_run(graph, run.parent_run_id) === nothing
                push!(diagnostics, error_diagnostic(
                    :missing_parent_run,
                    "run $(run.id.value) names unknown parent run $(run.parent_run_id.value)";
                    run_id = run.id.value,
                    parent_run_id = run.parent_run_id.value,
                ))
            end
        end

        if run.revision_id !== nothing
            rec = find_revision(graph, run.revision_id)
            if rec === nothing
                if !isempty(graph.revisions)
                    push!(diagnostics, error_diagnostic(
                        :missing_run_revision,
                        "run $(run.id.value) names unknown revision $(run.revision_id.value)";
                        run_id = run.id.value,
                        revision_id = run.revision_id.value,
                    ))
                end
            elseif rec.run_id !== nothing && rec.run_id != run.id
                push!(diagnostics, error_diagnostic(
                    :run_revision_mismatch,
                    "run $(run.id.value) points at revision $(rec.id.value) produced by $(rec.run_id.value)";
                    run_id = run.id.value,
                    revision_id = rec.id.value,
                    producing_run_id = rec.run_id.value,
                ))
            elseif _plan_ids_conflict(run, rec)
                push!(diagnostics, error_diagnostic(
                    :run_revision_plan_mismatch,
                    "run $(run.id.value) plan $(run.plan_id.value) does not match revision $(rec.id.value) plan $(rec.plan_id.value)";
                    run_id = run.id.value,
                    revision_id = rec.id.value,
                    run_plan_id = run.plan_id.value,
                    revision_plan_id = rec.plan_id.value,
                ))
            end
        end

        for activity in run.activities
            if activity.id.value in seen_activities
                push!(diagnostics, error_diagnostic(
                    :duplicate_activity,
                    "duplicate activity $(activity.id.value)";
                    activity_id = activity.id.value,
                ))
            else
                push!(seen_activities, activity.id.value)
            end
            activity.run_id == run.id && continue
            push!(diagnostics, error_diagnostic(
                :activity_run_mismatch,
                "activity $(activity.id.value) belongs to run $(activity.run_id.value), not $(run.id.value)";
                activity_id = activity.id.value,
                run_id = activity.run_id.value,
                expected_run_id = run.id.value,
            ))
        end
    end

    for rev in graph.revisions
        rev.run_id === nothing && continue
        run = find_run(graph, rev.run_id)
        if run === nothing
            push!(diagnostics, error_diagnostic(
                :missing_revision_run,
                "revision $(rev.id.value) names unknown run $(rev.run_id.value)";
                revision_id = rev.id.value,
                run_id = rev.run_id.value,
            ))
        elseif run.revision_id !== nothing && run.revision_id != rev.id
            push!(diagnostics, error_diagnostic(
                :run_revision_mismatch,
                "revision $(rev.id.value) names run $(run.id.value) which commits $(run.revision_id.value)";
                revision_id = rev.id.value,
                run_id = run.id.value,
                run_revision_id = run.revision_id.value,
            ))
        elseif _plan_ids_conflict(run, rev)
            push!(diagnostics, error_diagnostic(
                :run_revision_plan_mismatch,
                "revision $(rev.id.value) plan $(rev.plan_id.value) does not match run $(run.id.value) plan $(run.plan_id.value)";
                revision_id = rev.id.value,
                run_id = run.id.value,
                run_plan_id = run.plan_id.value,
                revision_plan_id = rev.plan_id.value,
            ))
        end
    end

    _validate_event_timeline!(diagnostics, graph)
    _validate_log_streams!(diagnostics, graph)
    _validate_run_lifecycle!(diagnostics, graph)
    _validate_write_transactions!(diagnostics, graph)
    return diagnostics
end

function _validate_event_timeline!(diagnostics, graph::ArchiveGraph)
    for event in graph.events
        _validate_event_record!(diagnostics, event)
        run = find_run(graph, event.run_id)
        if run === nothing
            push!(diagnostics, error_diagnostic(
                :missing_event_run,
                "event :$(event.kind) names unknown run $(event.run_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
            ))
        elseif event.activity_id !== nothing &&
                !any(activity -> activity.id == event.activity_id, run.activities)
            push!(diagnostics, error_diagnostic(
                :missing_event_activity,
                "event :$(event.kind) names unknown activity $(event.activity_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
                activity_id = event.activity_id.value,
            ))
        end
        if event.revision_id !== nothing && !isempty(graph.revisions) &&
                find_revision(graph, event.revision_id) === nothing
            push!(diagnostics, error_diagnostic(
                :missing_event_revision,
                "event :$(event.kind) names unknown revision $(event.revision_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
                revision_id = event.revision_id.value,
            ))
        end
        for ref in event.object_refs
            _reference_resolves(graph, ref) && continue
            push!(diagnostics, error_diagnostic(
                :dangling_event_object,
                "event :$(event.kind) names unknown object $(ref.object_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
                object_id = ref.object_id.value,
                target_revision_id = ref.revision_id === nothing ? nothing :
                    ref.revision_id.value,
            ))
        end
    end
    _validate_event_sequences!(diagnostics, graph)
    return diagnostics
end

function _validate_log_streams!(diagnostics, graph::ArchiveGraph)
    for stream in graph.log_streams
        _credential_like_diagnostics!(
            diagnostics,
            stream.summary,
            (; kind = stream.kind, run_id = stream.run_id.value, field = :summary),
        )
        run = find_run(graph, stream.run_id)
        if run === nothing
            push!(diagnostics, error_diagnostic(
                :missing_log_stream_run,
                "log stream :$(stream.kind) names unknown run $(stream.run_id.value)";
                kind = stream.kind,
                run_id = stream.run_id.value,
            ))
            continue
        end
        stream.activity_id === nothing && continue
        any(activity -> activity.id == stream.activity_id, run.activities) && continue
        push!(diagnostics, error_diagnostic(
            :missing_log_stream_activity,
            "log stream :$(stream.kind) names unknown activity $(stream.activity_id.value)";
            kind = stream.kind,
            run_id = stream.run_id.value,
            activity_id = stream.activity_id.value,
        ))
    end
    return diagnostics
end

function _validate_event_sequences!(diagnostics, graph::ArchiveGraph)
    return _validate_event_sequence_uniqueness!(diagnostics, graph.events)
end

function _validate_run_lifecycle!(diagnostics, graph::ArchiveGraph)
    for run in graph.runs
        _validate_run_record!(diagnostics, run)
        if run.revision_id === nothing
            for rev in graph.revisions
                rev.run_id == run.id || continue
                push!(diagnostics, error_diagnostic(
                    :uncommitted_run_has_revision,
                    "revision $(rev.id.value) names uncommitted run $(run.id.value)";
                    run_id = run.id.value,
                    revision_id = rev.id.value,
                    status = run.status,
                ))
            end
        end
        _validate_run_staging!(diagnostics, graph, run)
    end
    return diagnostics
end

function _validate_run_staging!(diagnostics, graph::ArchiveGraph, run::RunRecord)
    for staged in run.staged
        _validate_staged_against_graph!(diagnostics, graph, run, staged)
    end
    return diagnostics
end

function _validate_staged_against_graph!(diagnostics, graph, run::RunRecord, staged::StagedObject)
    if staged.origin === :reused
        source_rev = staged.source_revision_id
        if source_rev === nothing
            return diagnostics
        end
        source = find_object(graph, staged.object_id, source_rev)
        if source === nothing
            push!(diagnostics, error_diagnostic(
                :reused_source_missing,
                "reused object $(staged.object_id.value) has no source at $(source_rev.value)";
                run_id = run.id.value,
                object_id = staged.object_id.value,
                source_revision_id = source_rev.value,
            ))
        elseif source.content_id !== nothing && staged.content_id === nothing
            push!(diagnostics, error_diagnostic(
                :reused_content_missing,
                "reused object $(staged.object_id.value) dropped source content $(source.content_id.value)";
                run_id = run.id.value,
                object_id = staged.object_id.value,
                source_content_id = source.content_id.value,
            ))
        elseif staged.content_id !== nothing && source.content_id !== nothing &&
                staged.content_id != source.content_id
            push!(diagnostics, error_diagnostic(
                :reused_content_mismatch,
                "reused object $(staged.object_id.value) content does not match source";
                run_id = run.id.value,
                object_id = staged.object_id.value,
                content_id = staged.content_id.value,
                source_content_id = source.content_id.value,
            ))
        end
    end

    run.revision_id === nothing && return diagnostics
    promoted = find_object(graph, staged.object_id, run.revision_id)
    if promoted === nothing
        push!(diagnostics, error_diagnostic(
            :staged_not_promoted,
            "committed run $(run.id.value) did not promote staged object $(staged.object_id.value)";
            run_id = run.id.value,
            object_id = staged.object_id.value,
            revision_id = run.revision_id.value,
        ))
    elseif staged.content_id !== nothing && promoted.content_id !== nothing &&
            staged.content_id != promoted.content_id
        push!(diagnostics, error_diagnostic(
            :committed_content_mismatch,
            "promoted object $(staged.object_id.value) content does not match staging";
            run_id = run.id.value,
            object_id = staged.object_id.value,
            revision_id = run.revision_id.value,
            staged_content_id = staged.content_id.value,
            object_content_id = promoted.content_id.value,
        ))
    end
    return diagnostics
end

function _validate_write_transactions!(diagnostics, graph::ArchiveGraph)
    seen = Tuple{Symbol,String}[]
    in_flight_archive = WriteTransaction[]
    for tx in graph.writes
        _validate_write_transaction!(diagnostics, tx)
        key_run = tx.run_id === nothing ? "" : tx.run_id.value
        key = (tx.scope, key_run)
        if key in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_write,
                "$(tx.scope) write for $(key_run) is recorded more than once";
                scope = tx.scope,
                run_id = tx.run_id === nothing ? nothing : tx.run_id.value,
                sequence = tx.sequence,
            ))
        else
            push!(seen, key)
        end

        if tx.run_id !== nothing && find_run(graph, tx.run_id) === nothing
            push!(diagnostics, error_diagnostic(
                :missing_write_run,
                "$(tx.scope) write sequence $(tx.sequence) names unknown run $(tx.run_id.value)";
                scope = tx.scope,
                sequence = tx.sequence,
                run_id = tx.run_id.value,
            ))
        end

        if tx.scope === :archive && tx.phase in IN_FLIGHT_WRITE_PHASES
            push!(in_flight_archive, tx)
        end

        tx.run_id === nothing && continue
        run = find_run(graph, tx.run_id)
        run === nothing && continue
        _validate_write_against_run!(diagnostics, tx, run)
    end
    if length(in_flight_archive) > 1
        push!(diagnostics, error_diagnostic(
            :multiple_archive_writers,
            "v1 JLD2 path allows one in-flight archive writer; found $(length(in_flight_archive))";
            writers = length(in_flight_archive),
        ))
    end
    return diagnostics
end

function _validate_write_against_run!(diagnostics, tx::WriteTransaction, run::RunRecord)
    if tx.phase in IN_FLIGHT_WRITE_PHASES && run.revision_id !== nothing
        push!(diagnostics, error_diagnostic(
            :in_flight_write_has_revision,
            "run $(run.id.value) has an in-flight write and must not name a revision";
            run_id = run.id.value,
            phase = tx.phase,
            revision_id = run.revision_id.value,
        ))
    end
    if tx.phase === :committed && run.revision_id === nothing
        push!(diagnostics, error_diagnostic(
            :committed_write_missing_revision,
            "run $(run.id.value) write is :committed but names no revision";
            run_id = run.id.value,
            sequence = tx.sequence,
        ))
    end
    if tx.phase === :uncertain
        if run.revision_id !== nothing
            push!(diagnostics, error_diagnostic(
                :uncertain_write_has_revision,
                "run $(run.id.value) write is :uncertain and must not name a revision";
                run_id = run.id.value,
                revision_id = run.revision_id.value,
            ))
        end
        if run.status !== :uncertain
            push!(diagnostics, error_diagnostic(
                :uncertain_write_status_mismatch,
                "run $(run.id.value) write is :uncertain but status is :$(run.status)";
                run_id = run.id.value,
                status = run.status,
                phase = tx.phase,
            ))
        end
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
            revisions = length(graph.revisions),
            runs = length(graph.runs),
            events = length(graph.events),
            writes = length(graph.writes),
            log_streams = length(graph.log_streams),
            namespaces = Tuple(unique(obj.namespace.id for obj in ordered_objects(graph))),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function readiness(graph::ArchiveGraph, target::PipelineTarget)
    if target.name === :commit
        return _graph_commit_readiness(graph, target)
    elseif target.name === :restart
        return _graph_restart_readiness(graph, target)
    end
    return ReadinessReport(
        :archive_graph,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "archive graph readiness target :$(target.name) is not :commit or :restart";
            target = target.name,
        )],
        (; runs = length(graph.runs)),
    )
end

function _run_from_target(graph::ArchiveGraph, target::PipelineTarget)
    raw = get(target.options, :run_id, nothing)
    raw === nothing && return nothing
    run_id = raw isa RunId ? raw : RunId(string(raw))
    return find_run(graph, run_id)
end

function _graph_commit_readiness(graph::ArchiveGraph, target::PipelineTarget)
    run = _run_from_target(graph, target)
    if run === nothing
        return ReadinessReport(
            :archive_graph,
            target,
            false,
            [error_diagnostic(
                :missing_commit_run,
                "commit readiness requires a known run_id option",
            )],
            (;),
        )
    end
    local_report = readiness(run, PipelineTarget(:commit))
    diagnostics = DiagnosticMessage[local_report.diagnostics...]
    _validate_run_record!(diagnostics, run)
    _validate_run_staging!(diagnostics, graph, run)
    for write in graph.writes
        _write_blocks_commit(write, run) || continue
        if write.phase in IN_FLIGHT_WRITE_PHASES
            push!(diagnostics, error_diagnostic(
                :in_flight_write,
                _in_flight_commit_message(write, run);
                run_id = run.id.value,
                scope = write.scope,
                phase = write.phase,
                writer_run_id = write.run_id === nothing ? nothing : write.run_id.value,
            ))
        elseif write.phase === :uncertain
            push!(diagnostics, error_diagnostic(
                :uncertain_side_effect,
                "archive write is :uncertain; commit is fail-closed";
                run_id = run.id.value,
                scope = write.scope,
                writer_run_id = write.run_id === nothing ? nothing : write.run_id.value,
            ))
        end
    end
    return ReadinessReport(
        :archive_graph,
        target,
        isempty(diagnostics),
        diagnostics,
        (; run_id = run.id.value, status = run.status, staged = length(run.staged)),
    )
end

function _write_blocks_commit(write::WriteTransaction, run::RunRecord)
    if write.scope === :archive
        return write.phase in IN_FLIGHT_WRITE_PHASES || write.phase === :uncertain
    end
    write.scope === :run || return false
    write.run_id == run.id || return false
    return write.phase in IN_FLIGHT_WRITE_PHASES || write.phase === :uncertain
end

function _in_flight_commit_message(write::WriteTransaction, run::RunRecord)
    if write.scope === :archive && write.run_id != run.id
        return "archive has an in-flight :$(write.phase) writer; v1 is single-writer"
    end
    return "run $(run.id.value) still has an in-flight :$(write.phase) write"
end

function _graph_restart_readiness(graph::ArchiveGraph, target::PipelineTarget)
    run = _run_from_target(graph, target)
    if run === nothing
        return ReadinessReport(
            :archive_graph,
            target,
            false,
            [error_diagnostic(
                :missing_restart_run,
                "restart readiness requires a known run_id option",
            )],
            (;),
        )
    end
    local_report = readiness(run, PipelineTarget(:restart))
    diagnostics = DiagnosticMessage[local_report.diagnostics...]
    req = run.restart
    if req !== nothing
        parent = run.parent_run_id === nothing ? nothing : find_run(graph, run.parent_run_id)
        for checkpoint in req.checkpoints
            _append_checkpoint_diagnostics!(diagnostics, graph, run, parent, checkpoint)
        end
        if req.execution_context !== nothing
            if run.execution_context === nothing
                push!(diagnostics, error_diagnostic(
                    :missing_restart_execution_context,
                    "run $(run.id.value) restart needs execution context $(req.execution_context.value)";
                    run_id = run.id.value,
                    execution_context = req.execution_context.value,
                ))
            elseif run.execution_context != req.execution_context
                push!(diagnostics, error_diagnostic(
                    :incompatible_restart_execution_context,
                    "run $(run.id.value) execution context does not match restart requirement";
                    run_id = run.id.value,
                    execution_context = run.execution_context.value,
                    required = req.execution_context.value,
                ))
            end
        end
    end
    return ReadinessReport(
        :archive_graph,
        target,
        isempty(diagnostics),
        diagnostics,
        (;
            run_id = run.id.value,
            status = run.status,
            checkpoints = req === nothing ? 0 : length(req.checkpoints),
        ),
    )
end

function _append_checkpoint_diagnostics!(diagnostics, graph, run, parent, checkpoint::CheckpointRef)
    candidates = _checkpoint_candidates(graph, run, parent, checkpoint)
    if isempty(candidates)
        push!(diagnostics, error_diagnostic(
            :missing_restart_checkpoint,
            "restart checkpoint $(checkpoint.object_id.value) is not in the archive";
            run_id = run.id.value,
            object_id = checkpoint.object_id.value,
            content_id = checkpoint.content_id === nothing ? nothing :
                checkpoint.content_id.value,
            revision_id = checkpoint.revision_id === nothing ? nothing :
                checkpoint.revision_id.value,
            kind = checkpoint.kind,
        ))
        return diagnostics
    end
    checkpoint.content_id === nothing && return diagnostics
    for found in candidates
        found_content = _checkpoint_content(found)
        found_content == checkpoint.content_id && return diagnostics
    end
    for found in candidates
        _checkpoint_content(found) === nothing || continue
        push!(diagnostics, error_diagnostic(
            :unverified_restart_content,
            "restart checkpoint $(checkpoint.object_id.value) is present but has no content id to verify";
            run_id = run.id.value,
            object_id = checkpoint.object_id.value,
            required_content_id = checkpoint.content_id.value,
            kind = checkpoint.kind,
        ))
        return diagnostics
    end
    found_content = _checkpoint_content(candidates[1])
    push!(diagnostics, error_diagnostic(
        :incompatible_restart_content,
        "restart checkpoint $(checkpoint.object_id.value) content does not match";
        run_id = run.id.value,
        object_id = checkpoint.object_id.value,
        required_content_id = checkpoint.content_id.value,
        found_content_id = found_content === nothing ? nothing : found_content.value,
    ))
    return diagnostics
end

function _checkpoint_content(found)
    found isa ArchiveObject && return found.content_id
    found isa StagedObject && return found.content_id
    return nothing
end

function _checkpoint_candidates(graph, run, parent, checkpoint::CheckpointRef)
    candidates = Union{ArchiveObject,StagedObject}[]
    if checkpoint.revision_id !== nothing
        object = find_object(graph, checkpoint.object_id, checkpoint.revision_id)
        object === nothing || push!(candidates, object)
        return candidates
    end
    append!(candidates, find_revisions(graph, checkpoint.object_id))
    for staged in run.staged
        staged.object_id == checkpoint.object_id && push!(candidates, staged)
    end
    parent === nothing && return candidates
    for staged in parent.staged
        staged.object_id == checkpoint.object_id && push!(candidates, staged)
    end
    return candidates
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
        revisions = Tuple(to_namedtuple.(ordered_revisions(graph))),
        runs = Tuple(to_namedtuple.(ordered_runs(graph))),
        events = Tuple(to_namedtuple.(ordered_events(graph))),
        writes = Tuple(to_namedtuple.(ordered_writes(graph))),
        log_streams = Tuple(to_namedtuple.(ordered_log_streams(graph))),
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
        ", revisions=",
        length(graph.revisions),
        ", runs=",
        length(graph.runs),
        ", events=",
        length(graph.events),
        ", writes=",
        length(graph.writes),
        ", log_streams=",
        length(graph.log_streams),
        ")",
    )
end
