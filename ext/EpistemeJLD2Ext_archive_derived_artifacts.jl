# ---------------------------------------------------------------------------
# Derived/debug artifact provenance (src/archive_derived_artifacts.jl)
# ---------------------------------------------------------------------------

function Episteme.write_derived_archive(
    path::AbstractString,
    graph::ArchiveGraph,
    artifacts;
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
    history = ArchiveDerivedHistory(artifacts)
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
    append!(diagnostics, _validate_derived_history(
        state,
        runs,
        history;
        externals = reqs,
    ))
    any(d -> d.severity === :error, diagnostics) && throw(ArgumentError(
        "refusing to persist invalid derived-artifact history: $(Tuple(d.code for d in diagnostics if d.severity === :error))",
    ))

    profile_record = _profile_with_derived_artifacts(profile, kwargs)
    _refuse_derived_history_root_collision(profile_record)
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
            execution_contexts = execution_contexts,
        )
        created = true
        JLD2.jldopen(path, "r+") do file
            _write_derived_history!(file, history)
        end
    catch
        created && ispath(path) && rm(path; force = true)
        rethrow()
    end
    return path
end

function Episteme.inspect_archive(path::AbstractString, ::Type{ArchiveDerivedHistory})
    run_view = inspect_archive(path, ArchiveRunHistory)
    diagnostics = copy(run_view.diagnostics)
    if !run_view.identified
        return _empty_derived_history_inspection(
            path, false, false, nothing, RunRecord[], run_view.externals, diagnostics,
        )
    end
    if !isvalid(run_view)
        return _empty_derived_history_inspection(
            path, true, false, nothing, RunRecord[], run_view.externals, diagnostics,
        )
    end

    core = inspect_archive(path)
    declared = core.profile !== nothing && AH5_DERIVED_ARTIFACTS_FEATURE in core.profile.features
    declared || return _empty_derived_history_inspection(
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
        :derived_history_run_missing,
        "AH5 derived-artifact feature requires run-history records",
    ))
    run_view.state === nothing && push!(diagnostics, error_diagnostic(
        :derived_history_state_missing,
        "AH5 derived-artifact feature requires authoritative state-history records",
    ))
    any(d -> d.severity === :error, diagnostics) && return _empty_derived_history_inspection(
        path, true, true, nothing, RunRecord[], run_view.externals, diagnostics,
    )

    history = nothing
    try
        JLD2.jldopen(path, "r"; plain = true) do file
            _derived_history_counts_exist(file) || throw(ArgumentError(
                "AH5 profile declares derived artifacts but required indexed roots are missing",
            ))
            history = _read_derived_history(file)
        end
        append!(diagnostics, _validate_derived_history(
            run_view.state,
            run_view.runs,
            history;
            externals = run_view.externals,
        ))
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_derived_artifacts,
            "AH5 derived-artifact provenance metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        history = nothing
    end

    valid = history !== nothing && !any(d -> d.severity === :error, diagnostics)
    return ArchiveDerivedHistoryInspection(
        String(path),
        true,
        true,
        valid,
        valid ? run_view.state : nothing,
        valid ? copy(run_view.runs) : RunRecord[],
        valid ? history.artifacts : DerivedArtifactRecord[],
        copy(run_view.externals),
        diagnostics,
    )
end
