# ---------------------------------------------------------------------------
# Core AH5 profile writer and generic inspector (src/archive_profile.jl)
#
# JLD2 creates the file and owns `/_types`; Episteme owns `/episteme`. The
# profile record, the indexed storage shapes, and every decoder live in the
# owner package. Only the two entry points that open a path are here.
# ---------------------------------------------------------------------------

function Episteme.write_archive(
    path::AbstractString;
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    software_environments = nothing,
    execution_contexts = nothing,
    kwargs...,
)
    ispath(path) && throw(ArgumentError("archive already exists: $path"))
    graph === nothing || graph isa ArchiveGraph || throw(ArgumentError(
        "graph must be ArchiveGraph or nothing, got $(typeof(graph))",
    ))
    namespaces === nothing || namespaces isa NamespaceRegistry || throw(ArgumentError(
        "namespaces must be NamespaceRegistry or nothing, got $(typeof(namespaces))",
    ))
    schemas === nothing || schemas isa SchemaRegistry || throw(ArgumentError(
        "schemas must be SchemaRegistry or nothing, got $(typeof(schemas))",
    ))
    profile_record = profile === nothing ? ArchiveProfile(; kwargs...) : profile
    profile === nothing || isempty(kwargs) || throw(ArgumentError(
        "pass either profile= or ArchiveProfile keywords, not both",
    ))
    profile_record isa ArchiveProfile || throw(ArgumentError(
        "profile must be ArchiveProfile, got $(typeof(profile_record))",
    ))
    profile_record = _published_profile(profile_record)
    if software_environments !== nothing
        software_environments isa SoftwareEnvironmentRegistry || throw(ArgumentError(
            "software_environments must be SoftwareEnvironmentRegistry or nothing"))
        profile_record = Episteme._software_profile(profile_record)
        Episteme._refuse_missing_software_environments(graph, software_environments)
    elseif Episteme.AH5_SOFTWARE_ENVIRONMENTS_FEATURE in profile_record.features
        throw(ArgumentError("declared software environment feature requires a registry"))
    end
    if execution_contexts !== nothing
        execution_contexts isa ExecutionContextRegistry || throw(ArgumentError(
            "execution_contexts must be ExecutionContextRegistry or nothing"))
        profile_record = Episteme._execution_profile(profile_record)
        Episteme._refuse_missing_execution_contexts(graph, execution_contexts)
    elseif Episteme.AH5_EXECUTION_CONTEXTS_FEATURE in profile_record.features
        throw(ArgumentError("declared execution context feature requires a registry"))
    end
    _refuse_invalid_profile(profile_record)
    _refuse_invalid_payload(graph, namespaces, schemas)

    objects = graph === nothing ? ArchiveObject[] : graph.objects
    ns_listings = namespaces === nothing && graph === nothing ?
        NamespaceListing[] : list_namespaces(objects, namespaces)
    schema_listings = schemas === nothing ? SchemaListing[] : list_schemas(schemas)
    history = graph === nothing ? ArchiveHistorySummary() : ArchiveHistorySummary(graph)
    provenance = graph === nothing ? ArchiveProvenanceSummary() : ArchiveProvenanceSummary(graph)
    external_values = _typed_vector(ExternalRequirement, externals, "external requirements")
    roots = profile_record.roots

    JLD2.jldopen(path, "w") do file
        file[AH5_PROFILE_KEY] = _profile_storage(profile_record)
        _write_indexed!(file, roots.namespaces, ns_listings, _namespace_listing_storage)
        _write_indexed!(file, roots.schemas, schema_listings, _schema_listing_storage)
        file[roots.history] = _history_storage(history)
        file[roots.provenance] = _provenance_storage(provenance)
        _write_indexed!(file, roots.externals, external_values, _external_storage)
        if software_environments !== nothing
            Episteme._write_software_environments!(file, software_environments)
        end
        if execution_contexts !== nothing
            Episteme._write_execution_contexts!(file, execution_contexts)
        end
    end
    return path
end

# A task may store a Ref under these keys to count read sessions and generic
# core decodes. The keys hold no archive data; the open file is an argument.
const _ARCHIVE_READ_OPENS = :episteme_ah5_read_opens
const _ARCHIVE_CORE_DECODES = :episteme_ah5_core_decodes

function _note_archive_counter(key)
    counter = get(task_local_storage(), key, nothing)
    counter isa Ref || return nothing
    counter[] += 1
    return nothing
end

function _jldopen_archive_read(path)
    _note_archive_counter(_ARCHIVE_READ_OPENS)
    return JLD2.jldopen(path, "r"; plain = true)
end

"""
    _inspect_archive_session(f, path) -> result of f

Identify `path` once, open it once for reading, decode generic AH5 metadata
once, and pass `(file, core)` to `f`. `file` is `nothing` when the path cannot
be opened; `core` is still the fail-closed inspection. The file is closed
before this function returns.
"""
function _inspect_archive_session(f, path::AbstractString)
    diagnostics = DiagnosticMessage[]
    if !ispath(path)
        push!(diagnostics, error_diagnostic(
            :missing_archive,
            "archive path does not exist: $path";
            path = String(path),
        ))
        return f(nothing, _empty_inspection(path, diagnostics))
    end
    if !is_hdf5_container(path)
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is not an HDF5-format AH5 archive";
            path = String(path),
        ))
        return f(nothing, _empty_inspection(path, diagnostics))
    end

    local file
    try
        file = _jldopen_archive_read(path)
    catch err
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is HDF5-format but has no readable AH5 profile";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        return f(nothing, _empty_inspection(path, diagnostics))
    end

    try
        core = try
            _note_archive_counter(_ARCHIVE_CORE_DECODES)
            _inspect_open_archive(path, file, diagnostics)
        catch err
            push!(diagnostics, error_diagnostic(
                :not_ah5_archive,
                "file is HDF5-format but has no readable AH5 profile";
                path = String(path),
                reason = sprint(showerror, err),
            ))
            return f(nothing, _empty_inspection(path, diagnostics))
        end
        return f(file, core)
    finally
        close(file)
    end
end

function Episteme.inspect_archive(path::AbstractString)
    return _inspect_archive_session(path) do _file, core
        return core
    end
end
