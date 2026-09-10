_software_text(::Nothing) = nothing
function _software_text(value::AbstractString)
    result = String(strip(value))
    isempty(result) && throw(ArgumentError("software provenance text must be nonempty or nothing"))
    return result
end

_software_names(::Nothing) = nothing
_software_names(values) = Tuple(sort!(unique([_software_text(value) for value in values])))

"""
    SoftwareComponent(id, name; uuid=nothing, version=nothing,
                      repository=nothing, source_identity=nothing,
                      dirty=nothing, dependencies=nothing, features=nothing)

Immutable package, native library, or backend facts supplied by the caller.
`id` is the stable graph key; dependencies refer to component ids. A source
identity records the complete commit/tree/build identity, independently of
the software version. Nothing is inferred from the current machine.

`nothing` means not recorded, including for dependencies and features; an
empty tuple means a recorded empty set. Software versions never imply payload
schema compatibility. Released packages need no repository or git checkout.
"""
struct SoftwareComponent
    id::String
    name::String
    uuid::Union{Nothing,UUID}
    version::Union{Nothing,String}
    repository::Union{Nothing,String}
    source_identity::Union{Nothing,String}
    dirty::Union{Nothing,Bool}
    dependencies::Union{Nothing,Tuple{Vararg{String}}}
    features::Union{Nothing,Tuple{Vararg{String}}}

    function SoftwareComponent(id::AbstractString, name::AbstractString;
        uuid=nothing, version=nothing, repository=nothing, source_identity=nothing,
        dirty::Union{Nothing,Bool}=nothing, dependencies=nothing, features=nothing)
        return new(_software_text(id), _software_text(name),
            uuid === nothing ? nothing : UUID(string(uuid)),
            _software_text(version), _software_text(repository),
            _software_text(source_identity), dirty,
            _software_names(dependencies), _software_names(features))
    end
end

to_namedtuple(component::SoftwareComponent) = (
    id=component.id, name=component.name,
    uuid=component.uuid === nothing ? nothing : string(component.uuid),
    version=component.version, repository=component.repository,
    source_identity=component.source_identity, dirty=component.dirty,
    dependencies=component.dependencies, features=component.features,
)

_software_environment_content(components, julia_version, julia_build, features) = (
    format="episteme-software-environment-v1",
    components=Tuple(to_namedtuple(component) for component in components),
    julia_version=julia_version, julia_build=julia_build, features=features,
)

"""
    SoftwareEnvironment(components=(); julia_version=nothing,
                        julia_build=nothing, features=nothing)

One normalized immutable dependency graph and runtime record. Its
`SoftwareEnvironmentId` is derived from all recorded facts, so input order is
irrelevant while source, dirty-state and material feature differences change
identity. Runs and object revisions reference this shared record through the
existing software-environment provenance id.
"""
struct SoftwareEnvironment
    id::SoftwareEnvironmentId
    components::Tuple{Vararg{SoftwareComponent}}
    julia_version::Union{Nothing,String}
    julia_build::Union{Nothing,String}
    features::Union{Nothing,Tuple{Vararg{String}}}

    function SoftwareEnvironment(components=(); julia_version=nothing,
        julia_build=nothing, features=nothing)
        ordered = sort!(_typed_vector(SoftwareComponent, components, "components"); by=c -> c.id)
        ids = Set(component.id for component in ordered)
        length(ids) == length(ordered) || throw(ArgumentError("duplicate software component id"))
        for component in ordered
            component.dependencies === nothing && continue
            all(id -> id in ids, component.dependencies) || throw(ArgumentError(
                "software component $(component.id) references an unrecorded dependency"))
        end
        normalized = Tuple(ordered)
        version, build = _software_text(julia_version), _software_text(julia_build)
        flags = _software_names(features)
        content = _software_environment_content(normalized, version, build, flags)
        id = SoftwareEnvironmentId("software:" * canonical_content_id(content).value)
        return new(id, normalized, version, build, flags)
    end
end

to_namedtuple(environment::SoftwareEnvironment) = merge(
    (; id=environment.id.value),
    _software_environment_content(environment.components, environment.julia_version,
        environment.julia_build, environment.features),
)

"""Return recorded provenance gaps without consulting the current environment."""
function validate(environment::SoftwareEnvironment)
    diagnostics = DiagnosticMessage[]
    for field in (:julia_version, :julia_build, :features)
        getfield(environment, field) === nothing && push!(diagnostics, warning_diagnostic(
            :software_provenance_unknown, "environment $field was not recorded"; field))
    end
    for component in environment.components
        for field in (:version, :source_identity, :dirty, :dependencies, :features)
            getfield(component, field) === nothing && push!(diagnostics, warning_diagnostic(
                :software_provenance_unknown, "component $(component.id) $field was not recorded";
                component=component.id, field))
        end
        component.dirty === true && push!(diagnostics, warning_diagnostic(
            :modified_software_source,
            "component $(component.id) has modified source; its base identity does not reconstruct those changes";
            component=component.id))
    end
    return ValidationReport(:software_environment, true, diagnostics,
        (; id=environment.id.value, component_count=length(environment.components)))
end

report(environment::SoftwareEnvironment) = validate(environment)

"""Restore recorded component facts without probing installed software."""
function from_namedtuple(::Type{SoftwareComponent}, nt)
    return SoftwareComponent(nt.id, nt.name; uuid=nt.uuid, version=nt.version,
        repository=nt.repository, source_identity=nt.source_identity,
        dirty=nt.dirty, dependencies=nt.dependencies, features=nt.features)
end

"""Restore an environment, rejecting unsupported formats and altered content."""
function from_namedtuple(::Type{SoftwareEnvironment}, nt)
    nt.format == "episteme-software-environment-v1" || throw(ArgumentError(
        "unsupported software environment format: $(nt.format)"))
    environment = SoftwareEnvironment(
        (from_namedtuple(SoftwareComponent, component) for component in nt.components);
        julia_version=nt.julia_version, julia_build=nt.julia_build, features=nt.features)
    environment.id.value == nt.id || throw(ArgumentError(
        "software environment content does not match its recorded identity"))
    return environment
end

"""
    SoftwareEnvironmentRegistry(environments=())

Immutable, deterministically ordered shared environment records. Repeated
identical records are stored once; runs and revisions refer to them by id.
"""
struct SoftwareEnvironmentRegistry
    environments::Tuple{Vararg{SoftwareEnvironment}}

    function SoftwareEnvironmentRegistry(environments=())
        records = Dict{String,SoftwareEnvironment}()
        for environment in _typed_vector(SoftwareEnvironment, environments, "environments")
            key = environment.id.value
            if haskey(records, key)
                to_namedtuple(records[key]) == to_namedtuple(environment) ||
                    throw(ArgumentError("conflicting software environment records for $key"))
            else
                records[key] = environment
            end
        end
        return new(Tuple(records[key] for key in sort!(collect(keys(records)))))
    end
end

"""Look up a recorded environment by identity; return `nothing` when absent."""
function find_software_environment(registry::SoftwareEnvironmentRegistry, id::SoftwareEnvironmentId)
    for environment in registry.environments
        environment.id == id && return environment
    end
    return nothing
end

to_namedtuple(registry::SoftwareEnvironmentRegistry) = (
    environments=Tuple(to_namedtuple(environment) for environment in registry.environments),
)

function from_namedtuple(::Type{SoftwareEnvironmentRegistry}, nt)
    return SoftwareEnvironmentRegistry(
        from_namedtuple(SoftwareEnvironment, environment) for environment in nt.environments)
end

function validate(registry::SoftwareEnvironmentRegistry)
    diagnostics = DiagnosticMessage[]
    for environment in registry.environments
        append!(diagnostics, validate(environment).diagnostics)
    end
    return ValidationReport(:software_environment_registry, true, diagnostics,
        (; environment_count=length(registry.environments)))
end

report(registry::SoftwareEnvironmentRegistry) = validate(registry)
