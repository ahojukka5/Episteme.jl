# ---------------------------------------------------------------------------
# AH5 profile, JLD2 writer, and generic file inspector (#40)
#
# `.ah5` is Episteme's versioned scientific-archive profile on an ordinary
# HDF5-format file created by JLD2. Identity is in-file metadata, not the
# filename extension. JLD2 `/_types` is Julia representation, not profile
# identity. HDF5.jl is not required here; bulk `/data` remains a later
# EpistemeHDF5Ext path.
# ---------------------------------------------------------------------------

const AH5_MAGIC = "AH5"
const AH5_PROFILE_VERSION = "1.0.0"
const HDF5_SIGNATURE = UInt8[0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a]
const JLD2_HEADER_PREFIX = codeunits("HDF5-based Julia Data Format")

const AH5_PROFILE_KEY = "episteme/profile"
const AH5_NAMESPACES_KEY = "episteme/namespaces"
const AH5_SCHEMAS_KEY = "episteme/schemas"
const AH5_HISTORY_KEY = "episteme/history"
const AH5_PROVENANCE_KEY = "episteme/provenance"
const AH5_EXTERNALS_KEY = "episteme/externals"

const AH5_SUPPORTED_FEATURES = (
    :jld2_writer,
    :namespaces,
    :embedded_schemas,
    :history,
    :provenance,
    :externals,
)

"""
    ArchiveProfileRoots

Physical JLD2/HDF5 paths for inspectable AH5 records. These are not
package namespaces and not scientific schema identity.
"""
struct ArchiveProfileRoots
    namespaces::String
    schemas::String
    history::String
    provenance::String
    externals::String
end

function ArchiveProfileRoots(;
    namespaces::AbstractString = AH5_NAMESPACES_KEY,
    schemas::AbstractString = AH5_SCHEMAS_KEY,
    history::AbstractString = AH5_HISTORY_KEY,
    provenance::AbstractString = AH5_PROVENANCE_KEY,
    externals::AbstractString = AH5_EXTERNALS_KEY,
)
    return ArchiveProfileRoots(
        String(namespaces),
        String(schemas),
        String(history),
        String(provenance),
        String(externals),
    )
end

"""
    ArchiveProfile

Domain-neutral AH5 root record. `profile_version` is independent of the
Episteme package version and of payload-schema versions.
`package_version` is provenance only.
"""
struct ArchiveProfile
    magic::String
    profile_version::String
    archive_id::String
    created_at::String
    creator::String
    features::Tuple{Vararg{Symbol}}
    required_features::Tuple{Vararg{Symbol}}
    roots::ArchiveProfileRoots
    package_version::String
end

function ArchiveProfile(;
    magic::AbstractString = AH5_MAGIC,
    profile_version::AbstractString = AH5_PROFILE_VERSION,
    archive_id::AbstractString = string(UUIDs.uuid4()),
    created_at::AbstractString = _ah5_timestamp(),
    creator::AbstractString = "Episteme.jl",
    features = (:jld2_writer,),
    required_features = (),
    roots::ArchiveProfileRoots = ArchiveProfileRoots(),
    package_version::AbstractString = string(pkgversion(@__MODULE__)),
)
    stripped_magic = String(strip(magic))
    stripped_version = String(strip(profile_version))
    stripped_id = String(strip(archive_id))
    isempty(stripped_magic) && throw(ArgumentError("AH5 magic must not be empty"))
    isempty(stripped_version) && throw(ArgumentError("AH5 profile version must not be empty"))
    isempty(stripped_id) && throw(ArgumentError("AH5 archive id must not be empty"))
    return ArchiveProfile(
        stripped_magic,
        stripped_version,
        stripped_id,
        String(created_at),
        String(creator),
        _symbol_tuple(features, "AH5 features"),
        _symbol_tuple(required_features, "AH5 required features"),
        roots,
        String(strip(package_version)),
    )
end

"""
    ArchiveHistorySummary

Counts and head names for generic inspection. Payload bytes are never
included.
"""
struct ArchiveHistorySummary
    objects::Int
    heads::Int
    revisions::Int
    runs::Int
    events::Int
    writes::Int
    log_streams::Int
    head_names::Tuple{Vararg{Symbol}}
end

function ArchiveHistorySummary(
    graph::ArchiveGraph,
)
    heads = ordered_heads(graph)
    return ArchiveHistorySummary(
        length(graph.objects),
        length(graph.heads),
        length(graph.revisions),
        length(graph.runs),
        length(graph.events),
        length(graph.writes),
        length(graph.log_streams),
        Tuple(head.name for head in heads),
    )
end

ArchiveHistorySummary() = ArchiveHistorySummary(0, 0, 0, 0, 0, 0, 0, ())

"""
    ArchiveProvenanceSummary

Software-environment and execution-context identities observed on
envelope records. Full manifests are issues #37 and #43.
"""
struct ArchiveProvenanceSummary
    software_environments::Tuple{Vararg{String}}
    execution_contexts::Tuple{Vararg{String}}
end

function ArchiveProvenanceSummary(graph::ArchiveGraph)
    software = String[]
    contexts = String[]
    for object in ordered_objects(graph)
        sw = object.provenance.software_environment
        if sw !== nothing && !(sw.value in software)
            push!(software, sw.value)
        end
        ctx = object.provenance.execution_context
        if ctx !== nothing && !(ctx.value in contexts)
            push!(contexts, ctx.value)
        end
    end
    return ArchiveProvenanceSummary(Tuple(software), Tuple(contexts))
end

ArchiveProvenanceSummary() = ArchiveProvenanceSummary((), ())

"""
    ArchiveInspection

Generic view of one `.ah5` file. Domain payload packages are not loaded.
"""
struct ArchiveInspection
    path::String
    identified::Bool
    profile::Union{Nothing,ArchiveProfile}
    namespaces::Vector{NamespaceListing}
    schemas::Vector{SchemaListing}
    history::ArchiveHistorySummary
    provenance::ArchiveProvenanceSummary
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

_ah5_timestamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ")

function _profile_major(version::AbstractString)
    part = split(String(version), '.'; limit = 2)[1]
    n = tryparse(Int, part)
    return n
end

function is_hdf5_container(path::AbstractString)
    isfile(path) || return false
    return open(path, "r") do io
        nbytes = Int(min(filesize(io), 65536))
        nbytes < length(HDF5_SIGNATURE) && return false
        data = read(io, nbytes)
        if length(data) >= length(JLD2_HEADER_PREFIX) &&
                view(data, 1:length(JLD2_HEADER_PREFIX)) == JLD2_HEADER_PREFIX
            return true
        end
        offset = 0
        while offset + length(HDF5_SIGNATURE) <= length(data)
            if view(data, offset + 1:offset + length(HDF5_SIGNATURE)) == HDF5_SIGNATURE
                return true
            end
            offset = offset == 0 ? 512 : 2 * offset
        end
        return false
    end
end

"""
    write_archive(path; graph=nothing, namespaces=nothing, schemas=nothing,
                  externals=(), profile=nothing, kwargs...)

Create a JLD2-backed AH5 file. The path is created by JLD2. Existing
paths are refused. Domain payloads are not written.
"""
function write_archive(
    path::AbstractString;
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
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

    objects = graph === nothing ? ArchiveObject[] : graph.objects
    ns_listings = namespaces === nothing && graph === nothing ?
        NamespaceListing[] : list_namespaces(objects, namespaces)
    schema_listings = schemas === nothing ? SchemaListing[] : list_schemas(schemas)
    history = graph === nothing ? ArchiveHistorySummary() : ArchiveHistorySummary(graph)
    provenance = graph === nothing ? ArchiveProvenanceSummary() : ArchiveProvenanceSummary(graph)
    external_values = _typed_vector(ExternalRequirement, externals, "external requirements")

    JLD2.jldopen(path, "w") do file
        file[AH5_PROFILE_KEY] = _profile_storage(profile_record)
        file[AH5_NAMESPACES_KEY] = _record_storage(ns_listings)
        file[AH5_SCHEMAS_KEY] = _record_storage(schema_listings)
        file[AH5_HISTORY_KEY] = _history_storage(history)
        file[AH5_PROVENANCE_KEY] = _provenance_storage(provenance)
        file[AH5_EXTERNALS_KEY] = _record_storage(external_values)
    end
    return path
end

"""
    inspect_archive(path) -> ArchiveInspection

Read AH5 profile metadata without domain packages or payload load.
Forensic JLD2 `plain=true` is the default reader. Full Julia-native
object reconstruction is not this API.
"""
function inspect_archive(path::AbstractString)
    diagnostics = DiagnosticMessage[]
    empty = ArchiveInspection(
        String(path),
        false,
        nothing,
        NamespaceListing[],
        SchemaListing[],
        ArchiveHistorySummary(),
        ArchiveProvenanceSummary(),
        ExternalRequirement[],
        diagnostics,
    )
    if !ispath(path)
        push!(diagnostics, error_diagnostic(
            :missing_archive,
            "archive path does not exist: $path";
            path = String(path),
        ))
        return empty
    end
    if !is_hdf5_container(path)
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is not an HDF5-format AH5 archive";
            path = String(path),
        ))
        return empty
    end

    groups = try
        _read_ah5_groups(path)
    catch err
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "file is HDF5-format but has no readable AH5 profile";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        return empty
    end

    raw_profile = groups.profile
    if raw_profile === nothing
        push!(diagnostics, error_diagnostic(
            :missing_profile,
            "mandatory AH5 profile record $(AH5_PROFILE_KEY) is missing";
            path = String(path),
        ))
        return empty
    end

    profile = try
        from_namedtuple(ArchiveProfile, raw_profile)
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_profile,
            "AH5 profile metadata is corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
        return empty
    end

    identified = profile.magic == AH5_MAGIC
    if !identified
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "in-file magic $(repr(profile.magic)) is not $AH5_MAGIC";
            path = String(path),
            magic = profile.magic,
        ))
    end
    _validate_archive_profile!(diagnostics, profile)

    namespaces = NamespaceListing[]
    schemas = SchemaListing[]
    history = ArchiveHistorySummary()
    provenance = ArchiveProvenanceSummary()
    externals = ExternalRequirement[]
    try
        namespaces = _restore_records(NamespaceListing, groups.namespaces)
        schemas = _restore_records(SchemaListing, groups.schemas)
        history = groups.history === nothing ? ArchiveHistorySummary() :
            from_namedtuple(ArchiveHistorySummary, groups.history)
        provenance = groups.provenance === nothing ? ArchiveProvenanceSummary() :
            from_namedtuple(ArchiveProvenanceSummary, groups.provenance)
        externals = _restore_records(ExternalRequirement, groups.externals)
    catch err
        push!(diagnostics, error_diagnostic(
            :corrupt_profile,
            "AH5 inspectable records are corrupt";
            path = String(path),
            reason = sprint(showerror, err),
        ))
    end

    return ArchiveInspection(
        String(path),
        identified,
        identified ? profile : nothing,
        namespaces,
        schemas,
        history,
        provenance,
        externals,
        diagnostics,
    )
end

function is_ah5_archive(path::AbstractString)
    inspection = inspect_archive(path)
    return inspection.identified
end

function _read_ah5_groups(path::AbstractString)
    return JLD2.jldopen(path, "r") do file
        return (
            profile = _jld2_get(file, AH5_PROFILE_KEY),
            namespaces = _jld2_get(file, AH5_NAMESPACES_KEY),
            schemas = _jld2_get(file, AH5_SCHEMAS_KEY),
            history = _jld2_get(file, AH5_HISTORY_KEY),
            provenance = _jld2_get(file, AH5_PROVENANCE_KEY),
            externals = _jld2_get(file, AH5_EXTERNALS_KEY),
        )
    end
end

function _jld2_get(file, key::AbstractString)
    haskey(file, key) || return nothing
    return file[key]
end

function _record_storage(records)
    return [to_namedtuple(record) for record in records]
end

function _string_storage(values)
    return String[String(value) for value in values]
end

function _profile_storage(profile::ArchiveProfile)
    nt = to_namedtuple(profile)
    return merge(nt, (
        features = _string_storage(profile.features),
        required_features = _string_storage(profile.required_features),
    ))
end

function _history_storage(history::ArchiveHistorySummary)
    nt = to_namedtuple(history)
    return merge(nt, (; head_names = _string_storage(history.head_names)))
end

function _provenance_storage(prov::ArchiveProvenanceSummary)
    return (
        software_environments = _string_storage(prov.software_environments),
        execution_contexts = _string_storage(prov.execution_contexts),
    )
end

function _feature_tuple(value)
    value === nothing && return ()
    if value isa NamedTuple
        return Tuple(Symbol(item) for item in values(value))
    end
    return Tuple(Symbol(item) for item in value)
end

function _restore_records(::Type{T}, values) where {T}
    values === nothing && return T[]
    result = T[]
    for value in values
        push!(result, from_namedtuple(T, value))
    end
    return result
end

function _validate_archive_profile!(diagnostics, profile::ArchiveProfile)
    if profile.magic == AH5_MAGIC
        major = _profile_major(profile.profile_version)
        if major === nothing || major != _profile_major(AH5_PROFILE_VERSION)
            push!(diagnostics, error_diagnostic(
                :unsupported_profile_version,
                "AH5 profile version $(profile.profile_version) is not supported (expected $AH5_PROFILE_VERSION major)";
                profile_version = profile.profile_version,
                supported = AH5_PROFILE_VERSION,
            ))
        end
    end
    unknown = Symbol[]
    for feature in profile.required_features
        feature in AH5_SUPPORTED_FEATURES || push!(unknown, feature)
    end
    if !isempty(unknown)
        push!(diagnostics, error_diagnostic(
            :unsupported_required_feature,
            "AH5 archive requires unsupported features $(Tuple(unknown))";
            required_features = Tuple(unknown),
        ))
    end
    return diagnostics
end

function validate(profile::ArchiveProfile)
    diagnostics = DiagnosticMessage[]
    if profile.magic != AH5_MAGIC
        push!(diagnostics, error_diagnostic(
            :not_ah5_archive,
            "in-file magic $(repr(profile.magic)) is not $AH5_MAGIC";
            magic = profile.magic,
        ))
    end
    _validate_archive_profile!(diagnostics, profile)
    return ValidationReport(
        :ah5_profile,
        isempty(diagnostics),
        diagnostics,
        (;
            archive_id = profile.archive_id,
            profile_version = profile.profile_version,
            package_version = profile.package_version,
        ),
    )
end

function validate(inspection::ArchiveInspection)
    return ValidationReport(
        :ah5_archive,
        inspection.identified && isempty(inspection.diagnostics),
        inspection.diagnostics,
        (;
            path = inspection.path,
            identified = inspection.identified,
            archive_id = inspection.profile === nothing ? nothing : inspection.profile.archive_id,
            schemas = length(inspection.schemas),
            namespaces = length(inspection.namespaces),
        ),
    )
end

function report(profile::ArchiveProfile)
    return ObjectReport(
        :ah5_profile,
        "AH5 profile $(profile.profile_version) archive $(profile.archive_id).",
        to_namedtuple(profile),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function report(inspection::ArchiveInspection)
    id = inspection.profile === nothing ? "unidentified" : inspection.profile.archive_id
    return ObjectReport(
        :ah5_archive,
        inspection.identified ? "AH5 archive $id." : "File is not an AH5 archive.",
        to_namedtuple(inspection),
        inspection.diagnostics,
        ArtifactRef[],
    )
end

function readiness(inspection::ArchiveInspection, target::PipelineTarget)
    ok = inspection.identified && isempty(inspection.diagnostics)
    return ReadinessReport(
        :ah5_archive,
        target,
        ok && target.name === :inspect,
        inspection.diagnostics,
        (;
            identified = inspection.identified,
            target = target.name,
        ),
    )
end

to_namedtuple(roots::ArchiveProfileRoots) = (
    namespaces = roots.namespaces,
    schemas = roots.schemas,
    history = roots.history,
    provenance = roots.provenance,
    externals = roots.externals,
)

to_namedtuple(profile::ArchiveProfile) = (
    magic = profile.magic,
    profile_version = profile.profile_version,
    archive_id = profile.archive_id,
    created_at = profile.created_at,
    creator = profile.creator,
    features = profile.features,
    required_features = profile.required_features,
    roots = to_namedtuple(profile.roots),
    package_version = profile.package_version,
)

to_namedtuple(history::ArchiveHistorySummary) = (
    objects = history.objects,
    heads = history.heads,
    revisions = history.revisions,
    runs = history.runs,
    events = history.events,
    writes = history.writes,
    log_streams = history.log_streams,
    head_names = history.head_names,
)

to_namedtuple(prov::ArchiveProvenanceSummary) = (
    software_environments = prov.software_environments,
    execution_contexts = prov.execution_contexts,
)

to_namedtuple(inspection::ArchiveInspection) = (
    path = inspection.path,
    identified = inspection.identified,
    profile = inspection.profile === nothing ? nothing : to_namedtuple(inspection.profile),
    namespaces = Tuple(to_namedtuple.(inspection.namespaces)),
    schemas = Tuple(to_namedtuple.(inspection.schemas)),
    history = to_namedtuple(inspection.history),
    provenance = to_namedtuple(inspection.provenance),
    externals = Tuple(to_namedtuple.(inspection.externals)),
    diagnostics = Tuple(to_namedtuple.(inspection.diagnostics)),
)

function from_namedtuple(::Type{ArchiveProfileRoots}, nt)
    return ArchiveProfileRoots(;
        namespaces = String(nt.namespaces),
        schemas = String(nt.schemas),
        history = String(nt.history),
        provenance = String(nt.provenance),
        externals = String(nt.externals),
    )
end

function from_namedtuple(::Type{ArchiveProfile}, nt)
    return ArchiveProfile(;
        magic = String(nt.magic),
        profile_version = String(nt.profile_version),
        archive_id = String(nt.archive_id),
        created_at = String(nt.created_at),
        creator = String(nt.creator),
        features = _feature_tuple(nt.features),
        required_features = hasproperty(nt, :required_features) ?
            _feature_tuple(nt.required_features) : (),
        roots = from_namedtuple(ArchiveProfileRoots, nt.roots),
        package_version = String(nt.package_version),
    )
end

function from_namedtuple(::Type{ArchiveHistorySummary}, nt)
    return ArchiveHistorySummary(
        Int(nt.objects),
        Int(nt.heads),
        Int(nt.revisions),
        Int(nt.runs),
        Int(nt.events),
        Int(nt.writes),
        Int(nt.log_streams),
        Tuple(Symbol(name) for name in nt.head_names),
    )
end

function from_namedtuple(::Type{ArchiveProvenanceSummary}, nt)
    return ArchiveProvenanceSummary(
        Tuple(String(id) for id in nt.software_environments),
        Tuple(String(id) for id in nt.execution_contexts),
    )
end
