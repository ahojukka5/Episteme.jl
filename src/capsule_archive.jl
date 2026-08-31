# ---------------------------------------------------------------------------
# Standalone inspectable AH5 capsule materialization (#87 / parent #35)
# ---------------------------------------------------------------------------

const AH5_CAPSULE_FEATURE = :capsule_manifest
const AH5_CAPSULE_KEY = "episteme/capsule"

"""
    CapsuleArchiveManifest

Immutable identity/retention record for one materialized capsule. The capsule
has its own AH5 archive id; `source_archive_id` preserves the identity of the
archive it was derived from. `payloads_embedded` is deliberately false in this
first physical capsule slice.
"""
struct CapsuleArchiveManifest
    capsule_archive_id::String
    source_archive_id::String
    root_revisions::Vector{RevisionId}
    target::Symbol
    verification::Symbol
    payloads_embedded::Bool
    retained_objects::Int
    omitted_objects::Int
    retained_revisions::Int
    retained_runs::Int
    external_objects::Int
end

"""
    CapsuleArchiveInspection <: AbstractValidationReport

Generic forensic inspection of one AH5 capsule manifest plus cross-checks
against the persisted state/run/event and integrity layers.
"""
struct CapsuleArchiveInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    manifest::Union{Nothing,CapsuleArchiveManifest}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::CapsuleArchiveInspection) = view.valid

"""
    CapsuleArchiveResult

Successful materialization result. `source_unchanged` is always true; `graph`
is the newly compacted in-memory graph that was written to the capsule.
"""
struct CapsuleArchiveResult
    path::String
    source_unchanged::Bool
    manifest::CapsuleArchiveManifest
    graph::ArchiveGraph
    schemas::SchemaRegistry
    externals::Vector{ExternalRequirement}
    report::ValidationReport
end

function _capsule_archive_nonempty(value, name)
    text = String(strip(value))
    isempty(text) && throw(ArgumentError("$name must not be empty"))
    return text
end

function _capsule_archive_profile(profile, capsule_archive_id)
    if profile === nothing
        base = ArchiveProfile(; archive_id = capsule_archive_id)
    else
        profile isa ArchiveProfile || throw(ArgumentError(
            "profile must be ArchiveProfile or nothing, got $(typeof(profile))",
        ))
        if capsule_archive_id !== nothing && String(capsule_archive_id) != profile.archive_id
            throw(ArgumentError(
                "capsule_archive_id disagrees with profile.archive_id",
            ))
        end
        base = profile
    end
    features = Symbol[base.features...]
    for feature in (AH5_CAPSULE_FEATURE, AH5_INTEGRITY_FEATURE, AH5_EVENT_HISTORY_FEATURE)
        feature in features || push!(features, feature)
    end
    return ArchiveProfile(;
        magic = base.magic,
        profile_version = base.profile_version,
        archive_id = base.archive_id,
        created_at = base.created_at,
        creator = base.creator,
        features = Tuple(features),
        required_features = base.required_features,
        roots = base.roots,
        package_version = base.package_version,
    )
end

function _refuse_capsule_root_collision(profile::ArchiveProfile)
    for (name, root) in (
        (:namespaces, profile.roots.namespaces),
        (:schemas, profile.roots.schemas),
        (:history, profile.roots.history),
        (:provenance, profile.roots.provenance),
        (:externals, profile.roots.externals),
        (:integrity, AH5_INTEGRITY_KEY),
        (:state_history, AH5_STATE_HISTORY_KEY),
        (:run_history, AH5_RUN_HISTORY_KEY),
        (:event_history, AH5_EVENT_HISTORY_KEY),
    )
        _path_overlap(root, AH5_CAPSULE_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps capsule manifest root $(repr(AH5_CAPSULE_KEY))",
        ))
    end
    return profile
end

function _capsule_manifest_storage(manifest::CapsuleArchiveManifest)
    return (
        capsule_archive_id = manifest.capsule_archive_id,
        source_archive_id = manifest.source_archive_id,
        root_revisions = String[id.value for id in manifest.root_revisions],
        target = String(manifest.target),
        verification = String(manifest.verification),
        payloads_embedded = manifest.payloads_embedded,
        retained_objects = manifest.retained_objects,
        omitted_objects = manifest.omitted_objects,
        retained_revisions = manifest.retained_revisions,
        retained_runs = manifest.retained_runs,
        external_objects = manifest.external_objects,
    )
end

function _restore_capsule_manifest(nt)
    roots = RevisionId[RevisionId(String(value)) for value in nt.root_revisions]
    isempty(roots) && throw(ArgumentError("capsule manifest has no root revision"))
    target = Symbol(nt.target)
    target in CAPSULE_TARGETS || throw(ArgumentError("unsupported capsule target :$target"))
    verification = _verification_level(Symbol(nt.verification))
    return CapsuleArchiveManifest(
        _capsule_archive_nonempty(nt.capsule_archive_id, "capsule archive id"),
        _capsule_archive_nonempty(nt.source_archive_id, "source archive id"),
        roots,
        target,
        verification,
        _as_bool(nt.payloads_embedded),
        Int(nt.retained_objects),
        Int(nt.omitted_objects),
        Int(nt.retained_revisions),
        Int(nt.retained_runs),
        Int(nt.external_objects),
    )
end

function _capsule_manifest_diagnostics(manifest::CapsuleArchiveManifest)
    diagnostics = DiagnosticMessage[]
    manifest.capsule_archive_id == manifest.source_archive_id && push!(diagnostics, error_diagnostic(
        :capsule_source_identity_reused,
        "capsule archive id must differ from source archive id";
        archive_id = manifest.capsule_archive_id,
    ))
    isempty(manifest.root_revisions) && push!(diagnostics, error_diagnostic(
        :capsule_root_missing,
        "capsule manifest has no root revision",
    ))
    manifest.target in CAPSULE_TARGETS || push!(diagnostics, error_diagnostic(
        :unsupported_target,
        "unsupported capsule target :$(manifest.target)";
        target = manifest.target,
    ))
    try
        _verification_level(manifest.verification)
    catch err
        push!(diagnostics, error_diagnostic(
            :unsupported_verification_level,
            "unsupported capsule verification level :$(manifest.verification)";
            reason = sprint(showerror, err),
        ))
    end
    for (name, count) in (
        (:retained_objects, manifest.retained_objects),
        (:omitted_objects, manifest.omitted_objects),
        (:retained_revisions, manifest.retained_revisions),
        (:retained_runs, manifest.retained_runs),
        (:external_objects, manifest.external_objects),
    )
        count >= 0 || push!(diagnostics, error_diagnostic(
            :invalid_capsule_count,
            "capsule manifest count $name must be non-negative";
            field = name,
            value = count,
        ))
    end
    return diagnostics
end

function validate(manifest::CapsuleArchiveManifest)
    diagnostics = _capsule_manifest_diagnostics(manifest)
    return ValidationReport(
        :capsule_archive_manifest,
        !any(d -> d.severity === :error, diagnostics),
        diagnostics,
        (;
            capsule_archive_id = manifest.capsule_archive_id,
            source_archive_id = manifest.source_archive_id,
            roots = Tuple(id.value for id in manifest.root_revisions),
            payloads_embedded = manifest.payloads_embedded,
        ),
    )
end

# ---------------------------------------------------------------------------
# Binding and filtering helpers
# ---------------------------------------------------------------------------

_capsule_id_tuple(values) = Tuple(id.value for id in values)

function _capsule_classification_signature(items)
    return Tuple(
        (
            item.object_id.value,
            item.revision_id === nothing ? "" : item.revision_id.value,
            item.content_id === nothing ? "" : item.content_id.value,
            item.class,
        )
        for item in items
    )
end

function _refuse_capsule_retention_mismatch(expected::PurgePlan, actual::PurgePlan)
    checks = (
        (:retained_revisions, _capsule_id_tuple(expected.retained_revisions), _capsule_id_tuple(actual.retained_revisions)),
        (:omitted_revisions, _capsule_id_tuple(expected.omitted_revisions), _capsule_id_tuple(actual.omitted_revisions)),
        (:retained_runs, _capsule_id_tuple(expected.retained_runs), _capsule_id_tuple(actual.retained_runs)),
        (:omitted_runs, _capsule_id_tuple(expected.omitted_runs), _capsule_id_tuple(actual.omitted_runs)),
        (:classifications, _capsule_classification_signature(expected.classifications), _capsule_classification_signature(actual.classifications)),
    )
    for (name, left, right) in checks
        left == right && continue
        throw(ArgumentError("capsule plan $name no longer matches the source archive"))
    end
    expected.policy == actual.policy || throw(ArgumentError(
        "capsule retention policy no longer matches the source archive",
    ))
    return actual
end

function _capsule_manifest_entry_signature(entry::ManifestEntry)
    return (
        entry.object_id.value,
        entry.revision_id === nothing ? "" : entry.revision_id.value,
        entry.content_id === nothing ? "" : entry.content_id.value,
        entry.availability,
        entry.object === nothing ? nothing : entry.object.kind,
        entry.object === nothing ? nothing : entry.object.schema,
    )
end

function _refuse_capsule_manifest_mismatch(source::RevisionManifest, planned::RevisionManifest)
    source.revision.id == planned.revision.id || throw(ArgumentError(
        "capsule plan revision does not match source graph",
    ))
    source.plan_id == planned.plan_id || throw(ArgumentError(
        "capsule plan PlanId does not match source graph",
    ))
    Tuple(source.parents) == Tuple(planned.parents) || throw(ArgumentError(
        "capsule plan parent revisions do not match source graph",
    ))
    source_entries = Tuple(_capsule_manifest_entry_signature(entry) for entry in source.entries)
    planned_entries = Tuple(_capsule_manifest_entry_signature(entry) for entry in planned.entries)
    source_entries == planned_entries || throw(ArgumentError(
        "capsule plan state closure no longer matches source graph",
    ))
    return planned
end

function _capsule_required_schema_refs(graph::ArchiveGraph)
    refs = Dict{Tuple{String,String,String},SchemaRef}()
    for object in graph.objects
        refs[_integrity_schema_key(object.schema)] = object.schema
    end
    for run in graph.runs
        for staged in run.staged
            refs[_integrity_schema_key(staged.schema)] = staged.schema
        end
    end
    return [refs[key] for key in sort!(collect(keys(refs)))]
end

function _capsule_schema_registry(graph::ArchiveGraph, schemas::SchemaRegistry)
    definitions = SchemaDefinition[]
    for ref in _capsule_required_schema_refs(graph)
        matches = SchemaDefinition[entry for entry in schemas.entries if entry.schema == ref]
        length(matches) == 1 || throw(ArgumentError(
            "capsule requires exactly one schema definition for $(schema_kind(ref)) version $(ref.version)",
        ))
        push!(definitions, only(matches))
    end
    return SchemaRegistry(definitions)
end

function _capsule_namespace_registry(graph::ArchiveGraph, schemas::SchemaRegistry, registry)
    registry === nothing && return nothing
    registry isa NamespaceRegistry || throw(ArgumentError(
        "namespaces must be NamespaceRegistry or nothing",
    ))
    used = Set{Symbol}()
    for object in graph.objects
        push!(used, object.namespace.id)
    end
    for run in graph.runs
        for staged in run.staged
            push!(used, staged.namespace.id)
        end
    end
    for definition in schemas.entries
        push!(used, definition.namespace.id)
    end
    selected = NamespaceClaim[]
    seen = Set{Symbol}()
    for id in sort!(collect(used); by = String)
        direct = find_claim(registry, id)
        canonical = resolve_namespace(registry, id)
        for claim in (canonical, direct)
            claim === nothing && continue
            claim.namespace.id in seen && continue
            push!(seen, claim.namespace.id)
            push!(selected, claim)
        end
    end
    return NamespaceRegistry(selected)
end

function _capsule_external_classification_keys(plan::PurgePlan)
    return Set(
        (
            item.object_id.value,
            item.content_id === nothing ? "" : item.content_id.value,
        )
        for item in plan.classifications if item.class === :external
    )
end

function _capsule_external_requirements(plan::PurgePlan, externals)
    source = _externals_vector(externals)
    keys = _capsule_external_classification_keys(plan)
    result = ExternalRequirement[]
    for key in sort!(collect(keys))
        matches = ExternalRequirement[
            req for req in source
            if req.object_id.value == key[1] &&
                req.content_id !== nothing && req.content_id.value == key[2]
        ]
        length(matches) == 1 || throw(ArgumentError(
            "capsule external dependency $(key[1]) does not resolve to exactly one strong requirement",
        ))
        push!(result, only(matches))
    end
    return result
end

function _capsule_external_set_signature(values)
    return Tuple(sort!([_capsule_external_key(req) for req in values]))
end

function _refuse_capsule_external_mismatch(plan::CapsulePlan, externals)
    _capsule_external_set_signature(plan.externals) == _capsule_external_set_signature(externals) ||
        throw(ArgumentError("capsule external requirements no longer match the plan"))
    return externals
end

# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

"""
    write_capsule_archive(path, source_graph, plan, schemas;
                          source_archive_id, namespaces=nothing, externals=(),
                          capsule_archive_id=nothing, profile=nothing)
        -> CapsuleArchiveResult

Materialize one metadata-complete standalone inspectable capsule. Scientific
payload bytes are not embedded by this slice and the manifest records that fact
explicitly.
"""
function write_capsule_archive(
    path::AbstractString,
    source_graph::ArchiveGraph,
    plan::CapsulePlan,
    schemas::SchemaRegistry;
    source_archive_id::AbstractString,
    namespaces = nothing,
    externals = ExternalRequirement[],
    capsule_archive_id = nothing,
    profile = nothing,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    isvalid(plan) || throw(ArgumentError("refusing to materialize invalid CapsulePlan"))
    source_id = _capsule_archive_nonempty(source_archive_id, "source_archive_id")

    source_manifest = inspect(source_graph, plan.source_revision; externals = externals)
    _refuse_capsule_manifest_mismatch(source_manifest, plan.manifest)

    compacted = compact_archive(
        source_graph,
        [RetentionRoot(plan.source_revision)];
        policy = plan.retention.policy,
        externals = externals,
    )
    compacted.graph === nothing && throw(ArgumentError(
        "capsule compaction failed: $(Tuple(d.code for d in compacted.report.diagnostics))",
    ))
    _refuse_capsule_retention_mismatch(plan.retention, compacted.plan)
    graph = compacted.graph

    capsule_schemas = _capsule_schema_registry(graph, schemas)
    capsule_namespaces = _capsule_namespace_registry(graph, capsule_schemas, namespaces)
    capsule_externals = _capsule_external_requirements(compacted.plan, externals)
    _refuse_capsule_external_mismatch(plan, capsule_externals)

    integrity = RevisionIntegrityManifest[plan.integrity]
    _refuse_unstorable_integrity(integrity)
    _refuse_integrity_archive_mismatch(
        integrity,
        graph,
        capsule_schemas,
        capsule_externals,
    )

    requested_capsule_id = capsule_archive_id === nothing ? nothing :
        _capsule_archive_nonempty(capsule_archive_id, "capsule_archive_id")
    base_profile = if profile === nothing
        ArchiveProfile(;
            archive_id = requested_capsule_id === nothing ? string(UUIDs.uuid4()) : requested_capsule_id,
        )
    else
        profile
    end
    capsule_profile = _capsule_archive_profile(base_profile, requested_capsule_id)
    capsule_profile.archive_id == source_id && throw(ArgumentError(
        "capsule archive id must differ from source archive id",
    ))
    _refuse_capsule_root_collision(capsule_profile)

    capsule_manifest = CapsuleArchiveManifest(
        capsule_profile.archive_id,
        source_id,
        RevisionId[plan.source_revision],
        plan.target,
        plan.verification,
        false,
        compacted.plan.retained_objects,
        compacted.plan.omitted_objects,
        length(compacted.plan.retained_revisions),
        length(compacted.plan.retained_runs),
        compacted.plan.external_objects,
    )
    manifest_report = validate(capsule_manifest)
    isvalid(manifest_report) || throw(ArgumentError(
        "invalid capsule archive manifest: $(Tuple(d.code for d in manifest_report.diagnostics))",
    ))

    created = false
    try
        write_event_archive(
            path,
            graph;
            namespaces = capsule_namespaces,
            schemas = capsule_schemas,
            externals = capsule_externals,
            profile = capsule_profile,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_indexed!(
                file,
                AH5_INTEGRITY_KEY,
                integrity,
                _integrity_manifest_storage,
            )
            file[AH5_CAPSULE_KEY] = _capsule_manifest_storage(capsule_manifest)
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end

    report = ValidationReport(
        :capsule_archive,
        true,
        DiagnosticMessage[],
        (;
            path = String(path),
            capsule_archive_id = capsule_manifest.capsule_archive_id,
            source_archive_id = capsule_manifest.source_archive_id,
            root_revision = plan.source_revision.value,
            payloads_embedded = false,
        ),
    )
    return CapsuleArchiveResult(
        String(path),
        true,
        capsule_manifest,
        graph,
        capsule_schemas,
        capsule_externals,
        report,
    )
end

# ---------------------------------------------------------------------------
# Forensic inspector
# ---------------------------------------------------------------------------

function _empty_capsule_inspection(path, identified, declared, diagnostics)
    valid = identified && !any(d -> d.severity === :error, diagnostics)
    return CapsuleArchiveInspection(
        String(path), identified, declared, valid, nothing, diagnostics,
    )
end

"""
    inspect_archive(path, CapsuleArchiveManifest) -> CapsuleArchiveInspection

Inspect the capsule identity/retention record and cross-check it against the
persisted authoritative metadata-history and integrity layers.
"""
function inspect_archive(path::AbstractString, ::Type{CapsuleArchiveManifest})
    core = inspect_archive(path)
    diagnostics = copy(core.diagnostics)
    if !core.identified || core.profile === nothing
        return _empty_capsule_inspection(path, core.identified, false, diagnostics)
    end
    any(d -> d.severity === :error, diagnostics) &&
        return _empty_capsule_inspection(path, true, false, diagnostics)

    declared = AH5_CAPSULE_FEATURE in core.profile.features
    declared || return _empty_capsule_inspection(path, true, false, diagnostics)
    for feature in (AH5_INTEGRITY_FEATURE, AH5_STATE_HISTORY_FEATURE,
                    AH5_RUN_HISTORY_FEATURE, AH5_EVENT_HISTORY_FEATURE)
        feature in core.profile.features || push!(diagnostics, error_diagnostic(
            :capsule_feature_missing,
            "capsule manifest requires feature :$feature";
            feature = feature,
        ))
    end

    manifest = nothing
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            raw = _jld2_get(file, AH5_CAPSULE_KEY)
            raw === nothing && throw(ArgumentError("capsule manifest root is missing"))
            manifest = _restore_capsule_manifest(raw)
        end
        append!(diagnostics, _capsule_manifest_diagnostics(manifest))
        manifest.capsule_archive_id == core.profile.archive_id || push!(diagnostics, error_diagnostic(
            :capsule_archive_identity_mismatch,
            "capsule manifest archive id does not match AH5 profile";
            profile_archive_id = core.profile.archive_id,
            manifest_archive_id = manifest.capsule_archive_id,
        ))

        event_view = inspect_archive(path, ArchiveEventHistory)
        append!(diagnostics, event_view.diagnostics)
        integrity_view = inspect_archive(path, RevisionIntegrityManifest)
        append!(diagnostics, integrity_view.diagnostics)
        if isvalid(event_view) && event_view.state !== nothing
            graph = reconstruct_graph(event_view)
            for root in manifest.root_revisions
                find_revision(graph, root) !== nothing || push!(diagnostics, error_diagnostic(
                    :capsule_root_missing,
                    "capsule root revision $(root.value) is absent from reconstructed graph";
                    revision_id = root.value,
                ))
            end
            manifest.retained_objects == length(graph.objects) || push!(diagnostics, error_diagnostic(
                :capsule_manifest_count_mismatch,
                "capsule retained-object count disagrees with reconstructed graph";
                manifest = manifest.retained_objects,
                records = length(graph.objects),
            ))
            manifest.retained_revisions == length(graph.revisions) || push!(diagnostics, error_diagnostic(
                :capsule_manifest_count_mismatch,
                "capsule retained-revision count disagrees with reconstructed graph";
                manifest = manifest.retained_revisions,
                records = length(graph.revisions),
            ))
            manifest.retained_runs == length(graph.runs) || push!(diagnostics, error_diagnostic(
                :capsule_manifest_count_mismatch,
                "capsule retained-run count disagrees with reconstructed graph";
                manifest = manifest.retained_runs,
                records = length(graph.runs),
            ))
        end
        if isvalid(integrity_view)
            stored_roots = Set(item.revision_id.value for item in integrity_view.manifests)
            for root in manifest.root_revisions
                root.value in stored_roots || push!(diagnostics, error_diagnostic(
                    :capsule_integrity_missing,
                    "capsule has no persisted integrity manifest for root revision $(root.value)";
                    revision_id = root.value,
                ))
            end
        end
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_capsule_manifest,
            "AH5 capsule manifest is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        manifest = nothing
    end

    valid = manifest !== nothing && !any(d -> d.severity === :error, diagnostics)
    return CapsuleArchiveInspection(
        String(path), true, true, valid, valid ? manifest : nothing, diagnostics,
    )
end

function validate(view::CapsuleArchiveInspection)
    return ValidationReport(
        :capsule_archive,
        view.valid,
        copy(view.diagnostics),
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            source_archive_id = view.manifest === nothing ? nothing : view.manifest.source_archive_id,
            payloads_embedded = view.manifest === nothing ? nothing : view.manifest.payloads_embedded,
        ),
    )
end

validate(result::CapsuleArchiveResult) = result.report

function report(view::CapsuleArchiveInspection)
    return ObjectReport(
        :capsule_archive,
        view.manifest === nothing ?
            "AH5 archive has no valid capsule manifest." :
            "AH5 capsule $(view.manifest.capsule_archive_id) from source $(view.manifest.source_archive_id).",
        to_namedtuple(view),
        copy(view.diagnostics),
        ArtifactRef[],
    )
end

function report(result::CapsuleArchiveResult)
    return ObjectReport(
        :capsule_archive,
        "Materialized inspectable AH5 capsule $(result.manifest.capsule_archive_id).",
        (;
            path = result.path,
            source_archive_id = result.manifest.source_archive_id,
            root_revisions = Tuple(id.value for id in result.manifest.root_revisions),
            objects = length(result.graph.objects),
            revisions = length(result.graph.revisions),
            runs = length(result.graph.runs),
            schemas = length(result.schemas.entries),
            externals = length(result.externals),
            payloads_embedded = result.manifest.payloads_embedded,
        ),
        copy(result.report.diagnostics),
        ArtifactRef[req.artifact for req in result.externals],
    )
end

to_namedtuple(manifest::CapsuleArchiveManifest) = _capsule_manifest_storage(manifest)

to_namedtuple(view::CapsuleArchiveInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    manifest = view.manifest === nothing ? nothing : to_namedtuple(view.manifest),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
