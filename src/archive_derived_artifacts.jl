# ---------------------------------------------------------------------------
# Optional derived/debug artifact provenance persistence in AH5 (#32)
#
# Payload-free records above authoritative state + run history. Domain
# packages keep scientific payload types. Large products are referenced
# through ArtifactRef; bytes are not embedded here.
# ---------------------------------------------------------------------------

const AH5_DERIVED_ARTIFACTS_FEATURE = :derived_artifact_records
const AH5_DERIVED_ARTIFACTS_KEY = "episteme/derived_artifacts"

"""
    ArchiveDerivedHistory

Payload-free derived, debug, visualization, and annotation provenance.
Authoritative state and producing run/activity records remain in the earlier
AH5 history layers. Scientific payload bytes are not stored here.
"""
struct ArchiveDerivedHistory
    artifacts::Vector{DerivedArtifactRecord}

    function ArchiveDerivedHistory(artifacts = DerivedArtifactRecord[])
        return new(_derived_artifact_vector(artifacts))
    end
end

"""
    ArchiveDerivedHistoryInspection <: AbstractValidationReport

Forensic `plain=true` view of derived-artifact provenance reconstructed with
state and run history. `artifacts` is empty when the optional feature is
absent or when records fail structural validation.
"""
struct ArchiveDerivedHistoryInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    state::Union{Nothing,ArchiveStateHistory}
    runs::Vector{RunRecord}
    artifacts::Vector{DerivedArtifactRecord}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveDerivedHistoryInspection) = view.valid

function _derived_history_profile(profile::ArchiveProfile)
    AH5_DERIVED_ARTIFACTS_FEATURE in profile.required_features && throw(ArgumentError(
        "derived-artifact records are an optional AH5 v1 feature and must not be declared required",
    ))
    features = Symbol[profile.features...]
    AH5_DERIVED_ARTIFACTS_FEATURE in features || push!(features, AH5_DERIVED_ARTIFACTS_FEATURE)
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

function _profile_with_derived_artifacts(profile, kwargs)
    if profile === nothing
        return _derived_history_profile(ArchiveProfile(; kwargs...))
    end
    isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile))",
    ))
    return _derived_history_profile(profile)
end

function _refuse_derived_history_root_collision(profile::ArchiveProfile)
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
        (:software_environments, AH5_SOFTWARE_ENVIRONMENTS_KEY),
        (:execution_contexts, AH5_EXECUTION_CONTEXTS_KEY),
        (:capsule, AH5_CAPSULE_KEY),
    )
        _path_overlap(root, AH5_DERIVED_ARTIFACTS_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional derived-artifact root $(repr(AH5_DERIVED_ARTIFACTS_KEY))",
        ))
    end
    return profile
end

_derived_optional_text(value) = value === nothing ? "" : value.value

# Plain JLD2 reads can omit zero-size tuple fields. Persist portable storage
# sequences as vectors so empty records/tuples retain their structure.
_derived_jld2_storage(value) = value
_derived_jld2_storage(value::Tuple) = Any[_derived_jld2_storage(item) for item in value]
_derived_jld2_storage(value::NamedTuple) =
    (; (key => _derived_jld2_storage(item) for (key, item) in pairs(value))...)

function _derived_capture_portable(value, field)
    diagnostics = DiagnosticMessage[]
    captured = _capture_value!(diagnostics, value, "<derived-artifact>", field)
    return captured, captured !== :__unsupported__, diagnostics
end

function _derived_secret_diagnostic!(diagnostics, value, record, field)
    if value isa NamedTuple
        for name in keys(value)
            if _looks_like_secret_name(String(name))
                push!(diagnostics, error_diagnostic(
                    :credential_like_content,
                    "derived artifact key :$name looks like a secret name";
                    object_id = record.object_id.value,
                    revision_id = record.revision_id.value,
                    field = field,
                    key = name,
                ))
            end
            _derived_secret_diagnostic!(diagnostics, value[name], record, string(field, ".", name))
        end
    elseif value isa PortableDict
        for (key, item) in value.entries
            if (key isa Symbol || key isa AbstractString) && _looks_like_secret_name(String(key))
                push!(diagnostics, error_diagnostic(
                    :credential_like_content,
                    "derived artifact dictionary key $(repr(key)) looks like a secret name";
                    object_id = record.object_id.value,
                    revision_id = record.revision_id.value,
                    field = field,
                    key = String(key),
                ))
            end
            _derived_secret_diagnostic!(diagnostics, item, record, field)
        end
    elseif value isa PortableEncoded
        _derived_secret_diagnostic!(diagnostics, value.data, record, field)
    elseif value isa Tuple || value isa AbstractArray
        for item in value
            _derived_secret_diagnostic!(diagnostics, item, record, field)
        end
    elseif value isa AbstractString
        _looks_like_secret_value(value) || return diagnostics
        push!(diagnostics, error_diagnostic(
            :credential_like_content,
            "credential-like content is not allowed in persisted derived artifacts";
            object_id = record.object_id.value,
            revision_id = record.revision_id.value,
            field = field,
        ))
    end
    return diagnostics
end

function _derived_portable_storage(value, field, record)
    captured, ok, diagnostics = _derived_capture_portable(value, field)
    ok && isempty(diagnostics) || throw(ArgumentError(
        "derived artifact $field is not portable: $(Tuple(d.code for d in diagnostics))",
    ))
    secret_diagnostics = DiagnosticMessage[]
    _derived_secret_diagnostic!(secret_diagnostics, captured, record, field)
    isempty(secret_diagnostics) || throw(ArgumentError(
        "derived artifact $field contains credential-like content",
    ))
    return _derived_jld2_storage(_portable_value_namedtuple(captured))
end

function _restore_derived_portable(value, ::Type{T}, name::AbstractString) where {T}
    restored = _value_from_namedtuple(value)
    restored isa T || throw(ArgumentError(
        "AH5 derived-artifact $name must restore as $T, got $(typeof(restored))",
    ))
    return restored
end

function _validate_derived_portable!(diagnostics, record::DerivedArtifactRecord)
    for (field, value) in (
        (:parameters, record.parameters),
        (:value_shape, record.value_shape),
    )
        captured, ok, payload_diagnostics = _derived_capture_portable(value, field)
        append!(diagnostics, payload_diagnostics)
        ok || continue
        _derived_secret_diagnostic!(diagnostics, captured, record, field)
    end
    _derived_secret_diagnostic!(diagnostics, record.units, record, :units)
    for diagnostic in record.diagnostics
        _derived_secret_diagnostic!(diagnostics, diagnostic.message, record, :diagnostics)
        captured, ok, payload_diagnostics = _derived_capture_portable(
            diagnostic.context,
            :diagnostics,
        )
        append!(diagnostics, payload_diagnostics)
        ok || continue
        _derived_secret_diagnostic!(diagnostics, captured, record, :diagnostics)
    end
    record.artifact === nothing && return diagnostics
    artifact = record.artifact
    for (field, value) in (
        (:artifact_path, artifact.path),
        (:artifact_uri, artifact.uri),
        (:artifact_description, artifact.description),
        (:artifact_metadata, artifact.metadata),
    )
        value === nothing && continue
        captured, ok, payload_diagnostics = _derived_capture_portable(value, field)
        append!(diagnostics, payload_diagnostics)
        ok || continue
        _derived_secret_diagnostic!(diagnostics, captured, record, field)
    end
    return diagnostics
end

function _derived_record_storage(record::DerivedArtifactRecord)
    schema_ns, schema_id, schema_version = _optional_schema_parts(record.schema)
    artifact_kind, artifact_path, artifact_uri, artifact_description =
        record.artifact === nothing ? ("", "", "", "") :
        (
            String(record.artifact.kind),
            record.artifact.path === nothing ? "" : record.artifact.path,
            record.artifact.uri === nothing ? "" : record.artifact.uri,
            record.artifact.description,
        )
    artifact_metadata = record.artifact === nothing ? (;) : record.artifact.metadata
    return (
        object_id = record.object_id.value,
        revision_id = record.revision_id.value,
        role = String(record.role),
        input_object_ids = String[input.object_id.value for input in record.inputs],
        input_revision_ids = String[input.revision_id.value for input in record.inputs],
        input_content_ids = String[_derived_optional_text(input.content_id) for input in record.inputs],
        run_id = record.run_id.value,
        activity_id = record.activity_id.value,
        operation = String(record.operation),
        parameters = _derived_portable_storage(record.parameters, :parameters, record),
        schema_namespace = schema_ns,
        schema_id = schema_id,
        schema_version = schema_version,
        software_environment = _derived_optional_text(record.software_environment),
        retention = String(record.retention),
        status = String(record.status),
        diagnostic_severities = String[String(d.severity) for d in record.diagnostics],
        diagnostic_codes = String[String(d.code) for d in record.diagnostics],
        diagnostic_messages = String[d.message for d in record.diagnostics],
        diagnostic_contexts = Any[
            _derived_portable_storage(d.context, :diagnostics, record) for d in record.diagnostics
        ],
        units = record.units,
        value_shape = _derived_portable_storage(record.value_shape, :value_shape, record),
        artifact_kind = artifact_kind,
        artifact_path = artifact_path,
        artifact_uri = artifact_uri,
        artifact_description = artifact_description,
        artifact_metadata = _derived_portable_storage(
            artifact_metadata,
            :artifact_metadata,
            record,
        ),
    )
end

function _restore_derived_artifact(artifact_kind, path, uri, description, metadata)
    values = (
        String(artifact_kind),
        String(path),
        String(uri),
        String(description),
    )
    metadata_nt = _restore_derived_portable(metadata, NamedTuple, "artifact metadata")
    if isempty(values[1])
        all(isempty, values) && isempty(keys(metadata_nt)) || throw(ArgumentError(
            "artifact fields present without artifact kind",
        ))
        return nothing
    end
    return ArtifactRef(
        Symbol(values[1]),
        isempty(values[2]) ? nothing : values[2],
        isempty(values[3]) ? nothing : values[3],
        values[4],
        metadata_nt,
    )
end

function _restore_derived_record(nt)
    object_ids = _string_vec(nt.input_object_ids)
    revision_ids = _string_vec(nt.input_revision_ids)
    content_ids = _string_vec(nt.input_content_ids)
    length(object_ids) == length(revision_ids) == length(content_ids) || throw(ArgumentError(
        "AH5 derived-artifact input columns have inconsistent lengths",
    ))
    inputs = DerivedInputRef[]
    for index in eachindex(object_ids)
        push!(inputs, DerivedInputRef(
            ObjectId(object_ids[index]),
            RevisionId(revision_ids[index]);
            content_id = isempty(content_ids[index]) ? nothing : ContentId(content_ids[index]),
        ))
    end

    severities = _string_vec(nt.diagnostic_severities)
    codes = _string_vec(nt.diagnostic_codes)
    messages = _string_vec(nt.diagnostic_messages)
    contexts = nt.diagnostic_contexts === nothing ? Any[] : Any[nt.diagnostic_contexts...]
    length(severities) == length(codes) == length(messages) == length(contexts) ||
        throw(ArgumentError("AH5 derived-artifact diagnostic columns have inconsistent lengths"))
    diagnostics = DiagnosticMessage[]
    for index in eachindex(severities)
        push!(diagnostics, DiagnosticMessage(
            Symbol(severities[index]),
            Symbol(codes[index]),
            String(messages[index]),
            _restore_derived_portable(contexts[index], NamedTuple, "diagnostic context"),
        ))
    end

    software = String(nt.software_environment)
    return DerivedArtifactRecord(
        ObjectId(String(nt.object_id)),
        RevisionId(String(nt.revision_id)),
        Symbol(nt.role);
        inputs = inputs,
        run_id = RunId(String(nt.run_id)),
        activity_id = ActivityId(String(nt.activity_id)),
        operation = Symbol(nt.operation),
        parameters = _restore_derived_portable(nt.parameters, NamedTuple, "parameters"),
        schema = _restore_optional_schema(nt.schema_namespace, nt.schema_id, nt.schema_version),
        software_environment = isempty(software) ? nothing : SoftwareEnvironmentId(software),
        retention = Symbol(nt.retention),
        status = Symbol(nt.status),
        diagnostics = diagnostics,
        units = String(nt.units),
        value_shape = _restore_derived_portable(nt.value_shape, Tuple, "value_shape"),
        artifact = _restore_derived_artifact(
            nt.artifact_kind,
            nt.artifact_path,
            nt.artifact_uri,
            nt.artifact_description,
            nt.artifact_metadata,
        ),
    )
end

function _derived_history_graph(state::ArchiveStateHistory, runs)
    return ArchiveGraph(
        state.objects;
        heads = state.heads,
        revisions = state.revisions,
        runs = runs,
    )
end

function _validate_derived_history(
    state::ArchiveStateHistory,
    runs::Vector{RunRecord},
    history::ArchiveDerivedHistory;
    externals = ExternalRequirement[],
)
    diagnostics = DiagnosticMessage[]
    graph = _derived_history_graph(state, runs)
    report = validate(history.artifacts, graph)
    append!(diagnostics, report.diagnostics)
    for record in history.artifacts
        _validate_derived_portable!(diagnostics, record)
    end
    return diagnostics
end

function _write_derived_history!(file, history::ArchiveDerivedHistory)
    _write_indexed!(
        file,
        AH5_DERIVED_ARTIFACTS_KEY,
        history.artifacts,
        _derived_record_storage,
    )
    return file
end

function _read_derived_history(file)
    artifacts = _read_indexed(
        DerivedArtifactRecord,
        file,
        AH5_DERIVED_ARTIFACTS_KEY,
        _restore_derived_record,
    )
    return ArchiveDerivedHistory(artifacts)
end

function _derived_history_counts_exist(file)
    return _jld2_get(file, _count_key(AH5_DERIVED_ARTIFACTS_KEY)) !== nothing
end

function _empty_derived_history_inspection(
    path,
    identified,
    declared,
    state,
    runs,
    externals,
    diagnostics,
)
    valid = identified && !any(d -> d.severity === :error, diagnostics)
    return ArchiveDerivedHistoryInspection(
        String(path),
        identified,
        declared,
        valid,
        state,
        RunRecord[runs...],
        DerivedArtifactRecord[],
        ExternalRequirement[externals...],
        diagnostics,
    )
end

"""
    reconstruct_graph(view::ArchiveDerivedHistoryInspection) -> ArchiveGraph

Reconstruct the payload-free state + run graph used to validate derived
records. Derived provenance stays on the inspection view rather than on
[`ArchiveGraph`](@ref).
"""
function reconstruct_graph(view::ArchiveDerivedHistoryInspection)
    isvalid(view) || throw(ArgumentError(
        "cannot reconstruct graph from invalid AH5 derived-artifact history",
    ))
    view.state === nothing && throw(ArgumentError(
        "AH5 derived-artifact history has no state graph",
    ))
    return _derived_history_graph(view.state, view.runs)
end

function inspect(view::ArchiveDerivedHistoryInspection, revision_id::RevisionId)
    return inspect(reconstruct_graph(view), revision_id; externals = view.externals)
end

function derived_ancestry(record::DerivedArtifactRecord, view::ArchiveDerivedHistoryInspection)
    isvalid(view) || throw(ArgumentError(
        "cannot walk derived ancestry from invalid AH5 derived-artifact history",
    ))
    return derived_ancestry(record, view.artifacts)
end

function validate(view::ArchiveDerivedHistoryInspection)
    return ValidationReport(
        :archive_derived_artifacts,
        view.valid,
        copy(view.diagnostics),
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            artifacts = length(view.artifacts),
        ),
    )
end

function report(view::ArchiveDerivedHistoryInspection)
    return ObjectReport(
        :archive_derived_artifacts,
        view.feature_declared ?
            "AH5 derived-artifact history with $(length(view.artifacts)) records." :
            "AH5 archive has no derived-artifact extension.",
        to_namedtuple(view),
        copy(view.diagnostics),
        ArtifactRef[],
    )
end

to_namedtuple(history::ArchiveDerivedHistory) = (
    artifacts = Tuple(to_namedtuple(record) for record in history.artifacts),
)

to_namedtuple(view::ArchiveDerivedHistoryInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    artifacts = Tuple(to_namedtuple(record) for record in view.artifacts),
    externals = Tuple(to_namedtuple(req) for req in view.externals),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
