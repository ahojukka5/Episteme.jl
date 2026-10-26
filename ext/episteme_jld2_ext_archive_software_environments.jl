function Episteme.inspect_archive(path::AbstractString, ::Type{SoftwareEnvironmentRegistry})
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    declared = base.profile !== nothing &&
        Episteme.AH5_SOFTWARE_ENVIRONMENTS_FEATURE in base.profile.features
    registry = nothing
    if base.identified && !any(d -> d.severity === :error, diagnostics)
        if declared
            try
                Episteme._software_profile(base.profile)
                registry = JLD2.jldopen(path, "r"; plain=true) do file
                    Episteme._read_software_environments(file)
                end
                for id in base.provenance.software_environments
                    find_software_environment(registry, SoftwareEnvironmentId(id)) === nothing &&
                        throw(ArgumentError("software environment record is missing: $id"))
                end
                # Summaries are only indexes. Check authoritative records too,
                # so removing an id from the summary cannot hide a dangling ref.
                objects = ArchiveObject[]
                runs = RunRecord[]
                if Episteme.AH5_RUN_HISTORY_FEATURE in base.profile.features
                    history = inspect_archive(path, ArchiveRunHistory)
                    isvalid(history) || throw(ArgumentError("invalid authoritative run history"))
                    objects = history.state.objects
                    runs = history.runs
                elseif Episteme.AH5_STATE_HISTORY_FEATURE in base.profile.features
                    history = inspect_archive(path, ArchiveStateHistory)
                    isvalid(history) || throw(ArgumentError("invalid authoritative state history"))
                    objects = history.state.objects
                end
                references = Tuple{Union{Nothing,SoftwareEnvironmentId},String}[
                    (object.provenance.software_environment, "object $(object.object_id.value)")
                    for object in objects]
                for run in runs
                    push!(references, (run.software_environment, "run $(run.id.value)"))
                    for staged in run.staged
                        push!(references, (staged.provenance.software_environment,
                            "staged object $(staged.object_id.value)"))
                    end
                end
                for (id, owner) in references
                    if id === nothing
                        push!(diagnostics, warning_diagnostic(:software_provenance_unknown,
                            "$owner has no recorded software environment"; owner))
                    elseif find_software_environment(registry, id) === nothing
                        throw(ArgumentError("$owner references a missing software environment: $(id.value)"))
                    end
                end
                append!(diagnostics, validate(registry).diagnostics)
            catch err
                registry = nothing
                push!(diagnostics, error_diagnostic(:invalid_software_environment_records,
                    "cannot restore recorded software environments"; reason=sprint(showerror, err)))
            end
        else
            push!(diagnostics, warning_diagnostic(:software_provenance_unknown,
                "archive contains no declared software environment records"))
        end
    end
    return ArchiveSoftwareEnvironmentInspection(String(path), base.identified,
        declared, registry, diagnostics)
end
