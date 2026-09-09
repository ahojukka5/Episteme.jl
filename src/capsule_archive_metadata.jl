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
    definitions = SchemaDefinition[]
    for key in sort!(collect(keys(refs)))
        matches = [definition for definition in schemas.entries if
            _integrity_schema_key(definition.schema) == key]
        length(matches) == 1 || throw(ArgumentError(
            "capsule needs exactly one embedded definition for schema $(repr(key))",
        ))
        push!(definitions, only(matches))
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
const CapsuleCounts = NamedTuple{
    (:retained_objects, :omitted_objects, :retained_revisions, :omitted_revisions,
     :retained_runs, :omitted_runs),
    NTuple{6,Int},
}

"""
    CapsuleManifest

Identity and scope of a metadata-only AH5 capsule. Requested target and
verification record the plan's intent, not payload completeness or executable
replay readiness. Omitted counts describe the source at materialization time.
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
end

function _refuse_invalid_capsule_manifest(manifest::CapsuleManifest)
    manifest.format_version == 1 || throw(ArgumentError("unsupported capsule manifest version"))
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
    manifest.payloads_embedded && throw(ArgumentError(
        "capsule v1 does not embed scientific payload bytes",
    ))
    return manifest
end

function _capsule_manifest(profile::ArchiveProfile, source_archive_id, plan::CapsulePlan)
    counts = (
        retained_objects = plan.retention.retained_objects,
        omitted_objects = plan.retention.omitted_objects,
        retained_revisions = length(plan.retention.retained_revisions),
        omitted_revisions = length(plan.retention.omitted_revisions),
        retained_runs = length(plan.retention.retained_runs),
        omitted_runs = length(plan.retention.omitted_runs),
    )
    return _refuse_invalid_capsule_manifest(CapsuleManifest(
        1, profile.archive_id, String(source_archive_id), [plan.source_revision],
        plan.target, plan.verification, counts, false,
    ))
end

to_namedtuple(manifest::CapsuleManifest) = (
    format_version = manifest.format_version,
    archive_id = manifest.archive_id,
    source_archive_id = manifest.source_archive_id,
    root_revisions = Tuple(id.value for id in manifest.root_revisions),
    target = manifest.target,
    verification = manifest.verification,
    counts = manifest.counts,
    payloads_embedded = manifest.payloads_embedded,
)

function _capsule_manifest_storage(manifest::CapsuleManifest)
    nt = to_namedtuple(manifest)
    return merge(nt, (
        root_revisions = collect(nt.root_revisions),
        target = String(nt.target), verification = String(nt.verification),
    ))
end

function _restore_capsule_manifest(nt)
    nt.payloads_embedded isa Bool || throw(ArgumentError("invalid capsule payload flag"))
    counts = CapsuleCounts(Tuple(Int(getproperty(nt.counts, name)) for name in fieldnames(CapsuleCounts)))
    return _refuse_invalid_capsule_manifest(CapsuleManifest(
        Int(nt.format_version), String(nt.archive_id), String(nt.source_archive_id),
        RevisionId[RevisionId(String(value)) for value in nt.root_revisions],
        Symbol(nt.target), Symbol(nt.verification), counts, nt.payloads_embedded,
    ))
end

"""Successful metadata capsule materialization; no execution-readiness claim."""
struct CapsuleArchiveResult
    path::String
    manifest::CapsuleManifest
    source_unchanged::Bool
end

to_namedtuple(result::CapsuleArchiveResult) = (
    path = result.path, manifest = to_namedtuple(result.manifest),
    source_unchanged = result.source_unchanged,
)

"""Forensic capsule metadata view returned by `inspect_archive(path, CapsuleManifest)`."""
struct ArchiveCapsuleInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    manifest::Union{Nothing,CapsuleManifest}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveCapsuleInspection) = view.valid
validate(view::ArchiveCapsuleInspection) = ValidationReport(
    :ah5_capsule, view.valid, copy(view.diagnostics),
    (; path = view.path, identified = view.identified, feature_declared = view.feature_declared),
)
report(view::ArchiveCapsuleInspection) = ObjectReport(
    :ah5_capsule,
    view.feature_declared ? "AH5 archive declares metadata-only capsule scope." :
        "AH5 archive has no declared capsule manifest.",
    to_namedtuple(view), copy(view.diagnostics), ArtifactRef[],
)
to_namedtuple(view::ArchiveCapsuleInspection) = (
    path = view.path, identified = view.identified, feature_declared = view.feature_declared,
    valid = view.valid,
    manifest = view.manifest === nothing ? nothing : to_namedtuple(view.manifest),
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
        _path_overlap(root, AH5_CAPSULE_KEY) && throw(ArgumentError(
            "archive root overlaps reserved capsule metadata: $root",
        ))
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
