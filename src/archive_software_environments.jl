const AH5_SOFTWARE_ENVIRONMENTS_FEATURE = :software_environment_records
const AH5_SOFTWARE_ENVIRONMENTS_KEY = "episteme/software_environments"

# Plain JLD2 reads omit zero-size fields (nothing and empty tuples). Store
# explicit presence bits and ordinary vectors instead of the portable tuples.
_software_optional_storage(value) = value === nothing ? "" : string(value)
_software_optional_restore(value) = isempty(value) ? nothing : String(value)
_software_list_storage(value) = value === nothing ? String[] : String[value...]

function _software_component_storage(component::SoftwareComponent)
    return (id=component.id, name=component.name,
        uuid=_software_optional_storage(component.uuid),
        version=_software_optional_storage(component.version),
        repository=_software_optional_storage(component.repository),
        source_identity=_software_optional_storage(component.source_identity),
        dirty=component.dirty === nothing ? -1 : Int(component.dirty),
        dependencies_known=component.dependencies !== nothing,
        dependencies=_software_list_storage(component.dependencies),
        features_known=component.features !== nothing,
        features=_software_list_storage(component.features))
end

function _restore_software_component(nt)
    nt.dirty in (-1, 0, 1) || throw(ArgumentError("invalid recorded software dirty state"))
    return SoftwareComponent(nt.id, nt.name;
        uuid=_software_optional_restore(nt.uuid),
        version=_software_optional_restore(nt.version),
        repository=_software_optional_restore(nt.repository),
        source_identity=_software_optional_restore(nt.source_identity),
        dirty=nt.dirty == -1 ? nothing : Bool(nt.dirty),
        dependencies=nt.dependencies_known ? nt.dependencies : nothing,
        features=nt.features_known ? nt.features : nothing)
end

function _software_environment_storage(environment::SoftwareEnvironment)
    return (id=environment.id.value, format="episteme-software-environment-v1",
        julia_version=_software_optional_storage(environment.julia_version),
        julia_build=_software_optional_storage(environment.julia_build),
        features_known=environment.features !== nothing,
        features=_software_list_storage(environment.features))
end

function _restore_software_environment(nt, components)
    return from_namedtuple(SoftwareEnvironment, (
        id=nt.id, format=nt.format,
        components=Tuple(to_namedtuple(c) for c in components),
        julia_version=_software_optional_restore(nt.julia_version),
        julia_build=_software_optional_restore(nt.julia_build),
        features=nt.features_known ? nt.features : nothing))
end

function _write_software_environments!(file, registry::SoftwareEnvironmentRegistry)
    root = AH5_SOFTWARE_ENVIRONMENTS_KEY
    file[_count_key(root)] = length(registry.environments)
    for (index, environment) in enumerate(registry.environments)
        key = _entry_key(root, index)
        file[key * "/record"] = _software_environment_storage(environment)
        _write_indexed!(file, key * "/components", environment.components,
            _software_component_storage)
    end
    return file
end

function _read_software_environments(file)
    root = AH5_SOFTWARE_ENVIRONMENTS_KEY
    count = _jld2_get(file, _count_key(root))
    count isa Integer && count >= 0 || throw(ArgumentError(
        "missing or invalid software environment count"))
    environments = SoftwareEnvironment[]
    for index in 1:count
        key = _entry_key(root, index)
        component_count = _jld2_get(file, _count_key(key * "/components"))
        component_count isa Integer && component_count >= 0 || throw(ArgumentError(
            "missing or invalid software component count"))
        components = _read_indexed(SoftwareComponent, file, key * "/components",
            _restore_software_component)
        push!(environments, _restore_software_environment(file[key * "/record"], components))
    end
    length(Set(e.id for e in environments)) == length(environments) ||
        throw(ArgumentError("duplicate persisted software environment identity"))
    return SoftwareEnvironmentRegistry(environments)
end

function _software_profile(profile::ArchiveProfile)
    AH5_SOFTWARE_ENVIRONMENTS_FEATURE in profile.required_features && throw(ArgumentError(
        "software environment records are an optional AH5 v1 feature"))
    for root in (profile.roots.namespaces, profile.roots.schemas, profile.roots.history,
                 profile.roots.provenance, profile.roots.externals)
        _path_overlap(root, AH5_SOFTWARE_ENVIRONMENTS_KEY) && throw(ArgumentError(
            "archive root overlaps reserved software environment metadata: $root"))
    end
    features = Tuple(unique((profile.features..., AH5_SOFTWARE_ENVIRONMENTS_FEATURE)))
    return ArchiveProfile(; magic=profile.magic, profile_version=profile.profile_version,
        archive_id=profile.archive_id, created_at=profile.created_at, creator=profile.creator,
        features, required_features=profile.required_features, roots=profile.roots,
        package_version=profile.package_version)
end

function _refuse_missing_software_environments(graph, registry::SoftwareEnvironmentRegistry)
    graph === nothing && return nothing
    for id in ArchiveProvenanceSummary(graph).software_environments
        find_software_environment(registry, SoftwareEnvironmentId(id)) === nothing &&
            throw(ArgumentError("software environment record is missing: $id"))
    end
    return nothing
end

"""Forensic view of optional AH5 software environment records."""
struct ArchiveSoftwareEnvironmentInspection
    path::String
    identified::Bool
    feature_declared::Bool
    registry::Union{Nothing,SoftwareEnvironmentRegistry}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(view::ArchiveSoftwareEnvironmentInspection) =
    view.identified && !any(d -> d.severity === :error, view.diagnostics)
validate(view::ArchiveSoftwareEnvironmentInspection) = ValidationReport(
    :ah5_software_environments, isvalid(view), copy(view.diagnostics),
    (; path=view.path, feature_declared=view.feature_declared))
report(view::ArchiveSoftwareEnvironmentInspection) = validate(view)
to_namedtuple(view::ArchiveSoftwareEnvironmentInspection) = (
    path=view.path, identified=view.identified, feature_declared=view.feature_declared,
    valid=isvalid(view), registry=view.registry === nothing ? nothing : to_namedtuple(view.registry),
    diagnostics=Tuple(to_namedtuple.(view.diagnostics)),
)
