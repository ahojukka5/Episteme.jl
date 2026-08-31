# ---------------------------------------------------------------------------
# Optional event/write/log provenance persistence in AH5 (#85 / epic #24)
# ---------------------------------------------------------------------------

const AH5_EVENT_HISTORY_FEATURE = :event_history_records
const AH5_EVENT_HISTORY_KEY = "episteme/event_history"

"""
    ArchiveEventHistory

Remaining generic provenance metadata above state + run history. Raw log bytes
and scientific payload bytes are deliberately not stored here.
"""
struct ArchiveEventHistory
    events::Vector{EventRecord}
    writes::Vector{WriteTransaction}
    log_streams::Vector{LogStreamRecord}
end

function ArchiveEventHistory(
    events = EventRecord[];
    writes = WriteTransaction[],
    log_streams = LogStreamRecord[],
)
    return ArchiveEventHistory(
        _typed_vector(EventRecord, events, "event-history events"),
        _typed_vector(WriteTransaction, writes, "event-history writes"),
        _typed_vector(LogStreamRecord, log_streams, "event-history log streams"),
    )
end

"""
    ArchiveEventHistoryInspection <: AbstractValidationReport

Forensic view of state, run, event, write, and archived-log metadata. A valid
view reconstructs an ordinary `ArchiveGraph`; domain payloads and raw log bytes
remain unloaded.
"""
struct ArchiveEventHistoryInspection <: AbstractValidationReport
    path::String
    identified::Bool
    feature_declared::Bool
    valid::Bool
    state::Union{Nothing,ArchiveStateHistory}
    runs::Vector{RunRecord}
    events::Vector{EventRecord}
    writes::Vector{WriteTransaction}
    log_streams::Vector{LogStreamRecord}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveEventHistoryInspection) = view.valid

function _event_history_profile(profile::ArchiveProfile)
    AH5_EVENT_HISTORY_FEATURE in profile.required_features && throw(ArgumentError(
        "event-history records are an optional AH5 v1 feature and must not be declared required",
    ))
    features = Symbol[profile.features...]
    AH5_EVENT_HISTORY_FEATURE in features || push!(features, AH5_EVENT_HISTORY_FEATURE)
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

function _profile_with_event_history(profile, kwargs)
    if profile === nothing
        return _event_history_profile(ArchiveProfile(; kwargs...))
    end
    isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile))",
    ))
    return _event_history_profile(profile)
end

function _refuse_event_history_root_collision(profile::ArchiveProfile)
    for (name, root) in (
        (:namespaces, profile.roots.namespaces),
        (:schemas, profile.roots.schemas),
        (:history, profile.roots.history),
        (:provenance, profile.roots.provenance),
        (:externals, profile.roots.externals),
        (:integrity, AH5_INTEGRITY_KEY),
        (:state_history, AH5_STATE_HISTORY_KEY),
        (:run_history, AH5_RUN_HISTORY_KEY),
    )
        _path_overlap(root, AH5_EVENT_HISTORY_KEY) || continue
        throw(ArgumentError(
            "AH5 $name root $(repr(root)) overlaps optional event-history root $(repr(AH5_EVENT_HISTORY_KEY))",
        ))
    end
    return profile
end

_event_optional_text(value) = value === nothing ? "" : value.value

function _event_strong_content_id(content_id)
    content_id isa ContentId || return false
    text = content_id.value
    startswith(text, "sha256:") || return false
    hex = text[8:end]
    ncodeunits(hex) == 64 || return false
    return all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), hex)
end

# ---------------------------------------------------------------------------
# Portable event payload boundary
# ---------------------------------------------------------------------------

function _capture_event_payload(payload::NamedTuple)
    diagnostics = DiagnosticMessage[]
    captured, ok = _capture_namedtuple_data!(
        diagnostics,
        payload,
        "<event-payload>",
        :payload,
    )
    return captured, ok, diagnostics
end

function _event_payload_secret_diagnostic!(diagnostics, value, run_id, kind, path)
    if value isa NamedTuple
        for name in keys(value)
            if _looks_like_secret_name(String(name))
                push!(diagnostics, error_diagnostic(
                    :credential_like_content,
                    "event payload key :$name looks like a secret name";
                    run_id = run_id.value,
                    kind = kind,
                    field = path,
                    key = name,
                ))
            end
            _event_payload_secret_diagnostic!(
                diagnostics,
                value[name],
                run_id,
                kind,
                string(path, ".", name),
            )
        end
    elseif value isa PortableDict
        for (key, item) in value.entries
            if (key isa Symbol || key isa AbstractString) && _looks_like_secret_name(String(key))
                push!(diagnostics, error_diagnostic(
                    :credential_like_content,
                    "event payload dictionary key $(repr(key)) looks like a secret name";
                    run_id = run_id.value,
                    kind = kind,
                    field = path,
                    key = String(key),
                ))
            end
            _event_payload_secret_diagnostic!(diagnostics, item, run_id, kind, path)
        end
    elseif value isa PortableEncoded
        _event_payload_secret_diagnostic!(diagnostics, value.data, run_id, kind, path)
    elseif value isa Tuple || value isa AbstractArray
        for item in value
            _event_payload_secret_diagnostic!(diagnostics, item, run_id, kind, path)
        end
    elseif value isa AbstractString
        _looks_like_secret_value(value) || return diagnostics
        push!(diagnostics, error_diagnostic(
            :credential_like_content,
            "credential-like content is not allowed in persisted event payloads";
            run_id = run_id.value,
            kind = kind,
            field = path,
        ))
    end
    return diagnostics
end

function _validate_event_payload_persistence!(diagnostics, event::EventRecord)
    captured, ok, payload_diagnostics = _capture_event_payload(event.payload)
    append!(diagnostics, payload_diagnostics)
    ok || return diagnostics
    _event_payload_secret_diagnostic!(
        diagnostics,
        captured,
        event.run_id,
        event.kind,
        "payload",
    )
    return diagnostics
end

function _event_payload_storage(event::EventRecord)
    captured, ok, diagnostics = _capture_event_payload(event.payload)
    ok && isempty(diagnostics) || throw(ArgumentError(
        "event payload is not portable: $(Tuple(d.code for d in diagnostics))",
    ))
    secret_diagnostics = DiagnosticMessage[]
    _event_payload_secret_diagnostic!(
        secret_diagnostics,
        captured,
        event.run_id,
        event.kind,
        "payload",
    )
    isempty(secret_diagnostics) || throw(ArgumentError(
        "event payload contains credential-like content",
    ))
    return _portable_value_namedtuple(captured)
end

function _restore_event_payload(value)
    payload = _value_from_namedtuple(value)
    payload isa NamedTuple || throw(ArgumentError(
        "AH5 event payload must restore as a NamedTuple",
    ))
    return payload
end

# ---------------------------------------------------------------------------
# Plain-safe records
# ---------------------------------------------------------------------------

function _event_record_storage(event::EventRecord)
    refs = event.object_refs
    return (
        kind = String(event.kind),
        run_id = event.run_id.value,
        activity_id = _event_optional_text(event.activity_id),
        sequence_present = event.sequence !== nothing,
        sequence = event.sequence === nothing ? -1 : event.sequence,
        source = event.source === nothing ? "" : event.source,
        severity = String(event.severity),
        message = event.message,
        timestamp = event.timestamp === nothing ? "" : event.timestamp,
        scope = event.scope === nothing ? "" : String(event.scope),
        revision_id = _event_optional_text(event.revision_id),
        object_ref_object_ids = String[ref.object_id.value for ref in refs],
        object_ref_revision_ids = String[
            ref.revision_id === nothing ? "" : ref.revision_id.value for ref in refs
        ],
        producer_id = _event_optional_text(event.producer_id),
        execution_context = _event_optional_text(event.execution_context),
        retention = String(event.retention),
        payload = _event_payload_storage(event),
    )
end

function _restore_event_record(nt)
    object_ids = String[String(value) for value in nt.object_ref_object_ids]
    revision_ids = String[String(value) for value in nt.object_ref_revision_ids]
    length(object_ids) == length(revision_ids) || throw(ArgumentError(
        "AH5 event object-ref columns have inconsistent lengths",
    ))
    refs = ObjectRef[]
    for index in eachindex(object_ids)
        push!(refs, ObjectRef(
            ObjectId(object_ids[index]);
            revision_id = isempty(revision_ids[index]) ? nothing : RevisionId(revision_ids[index]),
        ))
    end

    sequence_present = _as_bool(nt.sequence_present)
    sequence_raw = Int(nt.sequence)
    if sequence_present
        sequence_raw >= 0 || throw(ArgumentError("negative AH5 event sequence"))
    elseif sequence_raw != -1
        throw(ArgumentError("AH5 event sequence sentinel mismatch"))
    end

    activity = String(nt.activity_id)
    source = String(nt.source)
    timestamp = String(nt.timestamp)
    scope = String(nt.scope)
    revision = String(nt.revision_id)
    producer = String(nt.producer_id)
    context = String(nt.execution_context)
    return EventRecord(
        Symbol(nt.kind),
        RunId(String(nt.run_id));
        activity_id = isempty(activity) ? nothing : ActivityId(activity),
        sequence = sequence_present ? sequence_raw : nothing,
        source = isempty(source) ? nothing : source,
        severity = Symbol(nt.severity),
        message = String(nt.message),
        timestamp = isempty(timestamp) ? nothing : timestamp,
        scope = isempty(scope) ? nothing : Symbol(scope),
        revision_id = isempty(revision) ? nothing : RevisionId(revision),
        object_refs = refs,
        producer_id = isempty(producer) ? nothing : AgentId(producer),
        execution_context = isempty(context) ? nothing : ExecutionContextId(context),
        retention = Symbol(nt.retention),
        payload = _restore_event_payload(nt.payload),
    )
end

_write_record_storage(tx::WriteTransaction) = (
    scope = String(tx.scope),
    phase = String(tx.phase),
    sequence = tx.sequence,
    run_id = _event_optional_text(tx.run_id),
    writer_token = tx.writer_token === nothing ? "" : tx.writer_token,
)

function _restore_write_record(nt)
    run = String(nt.run_id)
    writer = String(nt.writer_token)
    return WriteTransaction(;
        scope = Symbol(nt.scope),
        phase = Symbol(nt.phase),
        sequence = Int(nt.sequence),
        run_id = isempty(run) ? nothing : RunId(run),
        writer_token = isempty(writer) ? nothing : writer,
    )
end

_log_stream_storage(stream::LogStreamRecord) = (
    run_id = stream.run_id.value,
    kind = String(stream.kind),
    activity_id = _event_optional_text(stream.activity_id),
    source = stream.source === nothing ? "" : stream.source,
    retention = String(stream.retention),
    content_id = _event_optional_text(stream.content_id),
    summary = stream.summary === nothing ? "" : stream.summary,
)

function _restore_log_stream(nt)
    activity = String(nt.activity_id)
    source = String(nt.source)
    content = String(nt.content_id)
    summary = String(nt.summary)
    return LogStreamRecord(
        RunId(String(nt.run_id)),
        Symbol(nt.kind);
        activity_id = isempty(activity) ? nothing : ActivityId(activity),
        source = isempty(source) ? nothing : source,
        retention = Symbol(nt.retention),
        content_id = isempty(content) ? nothing : ContentId(content),
        summary = isempty(summary) ? nothing : summary,
    )
end

# ---------------------------------------------------------------------------
# Cross-layer validation
# ---------------------------------------------------------------------------

function _event_object_ref_resolves(graph, externals, ref::ObjectRef)
    _reference_resolves(graph, ref) && return true
    return _match_external(externals, ref.object_id, nothing) !== nothing
end

function _validate_event_records!(diagnostics, graph, externals, events)
    for event in events
        _validate_event_record!(diagnostics, event)
        _validate_event_payload_persistence!(diagnostics, event)
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
        if event.revision_id !== nothing && find_revision(graph, event.revision_id) === nothing
            push!(diagnostics, error_diagnostic(
                :missing_event_revision,
                "event :$(event.kind) names unknown revision $(event.revision_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
                revision_id = event.revision_id.value,
            ))
        end
        for ref in event.object_refs
            _event_object_ref_resolves(graph, externals, ref) && continue
            push!(diagnostics, error_diagnostic(
                :dangling_event_object,
                "event :$(event.kind) names unavailable object $(ref.object_id.value)";
                kind = event.kind,
                run_id = event.run_id.value,
                object_id = ref.object_id.value,
                target_revision_id = ref.revision_id === nothing ? nothing : ref.revision_id.value,
            ))
        end
    end
    _validate_event_sequence_uniqueness!(diagnostics, events)
    return diagnostics
end

function _validate_event_writes!(diagnostics, graph, writes)
    seen = Set{Tuple{Symbol,String}}()
    in_flight_archive = WriteTransaction[]
    for tx in writes
        _validate_write_transaction!(diagnostics, tx)
        key = (tx.scope, tx.run_id === nothing ? "" : tx.run_id.value)
        if key in seen
            push!(diagnostics, error_diagnostic(
                :duplicate_write,
                "$(tx.scope) write for $(key[2]) is recorded more than once";
                scope = tx.scope,
                run_id = tx.run_id === nothing ? nothing : tx.run_id.value,
                sequence = tx.sequence,
            ))
        else
            push!(seen, key)
        end
        if tx.run_id !== nothing
            run = find_run(graph, tx.run_id)
            if run === nothing
                push!(diagnostics, error_diagnostic(
                    :missing_write_run,
                    "$(tx.scope) write sequence $(tx.sequence) names unknown run $(tx.run_id.value)";
                    scope = tx.scope,
                    sequence = tx.sequence,
                    run_id = tx.run_id.value,
                ))
            else
                _validate_write_against_run!(diagnostics, tx, run)
            end
        end
        tx.scope === :archive && tx.phase in IN_FLIGHT_WRITE_PHASES && push!(in_flight_archive, tx)
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

function _validate_event_log_streams!(diagnostics, graph, streams)
    for stream in streams
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
        elseif stream.activity_id !== nothing &&
                !any(activity -> activity.id == stream.activity_id, run.activities)
            push!(diagnostics, error_diagnostic(
                :missing_log_stream_activity,
                "log stream :$(stream.kind) names unknown activity $(stream.activity_id.value)";
                kind = stream.kind,
                run_id = stream.run_id.value,
                activity_id = stream.activity_id.value,
            ))
        end
        if stream.content_id !== nothing && !_event_strong_content_id(stream.content_id)
            push!(diagnostics, error_diagnostic(
                :weak_log_content_identity,
                "archived log stream :$(stream.kind) lacks a strong sha256 ContentId";
                kind = stream.kind,
                run_id = stream.run_id.value,
                content_id = stream.content_id.value,
            ))
        end
    end
    return diagnostics
end

function _validate_event_history(
    state::ArchiveStateHistory,
    runs::Vector{RunRecord},
    history::ArchiveEventHistory;
    externals = ExternalRequirement[],
)
    diagnostics = DiagnosticMessage[]
    reqs = _externals_vector(externals)
    graph = ArchiveGraph(
        state.objects;
        heads = state.heads,
        revisions = state.revisions,
        runs = runs,
        events = history.events,
        writes = history.writes,
        log_streams = history.log_streams,
    )
    _validate_event_records!(diagnostics, graph, reqs, history.events)
    _validate_event_writes!(diagnostics, graph, history.writes)
    _validate_event_log_streams!(diagnostics, graph, history.log_streams)
    return diagnostics
end

# ---------------------------------------------------------------------------
# Physical extension and forensic reconstruction
# ---------------------------------------------------------------------------

function _write_event_history!(file, history::ArchiveEventHistory)
    _write_indexed!(
        file,
        string(AH5_EVENT_HISTORY_KEY, "/events"),
        history.events,
        _event_record_storage,
    )
    _write_indexed!(
        file,
        string(AH5_EVENT_HISTORY_KEY, "/writes"),
        history.writes,
        _write_record_storage,
    )
    _write_indexed!(
        file,
        string(AH5_EVENT_HISTORY_KEY, "/log_streams"),
        history.log_streams,
        _log_stream_storage,
    )
    return file
end

function _read_event_history(file)
    events = _read_indexed(
        EventRecord,
        file,
        string(AH5_EVENT_HISTORY_KEY, "/events"),
        _restore_event_record,
    )
    writes = _read_indexed(
        WriteTransaction,
        file,
        string(AH5_EVENT_HISTORY_KEY, "/writes"),
        _restore_write_record,
    )
    streams = _read_indexed(
        LogStreamRecord,
        file,
        string(AH5_EVENT_HISTORY_KEY, "/log_streams"),
        _restore_log_stream,
    )
    return ArchiveEventHistory(events; writes = writes, log_streams = streams)
end

function _event_history_counts_exist(file)
    for child in ("events", "writes", "log_streams")
        key = _count_key(string(AH5_EVENT_HISTORY_KEY, "/", child))
        _jld2_get(file, key) === nothing && return false
    end
    return true
end

"""
    write_event_archive(path, graph; kwargs...)

Create an AH5 archive with state, run/activity/restart, and generic event/write/
log provenance metadata. Event payloads must be portable; raw log bytes are not
embedded by this method.
"""
function write_event_archive(
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
    history = ArchiveEventHistory(
        EventRecord[ordered_events(graph)...];
        writes = WriteTransaction[ordered_writes(graph)...],
        log_streams = LogStreamRecord[ordered_log_streams(graph)...],
    )
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
    append!(diagnostics, _validate_event_history(
        state,
        runs,
        history;
        externals = reqs,
    ))
    any(d -> d.severity === :error, diagnostics) && throw(ArgumentError(
        "refusing to persist invalid event history: $(Tuple(d.code for d in diagnostics if d.severity === :error))",
    ))

    profile_record = _profile_with_event_history(profile, kwargs)
    _refuse_event_history_root_collision(profile_record)
    created = false
    try
        write_run_archive(
            path,
            graph;
            namespaces = namespaces,
            schemas = schemas,
            externals = reqs,
            profile = profile_record,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_event_history!(file, history)
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end
    return path
end

function _empty_event_history_inspection(
    path,
    identified,
    declared,
    state,
    runs,
    externals,
    diagnostics,
)
    valid = identified && !any(d -> d.severity === :error, diagnostics)
    return ArchiveEventHistoryInspection(
        String(path),
        identified,
        declared,
        valid,
        state,
        RunRecord[runs...],
        EventRecord[],
        WriteTransaction[],
        LogStreamRecord[],
        ExternalRequirement[externals...],
        diagnostics,
    )
end

"""
    inspect_archive(path, ArchiveEventHistory) -> ArchiveEventHistoryInspection

Forensically reconstruct all currently persistent generic state and provenance
layers. Scientific payload bytes and raw log bytes are not loaded.
"""
function inspect_archive(path::AbstractString, ::Type{ArchiveEventHistory})
    run_view = inspect_archive(path, ArchiveRunHistory)
    diagnostics = copy(run_view.diagnostics)
    if !run_view.identified
        return _empty_event_history_inspection(
            path, false, false, nothing, RunRecord[], run_view.externals, diagnostics,
        )
    end
    if !isvalid(run_view)
        return _empty_event_history_inspection(
            path, true, false, nothing, RunRecord[], run_view.externals, diagnostics,
        )
    end

    core = inspect_archive(path)
    declared = core.profile !== nothing && AH5_EVENT_HISTORY_FEATURE in core.profile.features
    declared || return _empty_event_history_inspection(
        path,
        true,
        false,
        run_view.state,
        run_view.runs,
        run_view.externals,
        diagnostics,
    )

    run_declared = core.profile !== nothing && AH5_RUN_HISTORY_FEATURE in core.profile.features
    run_declared || push!(diagnostics, error_diagnostic(
        :event_history_run_missing,
        "AH5 event-history feature requires run-history records",
    ))
    run_view.state === nothing && push!(diagnostics, error_diagnostic(
        :event_history_state_missing,
        "AH5 event-history feature requires authoritative state-history records",
    ))
    any(d -> d.severity === :error, diagnostics) && return _empty_event_history_inspection(
        path, true, true, nothing, RunRecord[], run_view.externals, diagnostics,
    )

    history = nothing
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            _event_history_counts_exist(file) || throw(ArgumentError(
                "AH5 profile declares event history but required indexed roots are missing",
            ))
            history = _read_event_history(file)
        end
        append!(diagnostics, _validate_event_history(
            run_view.state,
            run_view.runs,
            history;
            externals = run_view.externals,
        ))
        core.history.events == length(history.events) || push!(diagnostics, error_diagnostic(
            :event_history_summary_mismatch,
            "event-history event count does not match AH5 history summary";
            summary = core.history.events,
            records = length(history.events),
        ))
        core.history.writes == length(history.writes) || push!(diagnostics, error_diagnostic(
            :event_history_summary_mismatch,
            "event-history write count does not match AH5 history summary";
            summary = core.history.writes,
            records = length(history.writes),
        ))
        core.history.log_streams == length(history.log_streams) || push!(diagnostics, error_diagnostic(
            :event_history_summary_mismatch,
            "event-history log-stream count does not match AH5 history summary";
            summary = core.history.log_streams,
            records = length(history.log_streams),
        ))
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_event_history,
            "AH5 event/write/log provenance metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        history = nothing
    end

    valid = history !== nothing && !any(d -> d.severity === :error, diagnostics)
    return ArchiveEventHistoryInspection(
        String(path),
        true,
        true,
        valid,
        valid ? run_view.state : nothing,
        valid ? copy(run_view.runs) : RunRecord[],
        valid ? history.events : EventRecord[],
        valid ? history.writes : WriteTransaction[],
        valid ? history.log_streams : LogStreamRecord[],
        copy(run_view.externals),
        diagnostics,
    )
end

"""
    reconstruct_graph(view::ArchiveEventHistoryInspection) -> ArchiveGraph

Reconstruct the complete currently persistent payload-free archive graph.
"""
function reconstruct_graph(view::ArchiveEventHistoryInspection)
    isvalid(view) || throw(ArgumentError("cannot reconstruct graph from invalid AH5 event history"))
    view.state === nothing && throw(ArgumentError("AH5 event history has no state graph"))
    return ArchiveGraph(
        view.state.objects;
        heads = view.state.heads,
        revisions = view.state.revisions,
        runs = view.runs,
        events = view.events,
        writes = view.writes,
        log_streams = view.log_streams,
    )
end

function inspect(view::ArchiveEventHistoryInspection, revision_id::RevisionId)
    return inspect(reconstruct_graph(view), revision_id; externals = view.externals)
end

function event_timeline(view::ArchiveEventHistoryInspection; run_id = nothing)
    return event_timeline(reconstruct_graph(view); run_id = run_id)
end

function validate(view::ArchiveEventHistoryInspection)
    return ValidationReport(
        :archive_event_history,
        view.valid,
        copy(view.diagnostics),
        (;
            path = view.path,
            identified = view.identified,
            feature_declared = view.feature_declared,
            events = length(view.events),
            writes = length(view.writes),
            log_streams = length(view.log_streams),
        ),
    )
end

function report(view::ArchiveEventHistoryInspection)
    return ObjectReport(
        :archive_event_history,
        view.feature_declared ?
            "AH5 event history with $(length(view.events)) events, $(length(view.writes)) writes, and $(length(view.log_streams)) log streams." :
            "AH5 archive has no event-history extension.",
        to_namedtuple(view),
        copy(view.diagnostics),
        ArtifactRef[],
    )
end

to_namedtuple(history::ArchiveEventHistory) = (
    events = Tuple(_event_record_storage(event) for event in history.events),
    writes = Tuple(_write_record_storage(write) for write in history.writes),
    log_streams = Tuple(_log_stream_storage(stream) for stream in history.log_streams),
)

to_namedtuple(view::ArchiveEventHistoryInspection) = (
    path = view.path,
    identified = view.identified,
    feature_declared = view.feature_declared,
    valid = view.valid,
    events = Tuple(_event_record_storage(event) for event in view.events),
    writes = Tuple(_write_record_storage(write) for write in view.writes),
    log_streams = Tuple(_log_stream_storage(stream) for stream in view.log_streams),
    externals = Tuple(to_namedtuple(req) for req in view.externals),
    diagnostics = Tuple(to_namedtuple.(view.diagnostics)),
)
