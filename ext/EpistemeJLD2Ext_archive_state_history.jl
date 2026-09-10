# ---------------------------------------------------------------------------
# Authoritative state history (src/archive_state_history.jl)
# ---------------------------------------------------------------------------

function Episteme.write_state_archive(
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
            software_environments = software_environments,
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

function Episteme.inspect_archive(path::AbstractString, ::Type{ArchiveStateHistory})
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
