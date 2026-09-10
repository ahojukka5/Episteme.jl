# ---------------------------------------------------------------------------
# Run/activity/restart provenance (src/archive_run_history.jl)
# ---------------------------------------------------------------------------

function Episteme.write_run_archive(
    path::AbstractString,
    graph::ArchiveGraph;
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    software_environments = nothing,
    execution_contexts = nothing,
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
            software_environments = software_environments,
            execution_contexts = execution_contexts,
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

function Episteme.inspect_archive(path::AbstractString, ::Type{ArchiveRunHistory})
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
