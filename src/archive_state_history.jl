# ---------------------------------------------------------------------------
# Optional authoritative state-history persistence in AH5 (#81 / epic #24)
# ---------------------------------------------------------------------------

const AH5_STATE_HISTORY_FEATURE = :state_history_records
const AH5_STATE_HISTORY_KEY = "episteme/state_history"

"""
    ArchiveStateHistory

Authoritative payload-free revision/state graph: object envelopes, immutable
revision records, and workflow heads. Run/activity/event history is deliberately
not part of this first persistence slice.
"""
struct ArchiveStateHistory
    objects::Vector{ArchiveObject}
    revisions::Vector{RevisionRecord}
    heads::Vector{WorkflowHead}
end

function ArchiveStateHistory(objects; revisions = RevisionRecord[], heads = WorkflowHead[])
    return ArchiveStateHistory(
        _typed_vector(ArchiveObject, objects, "state-history objects"),
        _typed_vector(RevisionRecord, revisions, "state-history revisions"),
        _typed_vector(WorkflowHead, heads, "state-history heads"),
    )
end

"""
    ArchiveStateHistoryInspection <: AbstractValidationReport

Forensic `plain=true` view of the optional AH5 state-history extension.
`state === nothing` for old archives that do not declare the feature or when
state records fail structural/identity validation.
"""
struct ArchiveStateHistoryInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    state::Union{Nothing,ArchiveStateHistory}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveStateHistoryInspection) = view.valid

_state_graph(state::ArchiveStateHistory) = ArchiveGraph(
    state.objects;
    heads = state.heads,
    revisions = state.revisions,
)

function _state_profile(profile::ArchiveProfile)
    AH5_STATE_HISTORY_FEATURE in profile.required_features && throw(ArgumentError(
        "state-history records are an optional AH5 v1 feature and must not be declared required",
    ))
    features = Symbol[profile.features...]
    AH5_STATE_HISTORY_FEATURE in features || push!(features, AH5_STATE_HISTORY_FEATURE)
    return ArchiveProfile(;
        magic = profile.magic,
        profile_version = profile.profile_version,
        archive_id = profile.archive_id,
        created_at = profile.created_at,
        creator = profile.creator,
        features = Tuple(features),
        required_features = profile.required_features,
        roots = profile.roots,
        package_version = profile.package_version,
    )
end

function _profile_with_state_history(profile, kwargs)
    if profile === nothing
        return _state_profile(ArchiveProfile(; kwargs...))
    end
    isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile))",
    ))
    return _state_profile(profile)
end

function _refuse_state_history_root_collision(profile::ArchiveProfile)
    for (name, root) in (
        (:namespaces, profile.roots.namespaces),
        (:schemas, profile.roots.schemas),
        (:history, profile.roots.history),
        (:provenance, profile.roots.provenance),
        (:externals, profile.roots.externals),
    )
        _path_overlap(root, AH5_STATE_HISTORY_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional state-history root $(repr(AH5_STATE_HISTORY_KEY))",
        ))
    end
    _path_overlap(AH5_INTEGRITY_KEY, AH5_STATE_HISTORY_KEY) && throw(ArgumentError(
        "AH5 integrity and state-history roots overlap",
    ))
    return profile
end

# ---------------------------------------------------------------------------
# Plain-safe storage records
# ---------------------------------------------------------------------------

function _state_object_storage(object::ArchiveObject)
    refs = ordered_references(object)
    return (
        object_id = object.object_id.value,
        revision_id = object.revision_id.value,
        content_id = object.content_id === nothing ? "" : object.content_id.value,
        run_id = object.run_id === nothing ? "" : object.run_id.value,
        namespace_id = String(object.namespace.id),
        package_uuid = object.namespace.package_uuid,
        display_name = object.namespace.display_name,
        kind = String(object.kind),
        schema_namespace = String(object.schema.namespace_id),
        schema_id = object.schema.schema_id,
        schema_version = object.schema.version,
        software_environment = object.provenance.software_environment === nothing ? "" :
            object.provenance.software_environment.value,
        execution_context = object.provenance.execution_context === nothing ? "" :
            object.provenance.execution_context.value,
        reference_names = String[String(ref.name) for ref in refs],
        reference_object_ids = String[ref.target.object_id.value for ref in refs],
        reference_revision_ids = String[
            ref.target.revision_id === nothing ? "" : ref.target.revision_id.value for ref in refs
        ],
    )
end

function _restore_state_object(nt)
    names = _string_vec(nt.reference_names)
    object_ids = _string_vec(nt.reference_object_ids)
    revision_ids = _string_vec(nt.reference_revision_ids)
    (length(names) == length(object_ids) && length(names) == length(revision_ids)) ||
        throw(ArgumentError("AH5 state-history reference columns have inconsistent lengths"))
    refs = ArchiveReference[]
    for index in eachindex(names)
        push!(refs, ArchiveReference(
            Symbol(names[index]),
            ObjectId(object_ids[index]);
            revision_id = isempty(revision_ids[index]) ? nothing : RevisionId(revision_ids[index]),
        ))
    end
    content = String(nt.content_id)
    run = String(nt.run_id)
    software = String(nt.software_environment)
    context = String(nt.execution_context)
    namespace = ArchiveNamespace(
        Symbol(nt.namespace_id);
        package_uuid = String(nt.package_uuid),
        display_name = String(nt.display_name),
    )
    return ArchiveObject(
        ObjectId(String(nt.object_id)),
        RevisionId(String(nt.revision_id));
        content_id = isempty(content) ? nothing : ContentId(content),
        run_id = isempty(run) ? nothing : RunId(run),
        namespace = namespace,
        kind = Symbol(nt.kind),
        schema = SchemaRef(
            Symbol(nt.schema_namespace),
            String(nt.schema_id),
            String(nt.schema_version),
        ),
        provenance = ProvenanceRefs(;
            software_environment = isempty(software) ? nothing : SoftwareEnvironmentId(software),
            execution_context = isempty(context) ? nothing : ExecutionContextId(context),
        ),
        references = refs,
    )
end

_state_revision_storage(revision::RevisionRecord) = (
    revision_id = revision.id.value,
    parents = String[parent.value for parent in revision.parents],
    run_id = revision.run_id === nothing ? "" : revision.run_id.value,
    plan_id = revision.plan_id === nothing ? "" : revision.plan_id.value,
)

function _restore_state_revision(nt)
    run = String(nt.run_id)
    plan = String(nt.plan_id)
    return RevisionRecord(
        RevisionId(String(nt.revision_id));
        parents = RevisionId[RevisionId(String(parent)) for parent in nt.parents],
        run_id = isempty(run) ? nothing : RunId(run),
        plan_id = isempty(plan) ? nothing : PlanId(plan),
    )
end

_state_head_storage(head::WorkflowHead) = (
    head_id = head.id.value,
    name = String(head.name),
    revision_id = head.revision_id.value,
)

_restore_state_head(nt) = WorkflowHead(
    WorkflowHeadId(String(nt.head_id)),
    Symbol(nt.name),
    RevisionId(String(nt.revision_id)),
)

# ---------------------------------------------------------------------------
# State-history validation
# ---------------------------------------------------------------------------

_state_external_resolves(externals, target::ObjectRef) =
    _match_external(externals, target.object_id, nothing) !== nothing

function _state_namespace_match(listings, object::ArchiveObject)
    matches = NamespaceListing[
        listing for listing in listings if listing.namespace.id === object.namespace.id
    ]
    length(matches) == 1 || return false, length(matches), nothing
    listing = only(matches)
    expected_uuid = listing.namespace.package_uuid
    object_uuid = object.namespace.package_uuid
    if !isempty(expected_uuid) && isempty(object_uuid)
        return false, 1, :missing_uuid
    elseif !isempty(expected_uuid) && expected_uuid != object_uuid
        return false, 1, :uuid_mismatch
    end
    return true, 1, nothing
end

function _state_schema_match(listings, object::ArchiveObject)
    matches = SchemaListing[listing for listing in listings if listing.schema == object.schema]
    length(matches) == 1 || return false, length(matches), nothing
    listing = only(matches)
    expected_uuid = listing.namespace.package_uuid
    object_uuid = object.namespace.package_uuid
    if !isempty(expected_uuid) && isempty(object_uuid)
        return false, 1, :missing_uuid
    elseif !isempty(expected_uuid) && expected_uuid != object_uuid
        return false, 1, :uuid_mismatch
    end
    return true, 1, nothing
end

function _append_state_namespace_diagnostic!(diagnostics, object, listings)
    isempty(listings) && return diagnostics
    ok, count, reason = _state_namespace_match(listings, object)
    ok && return diagnostics
    code = count == 0 ? :missing_namespace :
        reason === :missing_uuid ? :namespace_identity_missing : :namespace_identity_conflict
    message = count == 0 ?
        "state object $(object.object_id.value) has no matching AH5 namespace listing" :
        reason === :missing_uuid ?
        "state object $(object.object_id.value) omits the package UUID recorded for namespace :$(object.namespace.id)" :
        "state object $(object.object_id.value) namespace identity disagrees with AH5 namespace metadata"
    push!(diagnostics, error_diagnostic(
        code,
        message;
        object_id = object.object_id.value,
        namespace = object.namespace.id,
        matches = count,
    ))
    return diagnostics
end

function _append_state_schema_diagnostic!(diagnostics, object, listings)
    isempty(listings) && return diagnostics
    ok, count, reason = _state_schema_match(listings, object)
    ok && return diagnostics
    code = count == 0 ? :missing_schema :
        reason === :missing_uuid ? :namespace_identity_missing : :state_schema_identity_mismatch
    message = count == 0 ?
        "state object $(object.object_id.value) references an unlisted embedded schema" :
        reason === :missing_uuid ?
        "state object $(object.object_id.value) omits the package UUID required by its embedded schema" :
        "state object $(object.object_id.value) does not match the embedded schema namespace identity"
    push!(diagnostics, error_diagnostic(
        code,
        message;
        object_id = object.object_id.value,
        schema_kind = schema_kind(object.schema),
        version = object.schema.version,
        matches = count,
    ))
    return diagnostics
end

function _validate_state_history(
    state::ArchiveStateHistory;
    externals = ExternalRequirement[],
    namespaces = NamespaceListing[],
    schemas = SchemaListing[],
)
    diagnostics = DiagnosticMessage[]
    reqs = _externals_vector(externals)
    graph = _state_graph(state)

    revision_ids = Set{String}()
    for revision in state.revisions
        if revision.id.value in revision_ids
            push!(diagnostics, error_diagnostic(
                :duplicate_revision_id,
                "state history contains duplicate revision $(revision.id.value)";
                revision_id = revision.id.value,
            ))
        end
        push!(revision_ids, revision.id.value)
    end
    for revision in state.revisions
        for parent in _unique_parents(revision)
            parent.value in revision_ids || push!(diagnostics, error_diagnostic(
                :dangling_parent,
                "revision $(revision.id.value) names unknown parent $(parent.value)";
                revision_id = revision.id.value,
                parent_id = parent.value,
            ))
        end
        _revision_has_parent_cycle(graph, revision) && push!(diagnostics, error_diagnostic(
            :cycle,
            "revision parent graph contains a cycle including $(revision.id.value)";
            revision_id = revision.id.value,
        ))
    end

    object_keys = Set{Tuple{String,String}}()
    for object in state.objects
        key = (object.object_id.value, object.revision_id.value)
        if key in object_keys
            push!(diagnostics, error_diagnostic(
                :duplicate_object_revision,
                "state history contains duplicate object version $(object.object_id.value) @ $(object.revision_id.value)";
                object_id = object.object_id.value,
                revision_id = object.revision_id.value,
            ))
        end
        push!(object_keys, key)
        object.revision_id.value in revision_ids || push!(diagnostics, error_diagnostic(
            :missing_object_revision,
            "object $(object.object_id.value) names unknown revision $(object.revision_id.value)";
            object_id = object.object_id.value,
            revision_id = object.revision_id.value,
        ))
        _validate_object_namespace!(diagnostics, object)
        object.kind == schema_kind(object.schema) || push!(diagnostics, error_diagnostic(
            :schema_kind_mismatch,
            "object $(object.object_id.value) kind $(object.kind) does not match schema $(schema_kind(object.schema))";
            object_id = object.object_id.value,
            kind = object.kind,
            schema_kind = schema_kind(object.schema),
        ))
        object.namespace.id === object.schema.namespace_id || push!(diagnostics, error_diagnostic(
            :schema_namespace_mismatch,
            "object $(object.object_id.value) namespace :$(object.namespace.id) does not match schema namespace :$(object.schema.namespace_id)";
            object_id = object.object_id.value,
            namespace = object.namespace.id,
            schema_namespace = object.schema.namespace_id,
        ))
        _append_state_namespace_diagnostic!(diagnostics, object, namespaces)
        _append_state_schema_diagnostic!(diagnostics, object, schemas)
    end

    head_ids = Set{String}()
    head_names = Set{Symbol}()
    for head in state.heads
        if head.id.value in head_ids
            push!(diagnostics, error_diagnostic(
                :duplicate_head_id,
                "state history contains duplicate head id $(head.id.value)";
                head_id = head.id.value,
            ))
        end
        push!(head_ids, head.id.value)
        if head.name in head_names
            push!(diagnostics, error_diagnostic(
                :duplicate_head_name,
                "state history contains duplicate head name :$(head.name)";
                name = head.name,
            ))
        end
        push!(head_names, head.name)
        head.revision_id.value in revision_ids || push!(diagnostics, error_diagnostic(
            :dangling_head,
            "workflow head :$(head.name) points to unknown revision $(head.revision_id.value)";
            head_id = head.id.value,
            revision_id = head.revision_id.value,
        ))
    end

    for object in state.objects
        visible = _visible_revision_order(graph, object.revision_id)
        for ref in ordered_references(object)
            _resolve_in_revision_scope(graph, ref.target, visible) !== nothing && continue
            _state_external_resolves(reqs, ref.target) && continue
            push!(diagnostics, error_diagnostic(
                :dangling_reference,
                "object $(object.object_id.value) reference :$(ref.name) names unavailable object $(ref.target.object_id.value)";
                object_id = object.object_id.value,
                revision_id = object.revision_id.value,
                name = ref.name,
                target_object_id = ref.target.object_id.value,
                target_revision_id = ref.target.revision_id === nothing ? nothing : ref.target.revision_id.value,
            ))
        end
    end
    return diagnostics
end

function validate(state::ArchiveStateHistory)
    diagnostics = _validate_state_history(state)
    return ValidationReport(
        :archive_state_history,
        !any(diagnostic -> diagnostic.severity === :error, diagnostics),
        diagnostics,
        (;
            objects = length(state.objects),
            revisions = length(state.revisions),
            heads = length(state.heads),
        ),
    )
end

_state_history_from_graph(graph::ArchiveGraph) = ArchiveStateHistory(
    ordered_objects(graph),
    ordered_revisions(graph),
    ordered_heads(graph),
)

# ---------------------------------------------------------------------------
# Physical state-history root
# ---------------------------------------------------------------------------

function _write_state_history!(file, state::ArchiveStateHistory)
    _write_indexed!(file, string(AH5_STATE_HISTORY_KEY, "/objects"), state.objects, _state_object_storage)
    _write_indexed!(file, string(AH5_STATE_HISTORY_KEY, "/revisions"), state.revisions, _state_revision_storage)
    _write_indexed!(file, string(AH5_STATE_HISTORY_KEY, "/heads"), state.heads, _state_head_storage)
    return file
end

function _read_state_history(file)
    objects = _read_indexed(
        ArchiveObject, file, string(AH5_STATE_HISTORY_KEY, "/objects"), _restore_state_object,
    )
    revisions = _read_indexed(
        RevisionRecord, file, string(AH5_STATE_HISTORY_KEY, "/revisions"), _restore_state_revision,
    )
    heads = _read_indexed(
        WorkflowHead, file, string(AH5_STATE_HISTORY_KEY, "/heads"), _restore_state_head,
    )
    return ArchiveStateHistory(objects, revisions, heads)
end

function _state_history_counts_exist(file)
    for child in ("objects", "revisions", "heads")
        _jld2_get(file, _count_key(string(AH5_STATE_HISTORY_KEY, "/", child))) === nothing &&
            return false
    end
    return true
end

"""
    write_state_archive(path, graph; kwargs...)

Create a normal AH5 archive and append authoritative payload-free object,
revision, and head records under the optional state-history feature. Full
run/activity/event provenance remains a later persistence slice.
"""
function write_state_archive(
    path::AbstractString,
    graph::ArchiveGraph;
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    kwargs...,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    reqs = _externals_vector(externals)
    state = _state_history_from_graph(graph)
    namespace_listings = list_namespaces(graph, namespaces)
    schema_listings = schemas === nothing ? SchemaListing[] : list_schemas(schemas)
    diagnostics = _validate_state_history(
        state;
        externals = reqs,
        namespaces = namespace_listings,
        schemas = schema_listings,
    )
    any(diagnostic -> diagnostic.severity === :error, diagnostics) && throw(ArgumentError(
        "refusing to persist invalid state history: $(Tuple(d.code for d in diagnostics if d.severity === :error))",
    ))
    profile_record = _profile_with_state_history(profile, kwargs)
    _refuse_state_history_root_collision(profile_record)

    created = false
    try
        write_archive(
            path;
            graph = graph,
            namespaces = namespaces,
            schemas = schemas,
            externals = reqs,
            profile = profile_record,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_state_history!(file, state)
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end
    return path
end

function _empty_state_history_inspection(path, identified, declared, externals, diagnostics)
    valid = identified && !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveStateHistoryInspection(
        String(path), identified, declared, valid, nothing,
        ExternalRequirement[externals...], diagnostics,
    )
end

"""
    inspect_archive(path, ArchiveStateHistory) -> ArchiveStateHistoryInspection

Forensically reconstruct the optional authoritative state graph with JLD2
`plain=true`. Scientific payloads and domain packages are never loaded.
"""
function inspect_archive(path::AbstractString, ::Type{ArchiveStateHistory})
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    if !base.identified || base.profile === nothing
        return _empty_state_history_inspection(path, base.identified, false, base.externals, diagnostics)
    end
    if any(diagnostic -> diagnostic.severity === :error, diagnostics)
        return _empty_state_history_inspection(path, true, false, base.externals, diagnostics)
    end
    declared = AH5_STATE_HISTORY_FEATURE in base.profile.features
    declared || return _empty_state_history_inspection(path, true, false, base.externals, diagnostics)

    state = nothing
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            _state_history_counts_exist(file) || throw(ArgumentError(
                "AH5 profile declares state-history records but required indexed roots are missing",
            ))
            state = _read_state_history(file)
        end
        append!(diagnostics, _validate_state_history(
            state;
            externals = base.externals,
            namespaces = base.namespaces,
            schemas = base.schemas,
        ))
        base.history.objects == length(state.objects) || push!(diagnostics, error_diagnostic(
            :state_history_summary_mismatch,
            "state-history object count does not match AH5 history summary";
            summary = base.history.objects,
            records = length(state.objects),
        ))
        base.history.revisions == length(state.revisions) || push!(diagnostics, error_diagnostic(
            :state_history_summary_mismatch,
            "state-history revision count does not match AH5 history summary";
            summary = base.history.revisions,
            records = length(state.revisions),
        ))
        base.history.heads == length(state.heads) || push!(diagnostics, error_diagnostic(
            :state_history_summary_mismatch,
            "state-history head count does not match AH5 history summary";
            summary = base.history.heads,
            records = length(state.heads),
        ))
        if any(diagnostic -> diagnostic.severity === :error, diagnostics)
            state = nothing
        end
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_state_history,
            "AH5 authoritative state-history metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        state = nothing
    end

    valid = state !== nothing && !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveStateHistoryInspection(
        String(path), true, true, valid, state, copy(base.externals), diagnostics,
    )
end

function validate(view::ArchiveStateHistoryInspection)
    return ValidationReport(
        :archive_state_history,
        view.valid,
        copy(view.diagnostics),
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            objects = view.state === nothing ? 0 : length(view.state.objects),
            revisions = view.state === nothing ? 0 : length(view.state.revisions),
            heads = view.state === nothing ? 0 : length(view.state.heads),
        ),
    )
end

function report(view::ArchiveStateHistoryInspection)
    nobjects = view.state === nothing ? 0 : length(view.state.objects)
    nrevisions = view.state === nothing ? 0 : length(view.state.revisions)
    return ObjectReport(
        :archive_state_history,
        view.feature_declared ?
            "AH5 state history with $nobjects objects and $nrevisions revisions." :
            "AH5 archive has no authoritative state-history extension.",
        to_namedtuple(view),
        copy(view.diagnostics),
        ArtifactRef[],
    )
end

# ---------------------------------------------------------------------------
# State-only selected revision inspection
# ---------------------------------------------------------------------------

function _state_only_manifest(manifest::RevisionManifest)
    diagnostics = DiagnosticMessage[
        diagnostic for diagnostic in manifest.diagnostics
        if diagnostic.code !== :missing_revision_run
    ]
    return RevisionManifest(
        manifest.mode,
        manifest.revision,
        manifest.entries,
        manifest.heads,
        nothing,
        manifest.plan_id,
        manifest.parents,
        manifest.children,
        manifest.ancestors,
        manifest.descendants,
        manifest.externals,
        diagnostics,
    )
end

"""
    inspect(state::ArchiveStateHistory, revision_id; externals=()) -> RevisionManifest

Reproduce the payload-free selected-state object closure from persisted state
records. Missing run-history diagnostics are intentionally omitted because this
persistence slice does not claim provenance-history completeness.
"""
function inspect(
    state::ArchiveStateHistory,
    revision_id::RevisionId;
    externals = ExternalRequirement[],
)
    return _state_only_manifest(
        inspect(_state_graph(state), revision_id; externals = externals),
    )
end

function inspect(view::ArchiveStateHistoryInspection, revision_id::RevisionId)
    isvalid(view) || throw(ArgumentError("cannot inspect invalid AH5 state history"))
    view.state === nothing && throw(ArgumentError("AH5 archive has no state-history records"))
    return inspect(view.state, revision_id; externals = view.externals)
end

# ---------------------------------------------------------------------------
# Generic representations
# ---------------------------------------------------------------------------

_state_object_namedtuple(object::ArchiveObject) = _state_object_storage(object)
_state_revision_namedtuple(revision::RevisionRecord) = _state_revision_storage(revision)
_state_head_namedtuple(head::WorkflowHead) = _state_head_storage(head)

to_namedtuple(state::ArchiveStateHistory) = (
    objects = Tuple(_state_object_namedtuple(object) for object in state.objects),
    revisions = Tuple(_state_revision_namedtuple(revision) for revision in state.revisions),
    heads = Tuple(_state_head_namedtuple(head) for head in state.heads),
)

to_namedtuple(view::ArchiveStateHistoryInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    state = view.state === nothing ? nothing : to_namedtuple(view.state),
    externals = Tuple(to_namedtuple(req) for req in view.externals),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
