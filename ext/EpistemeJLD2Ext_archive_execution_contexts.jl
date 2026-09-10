function Episteme.inspect_archive(path::AbstractString, ::Type{ExecutionContextRegistry})
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    declared = base.profile !== nothing &&
        Episteme.AH5_EXECUTION_CONTEXTS_FEATURE in base.profile.features
    registry = nothing
    if base.identified && !any(d -> d.severity === :error, diagnostics)
        if declared
            try
                Episteme._execution_profile(base.profile)
                registry = JLD2.jldopen(path, "r"; plain=true) do file
                    Episteme._read_execution_contexts(file)
                end
                for id in base.provenance.execution_contexts
                    find_execution_context(registry, ExecutionContextId(id)) === nothing &&
                        throw(ArgumentError("summarized context reference is missing"))
                end
                objects, runs, events = ArchiveObject[], RunRecord[], EventRecord[]
                if Episteme.AH5_EVENT_HISTORY_FEATURE in base.profile.features
                    history = inspect_archive(path, ArchiveEventHistory)
                    isvalid(history) || throw(ArgumentError("invalid authoritative event history"))
                    objects, runs, events = history.state.objects, history.runs, history.events
                elseif Episteme.AH5_RUN_HISTORY_FEATURE in base.profile.features
                    history = inspect_archive(path, ArchiveRunHistory)
                    isvalid(history) || throw(ArgumentError("invalid authoritative run history"))
                    objects, runs = history.state.objects, history.runs
                elseif Episteme.AH5_STATE_HISTORY_FEATURE in base.profile.features
                    history = inspect_archive(path, ArchiveStateHistory)
                    isvalid(history) || throw(ArgumentError("invalid authoritative state history"))
                    objects = history.state.objects
                end
                for (id, owner) in Episteme._execution_references(objects, runs, events)
                    if id === nothing
                        push!(diagnostics, warning_diagnostic(:execution_provenance_unknown,
                            "$owner has no recorded execution context"; owner))
                    elseif find_execution_context(registry, id) === nothing
                        throw(ArgumentError("authoritative context reference is missing"))
                    end
                end
                append!(diagnostics, validate(registry).diagnostics)
            catch
                registry = nothing
                # Malformed files may contain secrets: do not echo decoder values.
                push!(diagnostics, error_diagnostic(:invalid_execution_context_records,
                    "cannot restore or resolve recorded execution contexts"))
            end
        else
            push!(diagnostics, warning_diagnostic(:execution_provenance_unknown,
                "archive contains no declared execution context records"))
        end
    end
    return ArchiveExecutionContextInspection(String(path), base.identified,
        declared, registry, diagnostics)
end
