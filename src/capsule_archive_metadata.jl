# Select schema definitions from authoritative envelopes, including staged
# records in retained runs. A registry can contain unrelated schema versions.
function _capsule_schemas(graph::ArchiveGraph, schemas::SchemaRegistry)
    refs = Dict{Tuple{String,String,String},SchemaRef}()
    for object in graph.objects
        refs[_integrity_schema_key(object.schema)] = object.schema
    end
    for run in graph.runs, staged in run.staged
        refs[_integrity_schema_key(staged.schema)] = staged.schema
    end
    # One registry pass: first definition per key, plus the keys seen twice.
    by_key = Dict{Tuple{String,String,String},SchemaDefinition}()
    duplicated = Set{Tuple{String,String,String}}()
    for definition in schemas.entries
        key = _integrity_schema_key(definition.schema)
        haskey(by_key, key) ? push!(duplicated, key) : (by_key[key] = definition)
    end
    definitions = SchemaDefinition[]
    for key in sort!(collect(keys(refs)))
        haskey(by_key, key) && !(key in duplicated) || throw(ArgumentError(
            "capsule needs exactly one embedded definition for schema $(repr(key))",
        ))
        push!(definitions, by_key[key])
    end
    return SchemaRegistry(definitions)
end

function _capsule_retained_externals(graph::ArchiveGraph, plan::CapsulePlan, externals)
    state = _reachability(
        graph,
        [RetentionRoot(plan.source_revision)],
        plan.retention.policy,
        _externals_vector(externals),
    )
    any(d -> d.severity === :error, state.diagnostics) && throw(ArgumentError(
        "cannot select capsule externals from invalid retained metadata",
    ))
    values = sort!(copy(state.externals); by = _capsule_external_key)
    all(req -> _capsule_strong_content_id(req.content_id), values) || throw(ArgumentError(
        "retained capsule externals require strong content identities",
    ))
    return values
end

const AH5_CAPSULE_FEATURE = :capsule_manifest
const AH5_CAPSULE_KEY = "episteme/capsule"
const AH5_CAPSULE_PAYLOADS_KEY = "episteme/capsule_payloads"
const AH5_CAPSULE_DOCUMENTS_KEY = "episteme/capsule_documents"
const AH5_CAPSULE_NATIVE_KEY = "episteme/capsule_native"
const CAPSULE_CONTENT_KINDS = (
    :revision, :object, :schema, :provenance, :external, :payload, :document,
    :software_environment, :execution_context, :log, :debug, :runtime,
)
const CAPSULE_CONTENT_STATUSES = (:retained, :external, :unavailable, :redacted, :omitted)
const CAPSULE_REFUSED_RUNTIME_NAMES = (
    "os", "runtime", "container", "container_image", "os_image", "disk_image",
)
const CapsuleCounts = NamedTuple{
    (:retained_objects, :omitted_objects, :retained_revisions, :omitted_revisions,
     :retained_runs, :omitted_runs),
    NTuple{6,Int},
}

"""
    CapsuleContentEntry

One row in a capsule content manifest. `status` is `:retained`, `:external`,
`:unavailable`, `:redacted`, or `:omitted`. Empty identity fields mean the row
is not keyed by that identity.
"""
struct CapsuleContentEntry
    kind::Symbol
    status::Symbol
    object_id::String
    revision_id::String
    content_id::String
    label::String
    reason::Symbol
    encoding::String
end

function CapsuleContentEntry(
    kind::Symbol,
    status::Symbol;
    object_id::AbstractString = "",
    revision_id::AbstractString = "",
    content_id::AbstractString = "",
    label::AbstractString = "",
    reason::Symbol,
    encoding::AbstractString = "",
)
    kind in CAPSULE_CONTENT_KINDS || throw(ArgumentError(
        "capsule content kind must be one of $CAPSULE_CONTENT_KINDS, got :$kind",
    ))
    status in CAPSULE_CONTENT_STATUSES || throw(ArgumentError(
        "capsule content status must be one of $CAPSULE_CONTENT_STATUSES, got :$status",
    ))
    encoding in ("", "portable", "native") || throw(ArgumentError(
        "capsule payload encoding must be portable, native, or empty, got $(repr(encoding))",
    ))
    return CapsuleContentEntry(
        kind, status, String(object_id), String(revision_id), String(content_id),
        String(label), reason, String(encoding),
    )
end

"""Achieved capsule readiness. Rerun claims require replayable state."""
struct CapsuleReadiness
    inspectable::Bool
    replayable::Bool
    restartable::Bool
    rerunnable::Bool
    diagnostics::Vector{DiagnosticMessage}

    function CapsuleReadiness(
        inspectable::Bool,
        replayable::Bool,
        restartable::Bool,
        rerunnable::Bool,
        diagnostics = DiagnosticMessage[],
    )
        (replayable || restartable || rerunnable) && !inspectable && throw(ArgumentError(
            "capsule execution readiness requires inspectable metadata",
        ))
        rerunnable && !replayable && throw(ArgumentError(
            "rerunnable capsule requires replayable state",
        ))
        return new(
            inspectable, replayable, restartable, rerunnable,
            _typed_vector(DiagnosticMessage, diagnostics, "diagnostics"),
        )
    end
end

"""
    CapsuleManifest

Scope of one AH5 reproduction capsule. `target` is the plan request.
`readiness` is what the embedded content actually supports. Omitted counts
describe the source at materialization time. Format 1 is a legacy metadata-only
manifest; format 2 records the content disposition manifest.
"""
struct CapsuleManifest
    format_version::Int
    archive_id::String
    source_archive_id::String
    root_revisions::Vector{RevisionId}
    target::Symbol
    verification::Symbol
    counts::CapsuleCounts
    payloads_embedded::Bool
    content::Vector{CapsuleContentEntry}
    readiness::CapsuleReadiness
end

function _capsule_runtime_row(entries)
    for entry in entries
        entry.kind === :runtime || continue
        entry.status === :omitted || continue
        entry.reason === :runtime_not_packaged || continue
        return entry
    end
    return nothing
end

function _refuse_invalid_capsule_manifest(manifest::CapsuleManifest)
    manifest.format_version in (1, 2) || throw(ArgumentError(
        "unsupported capsule manifest version",
    ))
    isempty(strip(manifest.archive_id)) && throw(ArgumentError("capsule archive id is empty"))
    isempty(strip(manifest.source_archive_id)) && throw(ArgumentError("source archive id is empty"))
    strip(manifest.archive_id) != strip(manifest.source_archive_id) || throw(ArgumentError(
        "capsule archive id must differ from the source archive id",
    ))
    length(manifest.root_revisions) == 1 || throw(ArgumentError(
        "capsule v1 requires exactly one root revision",
    ))
    _capsule_target(manifest.target)
    _verification_level(manifest.verification)
    all(count -> count >= 0, manifest.counts) || throw(ArgumentError("negative capsule count"))
    embedded = any(entry -> entry.kind === :payload && entry.status === :retained, manifest.content)
    if manifest.format_version == 1
        manifest.payloads_embedded && throw(ArgumentError(
            "legacy capsule manifests do not embed scientific payload bytes",
        ))
        isempty(manifest.content) || throw(ArgumentError(
            "legacy capsule manifests do not carry a content disposition list",
        ))
        (manifest.readiness.replayable || manifest.readiness.restartable ||
            manifest.readiness.rerunnable) && throw(ArgumentError(
            "legacy capsule manifests cannot claim execution readiness",
        ))
    else
        manifest.payloads_embedded == embedded || throw(ArgumentError(
            "capsule payload flag does not match retained scientific state",
        ))
        _capsule_runtime_row(manifest.content) === nothing && throw(ArgumentError(
            "capsule manifest must record that no OS, runtime, or container image is packaged",
        ))
        any(entry -> entry.kind === :runtime && entry.status === :retained, manifest.content) &&
            throw(ArgumentError("capsule manifest claims a packaged runtime"))
    end
    return manifest
end

function _capsule_manifest(
    profile::ArchiveProfile,
    source_archive_id,
    plan::CapsulePlan,
    content::Vector{CapsuleContentEntry},
    readiness::CapsuleReadiness,
    payloads_embedded::Bool,
)
    counts = (
        retained_objects = plan.retention.retained_objects,
        omitted_objects = plan.retention.omitted_objects,
        retained_revisions = length(plan.retention.retained_revisions),
        omitted_revisions = length(plan.retention.omitted_revisions),
        retained_runs = length(plan.retention.retained_runs),
        omitted_runs = length(plan.retention.omitted_runs),
    )
    return _refuse_invalid_capsule_manifest(CapsuleManifest(
        2, profile.archive_id, String(source_archive_id), [plan.source_revision],
        plan.target, plan.verification, counts, payloads_embedded, content, readiness,
    ))
end

to_namedtuple(entry::CapsuleContentEntry) = (
    kind = entry.kind,
    status = entry.status,
    object_id = entry.object_id,
    revision_id = entry.revision_id,
    content_id = entry.content_id,
    label = entry.label,
    reason = entry.reason,
    encoding = entry.encoding,
)

to_namedtuple(readiness::CapsuleReadiness) = (
    inspectable = readiness.inspectable,
    replayable = readiness.replayable,
    restartable = readiness.restartable,
    rerunnable = readiness.rerunnable,
)

to_namedtuple(manifest::CapsuleManifest) = (
    format_version = manifest.format_version,
    archive_id = manifest.archive_id,
    source_archive_id = manifest.source_archive_id,
    root_revisions = Tuple(id.value for id in manifest.root_revisions),
    target = manifest.target,
    verification = manifest.verification,
    counts = manifest.counts,
    payloads_embedded = manifest.payloads_embedded,
    content = Tuple(to_namedtuple(entry) for entry in manifest.content),
    readiness = to_namedtuple(manifest.readiness),
)

function _capsule_content_storage(entry::CapsuleContentEntry)
    nt = to_namedtuple(entry)
    return (
        kind = String(nt.kind),
        status = String(nt.status),
        object_id = nt.object_id,
        revision_id = nt.revision_id,
        content_id = nt.content_id,
        label = nt.label,
        reason = String(nt.reason),
        encoding = nt.encoding,
    )
end

function _restore_capsule_content_entry(nt)
    return CapsuleContentEntry(
        Symbol(nt.kind),
        Symbol(nt.status);
        object_id = String(nt.object_id),
        revision_id = String(nt.revision_id),
        content_id = String(nt.content_id),
        label = String(nt.label),
        reason = Symbol(nt.reason),
        encoding = String(nt.encoding),
    )
end

function _capsule_readiness_storage(readiness::CapsuleReadiness)
    return to_namedtuple(readiness)
end

function _restore_capsule_readiness(nt, diagnostics = DiagnosticMessage[])
    return CapsuleReadiness(
        Bool(nt.inspectable), Bool(nt.replayable), Bool(nt.restartable), Bool(nt.rerunnable),
        diagnostics,
    )
end

function _capsule_manifest_storage(manifest::CapsuleManifest)
    nt = to_namedtuple(manifest)
    return (
        format_version = nt.format_version,
        archive_id = nt.archive_id,
        source_archive_id = nt.source_archive_id,
        root_revisions = collect(nt.root_revisions),
        target = String(nt.target),
        verification = String(nt.verification),
        counts = nt.counts,
        payloads_embedded = nt.payloads_embedded,
        content = [_capsule_content_storage(entry) for entry in manifest.content],
        readiness = _capsule_readiness_storage(manifest.readiness),
    )
end

function _restore_capsule_manifest(nt)
    nt.payloads_embedded isa Bool || throw(ArgumentError("invalid capsule payload flag"))
    counts = CapsuleCounts(Tuple(Int(getproperty(nt.counts, name)) for name in fieldnames(CapsuleCounts)))
    if !haskey(nt, :content)
        Int(nt.format_version) == 1 || throw(ArgumentError(
            "capsule manifest is missing its content disposition list",
        ))
        content = CapsuleContentEntry[]
        readiness = CapsuleReadiness(false, false, false, false)
    else
        content = CapsuleContentEntry[_restore_capsule_content_entry(entry) for entry in nt.content]
        readiness = _restore_capsule_readiness(nt.readiness)
    end
    return _refuse_invalid_capsule_manifest(CapsuleManifest(
        Int(nt.format_version), String(nt.archive_id), String(nt.source_archive_id),
        RevisionId[RevisionId(String(value)) for value in nt.root_revisions],
        Symbol(nt.target), Symbol(nt.verification), counts, nt.payloads_embedded,
        content, readiness,
    ))
end

"""Caller-supplied scientific state for one retained object version."""
struct CapsulePayload
    object_id::ObjectId
    revision_id::RevisionId
    value
end

"""
    CapsuleRedaction(object_id, revision_id=nothing)

Drop payload bytes for a retained object version. `revision_id=nothing` redacts
every retained version of that object.
"""
struct CapsuleRedaction
    object_id::ObjectId
    revision_id::Union{Nothing,RevisionId}
end

CapsuleRedaction(object_id::ObjectId) = CapsuleRedaction(object_id, nothing)

function to_namedtuple(payload::CapsulePayload)
    value = is_portable_value(payload.value) ? _portable_value_namedtuple(payload.value) : nothing
    return (
        object_id = payload.object_id.value,
        revision_id = payload.revision_id.value,
        value = value,
    )
end

"""Successful capsule materialization. Execution readiness is on the manifest."""
struct CapsuleArchiveResult
    path::String
    manifest::CapsuleManifest
    source_unchanged::Bool
end

to_namedtuple(result::CapsuleArchiveResult) = (
    path = result.path, manifest = to_namedtuple(result.manifest),
    source_unchanged = result.source_unchanged,
)

"""Forensic capsule view returned by `inspect_archive(path, CapsuleManifest)`."""
struct ArchiveCapsuleInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    manifest::Union{Nothing,CapsuleManifest}
    payloads::Vector{CapsulePayload}
    documents::Vector{PortableSemanticDocument}
    achieved::CapsuleReadiness
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveCapsuleInspection) = view.valid
validate(view::ArchiveCapsuleInspection) = ValidationReport(
    :ah5_capsule, view.valid, copy(view.diagnostics),
    (; path = view.path, identified = view.identified, feature_declared = view.feature_declared),
)
function report(view::ArchiveCapsuleInspection)
    if view.manifest === nothing
        summary = view.feature_declared ? "AH5 capsule manifest could not be read." :
            "AH5 archive has no declared capsule manifest."
    elseif view.manifest.payloads_embedded
        summary = "AH5 reproduction capsule embeds scientific state."
    else
        summary = "AH5 reproduction capsule does not embed scientific payload bytes."
    end
    return ObjectReport(
        :ah5_capsule, summary, to_namedtuple(view), copy(view.diagnostics), ArtifactRef[],
    )
end
to_namedtuple(view::ArchiveCapsuleInspection) = (
    path = view.path, identified = view.identified, feature_declared = view.feature_declared,
    valid = view.valid,
    manifest = view.manifest === nothing ? nothing : to_namedtuple(view.manifest),
    payloads = Tuple(to_namedtuple(payload) for payload in view.payloads),
    documents = Tuple(to_namedtuple(document) for document in view.documents),
    achieved = to_namedtuple(view.achieved),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)

function _capsule_profile(profile::ArchiveProfile)
    AH5_CAPSULE_FEATURE in profile.required_features && throw(ArgumentError(
        "capsule manifests are an optional AH5 v1 feature",
    ))
    features = Symbol[profile.features...]
    AH5_CAPSULE_FEATURE in features || push!(features, AH5_CAPSULE_FEATURE)
    return ArchiveProfile(;
        magic = profile.magic, profile_version = profile.profile_version,
        archive_id = profile.archive_id, created_at = profile.created_at,
        creator = profile.creator, features = Tuple(features),
        required_features = profile.required_features, roots = profile.roots,
        package_version = profile.package_version,
    )
end

function _refuse_capsule_root_collision(profile::ArchiveProfile)
    for root in (profile.roots.namespaces, profile.roots.schemas, profile.roots.history,
                 profile.roots.provenance, profile.roots.externals)
        for reserved in (
            AH5_CAPSULE_KEY, AH5_CAPSULE_PAYLOADS_KEY, AH5_CAPSULE_DOCUMENTS_KEY,
            AH5_CAPSULE_NATIVE_KEY,
        )
            _path_overlap(root, reserved) && throw(ArgumentError(
                "archive root overlaps reserved capsule metadata: $root",
            ))
        end
    end
    return nothing
end

function _capsule_schema_registry(listings)
    return SchemaRegistry([
        SchemaDefinition(listing.schema;
            namespace = listing.namespace, compatibility = listing.compatibility,
            fields = listing.fields, node_schema = listing.node_schema,
            documentation = listing.documentation, package_version = listing.package_version,
            replaces = listing.replaces, replaced_by = listing.replaced_by,
            migration = listing.migration)
        for listing in listings
    ])
end
