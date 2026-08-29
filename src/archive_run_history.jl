# ---------------------------------------------------------------------------
# Optional run/activity/restart provenance persistence in AH5 (#83 / epic #24)
# ---------------------------------------------------------------------------

const AH5_RUN_HISTORY_FEATURE = :run_history_records
const AH5_RUN_HISTORY_KEY = "episteme/run_history"

"""
    ArchiveRunHistory

Payload-free authoritative execution provenance for the run layer. Scientific
state remains in [`ArchiveStateHistory`](@ref); events, write transactions, and
log streams are deliberately outside this slice.
"""
struct ArchiveRunHistory
    runs::Vector{RunRecord}

    function ArchiveRunHistory(runs = RunRecord[])
        return new(_typed_vector(RunRecord, runs, "run-history runs"))
    end
end

"""
    ArchiveRunHistoryInspection <: AbstractValidationReport

Forensic view of state + run provenance reconstructed with JLD2 `plain=true`.
A valid view can be converted back to an ordinary [`ArchiveGraph`](@ref) with
[`reconstruct_graph`](@ref), allowing existing `inspect` and readiness logic to
operate without a parallel replay model.
"""
struct ArchiveRunHistoryInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    state::Union{Nothing,ArchiveStateHistory}
    runs::Vector{RunRecord}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveRunHistoryInspection) = view.valid

function _run_history_profile(profile::ArchiveProfile)
    AH5_RUN_HISTORY_FEATURE in profile.required_features && throw(ArgumentError(
        "run-history records are an optional AH5 v1 feature and must not be declared required",
    ))
    features = Symbol[profile.features...]
    AH5_RUN_HISTORY_FEATURE in features || push!(features, AH5_RUN_HISTORY_FEATURE)
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

function _profile_with_run_history(profile, kwargs)
    if profile === nothing
        return _run_history_profile(ArchiveProfile(; kwargs...))
    end
    isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile))",
    ))
    return _run_history_profile(profile)
end

function _refuse_run_history_root_collision(profile::ArchiveProfile)
    for (name, root) in (
        (:namespaces, profile.roots.namespaces),
        (:schemas, profile.roots.schemas),
        (:history, profile.roots.history),
        (:provenance, profile.roots.provenance),
        (:externals, profile.roots.externals),
    )
        _path_overlap(root, AH5_RUN_HISTORY_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional run-history root $(repr(AH5_RUN_HISTORY_KEY))",
        ))
    end
    for (name, root) in (
        (:integrity, AH5_INTEGRITY_KEY),
        (:state_history, AH5_STATE_HISTORY_KEY),
    )
        _path_overlap(root, AH5_RUN_HISTORY_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional run-history root $(repr(AH5_RUN_HISTORY_KEY))",
        ))
    end
    return profile
end

# ---------------------------------------------------------------------------
# Primitive-column helpers
# ---------------------------------------------------------------------------

_run_optional_text(value) = value === nothing ? "" : value.value

function _run_string_column(value, count::Int, name::AbstractString)
    result = String[String(item) for item in value]
    length(result) == count || throw(ArgumentError(
        "AH5 run-history column $name has length $(length(result)), expected $count",
    ))
    return result
end

function _run_int_column(value, count::Int, name::AbstractString)
    result = Int[Int(item) for item in value]
    length(result) == count || throw(ArgumentError(
        "AH5 run-history column $name has length $(length(result)), expected $count",
    ))
    return result
end

function _push_flat_ref!(owners, roles, names, object_ids, revision_ids, owner, role, ref)
    push!(owners, owner)
    push!(roles, String(role))
    push!(names, String(ref.name))
    push!(object_ids, ref.target.object_id.value)
    push!(revision_ids, ref.target.revision_id === nothing ? "" : ref.target.revision_id.value)
    return nothing
end

function _restore_flat_refs(owners, roles, names, object_ids, revision_ids, owner::Int, role::String)
    refs = ArchiveReference[]
    for index in eachindex(owners)
        owners[index] == owner || continue
        roles[index] == role || continue
        push!(refs, ArchiveReference(
            Symbol(names[index]),
            ObjectId(object_ids[index]);
            revision_id = isempty(revision_ids[index]) ? nothing : RevisionId(revision_ids[index]),
        ))
    end
    return refs
end

# ---------------------------------------------------------------------------
# One run as plain-safe primitive columns
# ---------------------------------------------------------------------------

function _run_record_storage(run::RunRecord)
    activity_ids = String[]
    activity_operations = String[]
    activity_idempotency_keys = String[]
    activity_reuse = String[]
    activity_ref_owner = Int[]
    activity_ref_role = String[]
    activity_ref_name = String[]
    activity_ref_object_id = String[]
    activity_ref_revision_id = String[]

    for (owner, activity) in enumerate(run.activities)
        push!(activity_ids, activity.id.value)
        push!(activity_operations, String(activity.operation))
        push!(activity_idempotency_keys,
            activity.idempotency_key === nothing ? "" : activity.idempotency_key)
        push!(activity_reuse, String(activity.reuse))
        for ref in activity.used
            _push_flat_ref!(
                activity_ref_owner, activity_ref_role, activity_ref_name,
                activity_ref_object_id, activity_ref_revision_id,
                owner, :used, ref,
            )
        end
        for ref in activity.generated
            _push_flat_ref!(
                activity_ref_owner, activity_ref_role, activity_ref_name,
                activity_ref_object_id, activity_ref_revision_id,
                owner, :generated, ref,
            )
        end
    end

    staged_object_id = String[]
    staged_content_id = String[]
    staged_namespace_id = String[]
    staged_package_uuid = String[]
    staged_display_name = String[]
    staged_kind = String[]
    staged_schema_namespace = String[]
    staged_schema_id = String[]
    staged_schema_version = String[]
    staged_origin = String[]
    staged_source_revision_id = String[]
    staged_activity_id = String[]
    staged_software_environment = String[]
    staged_execution_context = String[]
    staged_ref_owner = Int[]
    staged_ref_name = String[]
    staged_ref_object_id = String[]
    staged_ref_revision_id = String[]

    for (owner, staged) in enumerate(run.staged)
        push!(staged_object_id, staged.object_id.value)
        push!(staged_content_id, _run_optional_text(staged.content_id))
        push!(staged_namespace_id, String(staged.namespace.id))
        push!(staged_package_uuid, staged.namespace.package_uuid)
        push!(staged_display_name, staged.namespace.display_name)
        push!(staged_kind, String(staged.kind))
        push!(staged_schema_namespace, String(staged.schema.namespace_id))
        push!(staged_schema_id, staged.schema.schema_id)
        push!(staged_schema_version, staged.schema.version)
        push!(staged_origin, String(staged.origin))
        push!(staged_source_revision_id, _run_optional_text(staged.source_revision_id))
        push!(staged_activity_id, _run_optional_text(staged.activity_id))
        push!(staged_software_environment, _run_optional_text(staged.provenance.software_environment))
        push!(staged_execution_context, _run_optional_text(staged.provenance.execution_context))
        for ref in staged.references
            push!(staged_ref_owner, owner)
            push!(staged_ref_name, String(ref.name))
            push!(staged_ref_object_id, ref.target.object_id.value)
            push!(staged_ref_revision_id,
                ref.target.revision_id === nothing ? "" : ref.target.revision_id.value)
        end
    end

    restart = run.restart
    checkpoint_object_id = String[]
    checkpoint_content_id = String[]
    checkpoint_revision_id = String[]
    checkpoint_kind = String[]
    if restart !== nothing
        for checkpoint in restart.checkpoints
            push!(checkpoint_object_id, checkpoint.object_id.value)
            push!(checkpoint_content_id, _run_optional_text(checkpoint.content_id))
            push!(checkpoint_revision_id, _run_optional_text(checkpoint.revision_id))
            push!(checkpoint_kind, String(checkpoint.kind))
        end
    end

    return (
        run_id = run.id.value,
        plan_id = _run_optional_text(run.plan_id),
        parent_run_id = _run_optional_text(run.parent_run_id),
        revision_id = _run_optional_text(run.revision_id),
        status = String(run.status),
        software_environment = _run_optional_text(run.software_environment),
        execution_context = _run_optional_text(run.execution_context),
        agent_id = _run_optional_text(run.agent_id),

        activity_count = length(run.activities),
        activity_ids = activity_ids,
        activity_operations = activity_operations,
        activity_idempotency_keys = activity_idempotency_keys,
        activity_reuse = activity_reuse,
        activity_ref_count = length(activity_ref_owner),
        activity_ref_owner = activity_ref_owner,
        activity_ref_role = activity_ref_role,
        activity_ref_name = activity_ref_name,
        activity_ref_object_id = activity_ref_object_id,
        activity_ref_revision_id = activity_ref_revision_id,

        staged_count = length(run.staged),
        staged_object_id = staged_object_id,
        staged_content_id = staged_content_id,
        staged_namespace_id = staged_namespace_id,
        staged_package_uuid = staged_package_uuid,
        staged_display_name = staged_display_name,
        staged_kind = staged_kind,
        staged_schema_namespace = staged_schema_namespace,
        staged_schema_id = staged_schema_id,
        staged_schema_version = staged_schema_version,
        staged_origin = staged_origin,
        staged_source_revision_id = staged_source_revision_id,
        staged_activity_id = staged_activity_id,
        staged_software_environment = staged_software_environment,
        staged_execution_context = staged_execution_context,
        staged_ref_count = length(staged_ref_owner),
        staged_ref_owner = staged_ref_owner,
        staged_ref_name = staged_ref_name,
        staged_ref_object_id = staged_ref_object_id,
        staged_ref_revision_id = staged_ref_revision_id,

        restart_present = restart !== nothing,
        restart_execution_context = restart === nothing ? "" :
            _run_optional_text(restart.execution_context),
        restart_from_activity_id = restart === nothing ? "" :
            _run_optional_text(restart.from_activity_id),
        checkpoint_count = length(checkpoint_object_id),
        checkpoint_object_id = checkpoint_object_id,
        checkpoint_content_id = checkpoint_content_id,
        checkpoint_revision_id = checkpoint_revision_id,
        checkpoint_kind = checkpoint_kind,
    )
end

function _restore_run_record(nt)
    nact = Int(nt.activity_count)
    nact >= 0 || throw(ArgumentError("negative activity_count in AH5 run history"))
    activity_ids = _run_string_column(nt.activity_ids, nact, "activity_ids")
    activity_operations = _run_string_column(nt.activity_operations, nact, "activity_operations")
    activity_keys = _run_string_column(nt.activity_idempotency_keys, nact, "activity_idempotency_keys")
    activity_reuse = _run_string_column(nt.activity_reuse, nact, "activity_reuse")

    nrefs = Int(nt.activity_ref_count)
    nrefs >= 0 || throw(ArgumentError("negative activity_ref_count in AH5 run history"))
    ref_owner = _run_int_column(nt.activity_ref_owner, nrefs, "activity_ref_owner")
    ref_role = _run_string_column(nt.activity_ref_role, nrefs, "activity_ref_role")
    ref_name = _run_string_column(nt.activity_ref_name, nrefs, "activity_ref_name")
    ref_object = _run_string_column(nt.activity_ref_object_id, nrefs, "activity_ref_object_id")
    ref_revision = _run_string_column(nt.activity_ref_revision_id, nrefs, "activity_ref_revision_id")
    for index in eachindex(ref_owner)
        1 <= ref_owner[index] <= nact || throw(ArgumentError("activity ref owner index out of bounds"))
        ref_role[index] in ("used", "generated") || throw(ArgumentError("unknown activity ref role $(ref_role[index])"))
    end

    run_id = RunId(String(nt.run_id))
    activities = ActivityRecord[]
    for owner in 1:nact
        used = _restore_flat_refs(ref_owner, ref_role, ref_name, ref_object, ref_revision, owner, "used")
        generated = _restore_flat_refs(
            ref_owner, ref_role, ref_name, ref_object, ref_revision, owner, "generated",
        )
        push!(activities, ActivityRecord(
            ActivityId(activity_ids[owner]),
            run_id,
            Symbol(activity_operations[owner]);
            idempotency_key = isempty(activity_keys[owner]) ? nothing : activity_keys[owner],
            used = used,
            generated = generated,
            reuse = Symbol(activity_reuse[owner]),
        ))
    end

    nstaged = Int(nt.staged_count)
    nstaged >= 0 || throw(ArgumentError("negative staged_count in AH5 run history"))
    staged_object = _run_string_column(nt.staged_object_id, nstaged, "staged_object_id")
    staged_content = _run_string_column(nt.staged_content_id, nstaged, "staged_content_id")
    staged_ns = _run_string_column(nt.staged_namespace_id, nstaged, "staged_namespace_id")
    staged_uuid = _run_string_column(nt.staged_package_uuid, nstaged, "staged_package_uuid")
    staged_display = _run_string_column(nt.staged_display_name, nstaged, "staged_display_name")
    staged_kind = _run_string_column(nt.staged_kind, nstaged, "staged_kind")
    staged_schema_ns = _run_string_column(nt.staged_schema_namespace, nstaged, "staged_schema_namespace")
    staged_schema_id = _run_string_column(nt.staged_schema_id, nstaged, "staged_schema_id")
    staged_schema_version = _run_string_column(nt.staged_schema_version, nstaged, "staged_schema_version")
    staged_origin = _run_string_column(nt.staged_origin, nstaged, "staged_origin")
    staged_source = _run_string_column(nt.staged_source_revision_id, nstaged, "staged_source_revision_id")
    staged_activity = _run_string_column(nt.staged_activity_id, nstaged, "staged_activity_id")
    staged_sw = _run_string_column(nt.staged_software_environment, nstaged, "staged_software_environment")
    staged_ctx = _run_string_column(nt.staged_execution_context, nstaged, "staged_execution_context")

    nsrefs = Int(nt.staged_ref_count)
    nsrefs >= 0 || throw(ArgumentError("negative staged_ref_count in AH5 run history"))
    sref_owner = _run_int_column(nt.staged_ref_owner, nsrefs, "staged_ref_owner")
    sref_name = _run_string_column(nt.staged_ref_name, nsrefs, "staged_ref_name")
    sref_object = _run_string_column(nt.staged_ref_object_id, nsrefs, "staged_ref_object_id")
    sref_revision = _run_string_column(nt.staged_ref_revision_id, nsrefs, "staged_ref_revision_id")
    for owner in sref_owner
        1 <= owner <= nstaged || throw(ArgumentError("staged ref owner index out of bounds"))
    end

    staged_values = StagedObject[]
    for owner in 1:nstaged
        refs = ArchiveReference[]
        for index in eachindex(sref_owner)
            sref_owner[index] == owner || continue
            push!(refs, ArchiveReference(
                Symbol(sref_name[index]),
                ObjectId(sref_object[index]);
                revision_id = isempty(sref_revision[index]) ? nothing : RevisionId(sref_revision[index]),
            ))
        end
        push!(staged_values, StagedObject(
            ObjectId(staged_object[owner]);
            content_id = isempty(staged_content[owner]) ? nothing : ContentId(staged_content[owner]),
            namespace = ArchiveNamespace(
                Symbol(staged_ns[owner]);
                package_uuid = staged_uuid[owner],
                display_name = staged_display[owner],
            ),
            kind = Symbol(staged_kind[owner]),
            schema = SchemaRef(
                Symbol(staged_schema_ns[owner]),
                staged_schema_id[owner],
                staged_schema_version[owner],
            ),
            origin = Symbol(staged_origin[owner]),
            source_revision_id = isempty(staged_source[owner]) ? nothing : RevisionId(staged_source[owner]),
            activity_id = isempty(staged_activity[owner]) ? nothing : ActivityId(staged_activity[owner]),
            provenance = ProvenanceRefs(;
                software_environment = isempty(staged_sw[owner]) ? nothing : SoftwareEnvironmentId(staged_sw[owner]),
                execution_context = isempty(staged_ctx[owner]) ? nothing : ExecutionContextId(staged_ctx[owner]),
            ),
            references = refs,
        ))
    end

    ncheck = Int(nt.checkpoint_count)
    ncheck >= 0 || throw(ArgumentError("negative checkpoint_count in AH5 run history"))
    checkpoint_object = _run_string_column(nt.checkpoint_object_id, ncheck, "checkpoint_object_id")
    checkpoint_content = _run_string_column(nt.checkpoint_content_id, ncheck, "checkpoint_content_id")
    checkpoint_revision = _run_string_column(nt.checkpoint_revision_id, ncheck, "checkpoint_revision_id")
    checkpoint_kind = _run_string_column(nt.checkpoint_kind, ncheck, "checkpoint_kind")
    restart_present = Bool(nt.restart_present)
    restart = nothing
    if restart_present
        checkpoints = CheckpointRef[]
        for index in 1:ncheck
            push!(checkpoints, CheckpointRef(
                ObjectId(checkpoint_object[index]);
                content_id = isempty(checkpoint_content[index]) ? nothing : ContentId(checkpoint_content[index]),
                revision_id = isempty(checkpoint_revision[index]) ? nothing : RevisionId(checkpoint_revision[index]),
                kind = Symbol(checkpoint_kind[index]),
            ))
        end
        restart_context = String(nt.restart_execution_context)
        restart_activity = String(nt.restart_from_activity_id)
        restart = RestartRequirement(;
            checkpoints = checkpoints,
            execution_context = isempty(restart_context) ? nothing : ExecutionContextId(restart_context),
            from_activity_id = isempty(restart_activity) ? nothing : ActivityId(restart_activity),
        )
    elseif ncheck != 0 || !isempty(String(nt.restart_execution_context)) ||
            !isempty(String(nt.restart_from_activity_id))
        throw(ArgumentError("restart metadata present while restart_present=false"))
    end

    plan = String(nt.plan_id)
    parent = String(nt.parent_run_id)
    revision = String(nt.revision_id)
    software = String(nt.software_environment)
    context = String(nt.execution_context)
    agent = String(nt.agent_id)
    return RunRecord(
        run_id;
        plan_id = isempty(plan) ? nothing : PlanId(plan),
        parent_run_id = isempty(parent) ? nothing : RunId(parent),
        revision_id = isempty(revision) ? nothing : RevisionId(revision),
        status = Symbol(nt.status),
        software_environment = isempty(software) ? nothing : SoftwareEnvironmentId(software),
        execution_context = isempty(context) ? nothing : ExecutionContextId(context),
        agent_id = isempty(agent) ? nothing : AgentId(agent),
        activities = activities,
        staged = staged_values,
        restart = restart,
    )
end

# ---------------------------------------------------------------------------
# Cross-layer validation
# ---------------------------------------------------------------------------

function _run_reference_resolves(graph::ArchiveGraph, externals, ref::ObjectRef)
    _reference_resolves(graph, ref) && return true
    return _match_external(externals, ref.object_id, nothing) !== nothing
end

function _validate_run_ref!(diagnostics, graph, externals, ref, code, message; context...)
    _run_reference_resolves(graph, externals, ref.target) && return diagnostics
    push!(diagnostics, error_diagnostic(
        code,
        message;
        object_id = ref.target.object_id.value,
        target_revision_id = ref.target.revision_id === nothing ? nothing : ref.target.revision_id.value,
        name = ref.name,
        context...,
    ))
    return diagnostics
end

function _validate_staged_identity!(diagnostics, staged::StagedObject, namespaces, schemas, run_id)
    proxy_revision = staged.source_revision_id === nothing ? RevisionId("__staged__") : staged.source_revision_id
    proxy = ArchiveObject(
        staged.object_id,
        proxy_revision;
        content_id = staged.content_id,
        namespace = staged.namespace,
        kind = staged.kind,
        schema = staged.schema,
        provenance = staged.provenance,
        references = staged.references,
    )
    _validate_archive_object!(diagnostics, proxy)
    _append_state_namespace_diagnostic!(diagnostics, proxy, namespaces)
    _append_state_schema_diagnostic!(diagnostics, proxy, schemas)
    return diagnostics
end

function _validate_run_history(
    state::ArchiveStateHistory,
    runs::Vector{RunRecord};
    externals = ExternalRequirement[],
    namespaces = NamespaceListing[],
    schemas = SchemaListing[],
)
    diagnostics = DiagnosticMessage[]
    reqs = _externals_vector(externals)
    graph = ArchiveGraph(
        state.objects;
        heads = state.heads,
        revisions = state.revisions,
        runs = runs,
    )

    # Reuse the existing authoritative run/revision/lifecycle/staging checks.
    _validate_history_records!(diagnostics, graph)

    for object in state.objects
        object.run_id === nothing && continue
        find_run(graph, object.run_id) !== nothing && continue
        push!(diagnostics, error_diagnostic(
            :missing_object_run,
            "object $(object.object_id.value) names unknown run $(object.run_id.value)";
            object_id = object.object_id.value,
            revision_id = object.revision_id.value,
            run_id = object.run_id.value,
        ))
    end

    for run in runs
        activity_ids = Set(activity.id.value for activity in run.activities)
        for activity in run.activities
            for ref in activity.used
                _validate_run_ref!(
                    diagnostics, graph, reqs, ref,
                    :missing_activity_object,
                    "activity $(activity.id.value) names unavailable used object $(ref.target.object_id.value)";
                    activity_id = activity.id.value,
                    run_id = run.id.value,
                    role = :used,
                )
            end
            for ref in activity.generated
                _validate_run_ref!(
                    diagnostics, graph, reqs, ref,
                    :missing_activity_object,
                    "activity $(activity.id.value) names unavailable generated object $(ref.target.object_id.value)";
                    activity_id = activity.id.value,
                    run_id = run.id.value,
                    role = :generated,
                )
            end
        end

        for staged in run.staged
            _validate_staged_identity!(diagnostics, staged, namespaces, schemas, run.id)
            if staged.activity_id !== nothing && !(staged.activity_id.value in activity_ids)
                push!(diagnostics, error_diagnostic(
                    :missing_staged_activity,
                    "staged object $(staged.object_id.value) names unknown activity $(staged.activity_id.value)";
                    run_id = run.id.value,
                    object_id = staged.object_id.value,
                    activity_id = staged.activity_id.value,
                ))
            end
            for ref in staged.references
                _validate_run_ref!(
                    diagnostics, graph, reqs, ref,
                    :missing_staged_reference,
                    "staged object $(staged.object_id.value) names unavailable object $(ref.target.object_id.value)";
                    run_id = run.id.value,
                    staged_object_id = staged.object_id.value,
                )
            end
        end

        restart = run.restart
        if restart !== nothing
            if restart.from_activity_id !== nothing && !(restart.from_activity_id.value in activity_ids)
                push!(diagnostics, error_diagnostic(
                    :missing_restart_activity,
                    "restart contract for run $(run.id.value) names unknown activity $(restart.from_activity_id.value)";
                    run_id = run.id.value,
                    activity_id = restart.from_activity_id.value,
                ))
            end
            for checkpoint in restart.checkpoints
                target = ObjectRef(checkpoint.object_id, checkpoint.revision_id)
                if !_run_reference_resolves(graph, reqs, target)
                    push!(diagnostics, error_diagnostic(
                        :missing_restart_checkpoint_object,
                        "restart checkpoint $(checkpoint.object_id.value) is unavailable";
                        run_id = run.id.value,
                        object_id = checkpoint.object_id.value,
                        revision_id = checkpoint.revision_id === nothing ? nothing : checkpoint.revision_id.value,
                    ))
                    continue
                end
                if checkpoint.revision_id !== nothing
                    object = find_object(graph, checkpoint.object_id, checkpoint.revision_id)
                    if object !== nothing && checkpoint.content_id !== nothing &&
                            object.content_id !== nothing && checkpoint.content_id != object.content_id
                        push!(diagnostics, error_diagnostic(
                            :restart_checkpoint_content_mismatch,
                            "restart checkpoint content does not match archived object";
                            run_id = run.id.value,
                            object_id = checkpoint.object_id.value,
                            revision_id = checkpoint.revision_id.value,
                            checkpoint_content_id = checkpoint.content_id.value,
                            object_content_id = object.content_id.value,
                        ))
                    end
                end
            end
        end
    end
    return diagnostics
end

# ---------------------------------------------------------------------------
# Physical AH5 extension and forensic view
# ---------------------------------------------------------------------------

function _write_run_history!(file, history::ArchiveRunHistory)
    _write_indexed!(file, AH5_RUN_HISTORY_KEY, history.runs, _run_record_storage)
    return file
end

function _read_run_history(file)
    runs = _read_indexed(RunRecord, file, AH5_RUN_HISTORY_KEY, _restore_run_record)
    return ArchiveRunHistory(runs)
end

"""
    write_run_archive(path, graph; kwargs...)

Create an AH5 archive with both authoritative state-history and run/activity
provenance records. Event/write/log provenance remains a later extension.
"""
function write_run_archive(
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
    runs = RunRecord[ordered_runs(graph)...]
    ns_listings = list_namespaces(graph, namespaces)
    schema_listings = schemas === nothing ? SchemaListing[] : list_schemas(schemas)
    diagnostics = _validate_state_history(
        state;
        externals = reqs,
        namespaces = ns_listings,
        schemas = schema_listings,
    )
    append!(diagnostics, _validate_run_history(
        state,
        runs;
        externals = reqs,
        namespaces = ns_listings,
        schemas = schema_listings,
    ))
    any(diagnostic -> diagnostic.severity === :error, diagnostics) && throw(ArgumentError(
        "refusing to persist invalid run history: $(Tuple(d.code for d in diagnostics if d.severity === :error))",
    ))

    profile_record = _profile_with_run_history(profile, kwargs)
    _refuse_run_history_root_collision(profile_record)
    created = false
    try
        write_state_archive(
            path,
            graph;
            namespaces = namespaces,
            schemas = schemas,
            externals = reqs,
            profile = profile_record,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_run_history!(file, ArchiveRunHistory(runs))
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end
    return path
end

function _empty_run_history_inspection(path, identified, declared, state, externals, diagnostics)
    valid = identified && !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveRunHistoryInspection(
        String(path), identified, declared, valid, state, RunRecord[],
        ExternalRequirement[externals...], diagnostics,
    )
end

"""
    inspect_archive(path, ArchiveRunHistory) -> ArchiveRunHistoryInspection

Forensically reconstruct state plus authoritative run/activity/restart
provenance. The existing revision `inspect` and readiness contracts are reused.
"""
function inspect_archive(path::AbstractString, ::Type{ArchiveRunHistory})
    state_view = inspect_archive(path, ArchiveStateHistory)
    diagnostics = copy(state_view.diagnostics)
    if !state_view.identified
        return _empty_run_history_inspection(
            path, false, false, nothing, state_view.externals, diagnostics,
        )
    end
    if !isvalid(state_view)
        return _empty_run_history_inspection(
            path, true, false, nothing, state_view.externals, diagnostics,
        )
    end

    core = inspect_archive(path)
    declared = core.profile !== nothing && AH5_RUN_HISTORY_FEATURE in core.profile.features
    declared || return _empty_run_history_inspection(
        path, true, false, state_view.state, state_view.externals, diagnostics,
    )
    state_view.state === nothing && push!(diagnostics, error_diagnostic(
        :run_history_state_missing,
        "AH5 run-history feature requires authoritative state-history records",
    ))
    any(d -> d.severity === :error, diagnostics) && return _empty_run_history_inspection(
        path, true, true, nothing, state_view.externals, diagnostics,
    )

    history = nothing
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            _jld2_get(file, _count_key(AH5_RUN_HISTORY_KEY)) === nothing && throw(ArgumentError(
                "AH5 profile declares run history but $(AH5_RUN_HISTORY_KEY)/count is missing",
            ))
            history = _read_run_history(file)
        end
        append!(diagnostics, _validate_run_history(
            state_view.state,
            history.runs;
            externals = state_view.externals,
            namespaces = core.namespaces,
            schemas = core.schemas,
        ))
        core.history.runs == length(history.runs) || push!(diagnostics, error_diagnostic(
            :run_history_summary_mismatch,
            "run-history record count does not match AH5 history summary";
            summary = core.history.runs,
            records = length(history.runs),
        ))
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_run_history,
            "AH5 run-history metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        history = nothing
    end

    valid = history !== nothing && !any(d -> d.severity === :error, diagnostics)
    return ArchiveRunHistoryInspection(
        String(path),
        true,
        true,
        valid,
        valid ? state_view.state : nothing,
        valid ? history.runs : RunRecord[],
        copy(state_view.externals),
        diagnostics,
    )
end

"""
    reconstruct_graph(view::ArchiveRunHistoryInspection) -> ArchiveGraph

Return the exact payload-free state + run graph represented by a valid forensic
view. Events, write transactions, and log streams are empty by design in this
slice.
"""
function reconstruct_graph(view::ArchiveRunHistoryInspection)
    isvalid(view) || throw(ArgumentError("cannot reconstruct graph from invalid AH5 run history"))
    view.state === nothing && throw(ArgumentError("AH5 run history has no state graph"))
    return ArchiveGraph(
        view.state.objects;
        heads = view.state.heads,
        revisions = view.state.revisions,
        runs = view.runs,
    )
end

function inspect(view::ArchiveRunHistoryInspection, revision_id::RevisionId)
    graph = reconstruct_graph(view)
    return inspect(graph, revision_id; externals = view.externals)
end

function validate(view::ArchiveRunHistoryInspection)
    return ValidationReport(
        :archive_run_history,
        view.valid,
        copy(view.diagnostics),
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            runs = length(view.runs),
        ),
    )
end

function report(view::ArchiveRunHistoryInspection)
    return ObjectReport(
        :archive_run_history,
        view.feature_declared ?
            "AH5 run history with $(length(view.runs)) runs." :
            "AH5 archive has no run-history extension.",
        to_namedtuple(view),
        copy(view.diagnostics),
        ArtifactRef[],
    )
end

to_namedtuple(history::ArchiveRunHistory) = (
    runs = Tuple(_run_record_storage(run) for run in history.runs),
)

to_namedtuple(view::ArchiveRunHistoryInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    runs = Tuple(_run_record_storage(run) for run in view.runs),
    externals = Tuple(to_namedtuple(req) for req in view.externals),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
