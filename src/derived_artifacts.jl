# ---------------------------------------------------------------------------
# Derived-artifact and debug provenance (#105 / parent #32)
#
# Shared ancestry/retention envelope for postprocessed, diagnostic, and
# debug products. Domain packages keep payload meaning. AH5 persistence
# of these records is the optional derived-artifact history layer.
# ---------------------------------------------------------------------------

const ARTIFACT_ROLES = (
    :primary,
    :checkpoint,
    :derived,
    :debug,
    :visualization,
    :annotation,
)

const ARTIFACT_RETENTION = (
    :ephemeral,
    :debug,
    :forensic,
    :pinned,
    :replaceable,
    :visualization,
)

const ARTIFACT_STATUSES = (:complete, :failed, :incomplete)

"""
    DerivedInputRef(object_id, revision_id; content_id=nothing)

Exact scientific input to a derived product. The revision is required so
later analysis cannot silently retarget a movable head. When the archived
envelope has a `ContentId`, that identity is required here as well.
"""
struct DerivedInputRef
    object_id::ObjectId
    revision_id::RevisionId
    content_id::Union{Nothing,ContentId}
end

function DerivedInputRef(
    object_id::ObjectId,
    revision_id::RevisionId;
    content_id = nothing,
)
    return DerivedInputRef(
        object_id,
        revision_id,
        _optional_id(ContentId, content_id),
    )
end

"""
    DerivedArtifactRecord(object_id, revision_id, role; kwargs...)

Provenance envelope for one archived product version. It does not store
the scientific payload. Recomputation appends a new record rather than
mutating this one.
"""
struct DerivedArtifactRecord
    object_id::ObjectId
    revision_id::RevisionId
    role::Symbol
    inputs::Vector{DerivedInputRef}
    run_id::RunId
    activity_id::ActivityId
    operation::Symbol
    parameters::NamedTuple
    schema::Union{Nothing,SchemaRef}
    software_environment::Union{Nothing,SoftwareEnvironmentId}
    retention::Symbol
    status::Symbol
    diagnostics::Vector{DiagnosticMessage}
    units::String
    value_shape::Tuple
    artifact::Union{Nothing,ArtifactRef}
end

function DerivedArtifactRecord(
    object_id::ObjectId,
    revision_id::RevisionId,
    role::Symbol;
    inputs = DerivedInputRef[],
    run_id::RunId,
    activity_id::ActivityId,
    operation::Symbol,
    parameters::NamedTuple = (;),
    schema = nothing,
    software_environment = nothing,
    retention::Symbol = :forensic,
    status::Symbol = :complete,
    diagnostics = DiagnosticMessage[],
    units::AbstractString = "",
    value_shape = (),
    artifact = nothing,
)
    role in ARTIFACT_ROLES || throw(ArgumentError(
        "artifact role must be one of $ARTIFACT_ROLES, got :$role",
    ))
    retention in ARTIFACT_RETENTION || throw(ArgumentError(
        "artifact retention must be one of $ARTIFACT_RETENTION, got :$retention",
    ))
    status in ARTIFACT_STATUSES || throw(ArgumentError(
        "artifact status must be one of $ARTIFACT_STATUSES, got :$status",
    ))
    schema === nothing || schema isa SchemaRef || throw(ArgumentError(
        "schema must be SchemaRef or nothing, got $(typeof(schema))",
    ))
    artifact === nothing || artifact isa ArtifactRef || throw(ArgumentError(
        "artifact must be ArtifactRef or nothing, got $(typeof(artifact))",
    ))
    return DerivedArtifactRecord(
        object_id,
        revision_id,
        role,
        _typed_vector(DerivedInputRef, inputs, "derived inputs"),
        run_id,
        activity_id,
        operation,
        parameters,
        schema,
        _optional_id(SoftwareEnvironmentId, software_environment),
        retention,
        status,
        DiagnosticMessage[diagnostics...],
        String(units),
        Tuple(value_shape),
        artifact,
    )
end

function _derived_identity_key(object_id::ObjectId, revision_id::RevisionId)
    return (object_id.value, revision_id.value)
end

_derived_identity_key(record::DerivedArtifactRecord) =
    _derived_identity_key(record.object_id, record.revision_id)

_derived_identity_key(input::DerivedInputRef) =
    _derived_identity_key(input.object_id, input.revision_id)

function _derived_artifact_vector(values)
    return _typed_vector(DerivedArtifactRecord, values, "derived artifact records")
end

function _match_derived_artifact(artifacts, object::ArchiveObject)
    matches = DerivedArtifactRecord[
        record for record in artifacts
        if record.object_id == object.object_id && record.revision_id == object.revision_id
    ]
    isempty(matches) && return nothing
    return first(matches)
end

function _keep_derived_artifact(record::DerivedArtifactRecord, policy)
    record.retention === :pinned && return true
    record.retention === :forensic && return policy.keep_forensic_logs
    return policy.keep_debug_logs
end

function _derived_purge_class(record::DerivedArtifactRecord)
    record.retention === :visualization && return :purgeable_visualization
    record.retention === :replaceable && return :replaceable
    return :purgeable_debug
end

function _find_activity(run::RunRecord, activity_id::ActivityId)
    for activity in run.activities
        activity.id == activity_id && return activity
    end
    return nothing
end

function _derived_index(artifacts)
    index = Dict{Tuple{String,String},DerivedArtifactRecord}()
    for record in artifacts
        index[_derived_identity_key(record)] = record
    end
    return index
end

function _walk_derived_ancestry!(
    record::DerivedArtifactRecord,
    index,
    visiting,
    seen,
    diagnostics,
)
    key = _derived_identity_key(record)
    if key in visiting
        push!(diagnostics, error_diagnostic(
            :derived_ancestry_cycle,
            "derived artifact $(record.object_id.value) @ $(record.revision_id.value) has a cyclic ancestry";
            object_id = record.object_id.value,
            revision_id = record.revision_id.value,
            role = record.role,
        ))
        return DerivedArtifactRecord[]
    end
    key in seen && return DerivedArtifactRecord[]
    push!(visiting, key)
    ancestors = DerivedArtifactRecord[]
    for input in record.inputs
        child = get(index, _derived_identity_key(input), nothing)
        child === nothing && continue
        append!(ancestors, _walk_derived_ancestry!(child, index, visiting, seen, diagnostics))
        push!(ancestors, child)
    end
    delete!(visiting, key)
    push!(seen, key)
    return ancestors
end

"""
    derived_ancestry(record, artifacts) -> Vector{DerivedArtifactRecord}

Walk derived-from-derived inputs in stable order. Cycles are reported by
[`validate`](@ref) rather than being traversed infinitely.
"""
function derived_ancestry(record::DerivedArtifactRecord, artifacts)
    records = _derived_artifact_vector(artifacts)
    diagnostics = DiagnosticMessage[]
    ancestors = _walk_derived_ancestry!(
        record,
        _derived_index(records),
        Set{Tuple{String,String}}(),
        Set{Tuple{String,String}}(),
        diagnostics,
    )
    any(d -> d.code === :derived_ancestry_cycle, diagnostics) && return DerivedArtifactRecord[]
    unique_ancestors = DerivedArtifactRecord[]
    seen = Set{Tuple{String,String}}()
    for ancestor in ancestors
        key = _derived_identity_key(ancestor)
        key in seen && continue
        push!(seen, key)
        push!(unique_ancestors, ancestor)
    end
    return unique_ancestors
end

function _validate_derived_artifact!(diagnostics, record::DerivedArtifactRecord, graph)
    object = find_object(graph, record.object_id, record.revision_id)
    if object === nothing
        push!(diagnostics, error_diagnostic(
            :dangling_derived_artifact,
            "derived artifact $(record.object_id.value) @ $(record.revision_id.value) has no envelope object";
            object_id = record.object_id.value,
            revision_id = record.revision_id.value,
            role = record.role,
        ))
    elseif record.schema !== nothing && object.schema != record.schema
        push!(diagnostics, error_diagnostic(
            :derived_schema_mismatch,
            "derived artifact schema does not match envelope schema $(schema_kind(object.schema))";
            object_id = record.object_id.value,
            revision_id = record.revision_id.value,
        ))
    end

    run = find_run(graph, record.run_id)
    if run === nothing
        push!(diagnostics, error_diagnostic(
            :dangling_derived_run,
            "derived artifact $(record.object_id.value) names missing run $(record.run_id.value)";
            object_id = record.object_id.value,
            run_id = record.run_id.value,
        ))
    else
        activity = _find_activity(run, record.activity_id)
        if activity === nothing
            push!(diagnostics, error_diagnostic(
                :dangling_derived_activity,
                "derived artifact $(record.object_id.value) names missing activity $(record.activity_id.value)";
                object_id = record.object_id.value,
                run_id = record.run_id.value,
                activity_id = record.activity_id.value,
            ))
        elseif activity.operation != record.operation
            push!(diagnostics, error_diagnostic(
                :derived_operation_mismatch,
                "derived artifact operation :$(record.operation) does not match activity :$(activity.operation)";
                object_id = record.object_id.value,
                activity_id = record.activity_id.value,
                operation = record.operation,
                activity_operation = activity.operation,
            ))
        end
    end

    for input in record.inputs
        target = find_object(graph, input.object_id, input.revision_id)
        if target === nothing
            push!(diagnostics, error_diagnostic(
                :dangling_derived_input,
                "derived artifact $(record.object_id.value) input $(input.object_id.value) @ $(input.revision_id.value) is missing";
                object_id = record.object_id.value,
                input_object_id = input.object_id.value,
                input_revision_id = input.revision_id.value,
            ))
            continue
        end
        if target.content_id !== nothing && input.content_id === nothing
            push!(diagnostics, error_diagnostic(
                :missing_derived_input_content_id,
                "derived artifact $(record.object_id.value) input $(input.object_id.value) omits archived ContentId";
                object_id = record.object_id.value,
                input_object_id = input.object_id.value,
                input_revision_id = input.revision_id.value,
                envelope_content_id = target.content_id.value,
            ))
        elseif input.content_id !== nothing && target.content_id === nothing
            push!(diagnostics, error_diagnostic(
                :derived_input_content_mismatch,
                "derived input ContentId does not match archived envelope $(input.object_id.value)";
                object_id = record.object_id.value,
                input_object_id = input.object_id.value,
                declared_content_id = input.content_id.value,
                envelope_content_id = nothing,
            ))
        elseif input.content_id !== nothing && input.content_id != target.content_id
            push!(diagnostics, error_diagnostic(
                :derived_input_content_mismatch,
                "derived input ContentId does not match archived envelope $(input.object_id.value)";
                object_id = record.object_id.value,
                input_object_id = input.object_id.value,
                declared_content_id = input.content_id.value,
                envelope_content_id = target.content_id.value,
            ))
        end
    end
    return diagnostics
end

function validate(record::DerivedArtifactRecord, graph::ArchiveGraph)
    diagnostics = DiagnosticMessage[]
    _validate_derived_artifact!(diagnostics, record, graph)
    _walk_derived_ancestry!(
        record,
        _derived_index(DerivedArtifactRecord[record]),
        Set{Tuple{String,String}}(),
        Set{Tuple{String,String}}(),
        diagnostics,
    )
    return ValidationReport(
        :derived_artifact,
        !any(d -> d.severity === :error, diagnostics),
        diagnostics,
        (;
            object_id = record.object_id.value,
            revision_id = record.revision_id.value,
            role = record.role,
            retention = record.retention,
            status = record.status,
        ),
    )
end

function validate(artifacts, graph::ArchiveGraph)
    records = _derived_artifact_vector(artifacts)
    diagnostics = DiagnosticMessage[]
    seen = Dict{Tuple{String,String},DerivedArtifactRecord}()
    for record in records
        key = _derived_identity_key(record)
        if haskey(seen, key)
            push!(diagnostics, error_diagnostic(
                :duplicate_derived_artifact,
                "duplicate derived provenance for $(record.object_id.value) @ $(record.revision_id.value)";
                object_id = record.object_id.value,
                revision_id = record.revision_id.value,
            ))
        else
            seen[key] = record
        end
        _validate_derived_artifact!(diagnostics, record, graph)
    end
    index = _derived_index(records)
    visiting = Set{Tuple{String,String}}()
    walked = Set{Tuple{String,String}}()
    for record in records
        _walk_derived_ancestry!(record, index, visiting, walked, diagnostics)
    end
    return ValidationReport(
        :derived_artifacts,
        !any(d -> d.severity === :error, diagnostics),
        diagnostics,
        (; artifacts = length(records)),
    )
end

function report(record::DerivedArtifactRecord)
    input_count = length(record.inputs)
    return ObjectReport(
        :derived_artifact,
        "Artifact $(record.object_id.value) is a :$(record.role) product of :$(record.operation) from $input_count input(s).",
        to_namedtuple(record),
        copy(record.diagnostics),
        record.artifact === nothing ? ArtifactRef[] : ArtifactRef[record.artifact],
    )
end

to_namedtuple(input::DerivedInputRef) = (
    object_id = input.object_id.value,
    revision_id = input.revision_id.value,
    content_id = input.content_id === nothing ? nothing : input.content_id.value,
)

to_namedtuple(record::DerivedArtifactRecord) = (
    object_id = record.object_id.value,
    revision_id = record.revision_id.value,
    role = record.role,
    inputs = Tuple(to_namedtuple.(record.inputs)),
    run_id = record.run_id.value,
    activity_id = record.activity_id.value,
    operation = record.operation,
    parameters = record.parameters,
    schema = record.schema === nothing ? nothing : to_namedtuple(record.schema),
    software_environment = record.software_environment === nothing ? nothing :
        record.software_environment.value,
    retention = record.retention,
    status = record.status,
    diagnostics = Tuple(to_namedtuple.(record.diagnostics)),
    units = record.units,
    value_shape = record.value_shape,
    artifact = record.artifact === nothing ? nothing : to_namedtuple(record.artifact),
)
