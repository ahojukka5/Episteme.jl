# ---------------------------------------------------------------------------
# Event/write/log provenance (src/archive_event_history.jl)
# ---------------------------------------------------------------------------

function Episteme.write_event_archive(
    path::AbstractString,
    graph::ArchiveGraph;
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    software_environments = nothing,
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
            software_environments = software_environments,
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

function Episteme.inspect_archive(path::AbstractString, ::Type{ArchiveEventHistory})
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
