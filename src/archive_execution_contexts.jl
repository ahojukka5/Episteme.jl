const AH5_EXECUTION_CONTEXTS_FEATURE = :execution_context_records
const AH5_EXECUTION_CONTEXTS_KEY = "episteme/execution_contexts"

# Explicit tags and indexed children preserve nothing and empty tuples even
# under plain JLD2 reads, which can omit zero-size NamedTuple fields.
function _write_execution_value!(file, key, value)
    if value === nothing
        file[key * "/kind"] = "nothing"
    elseif value isa NamedTuple || value isa Tuple
        file[key * "/kind"] = value isa NamedTuple ? "record" : "tuple"
        file[key * "/count"] = length(value)
        if value isa NamedTuple
            file[key * "/names"] = String[String(name) for name in keys(value)]
        end
        for (index, item) in enumerate(value)
            _write_execution_value!(file, _entry_key(key, index), item)
        end
    else
        kind = value isa Bool ? "bool" : value isa Integer ? "integer" :
            value isa AbstractString ? "text" : error("unsupported execution storage value")
        file[key * "/kind"] = kind
        file[key * "/value"] = value
    end
    return file
end

function _read_execution_value(file, key)
    kind = String(file[key * "/kind"])
    kind == "nothing" && return nothing
    if kind in ("record", "tuple")
        count = file[key * "/count"]
        count isa Integer && !(count isa Bool) && count >= 0 ||
            throw(ArgumentError("invalid execution value count"))
        values = Tuple(_read_execution_value(file, _entry_key(key, index)) for index in 1:count)
        kind == "tuple" && return values
        names = Symbol.(file[key * "/names"])
        length(names) == count && length(unique(names)) == count ||
            throw(ArgumentError("invalid execution record fields"))
        return NamedTuple{Tuple(names)}(values)
    end
    value = file[key * "/value"]
    valid = kind == "bool" ? value isa Bool :
        kind == "integer" ? value isa Integer && !(value isa Bool) :
        kind == "text" ? value isa AbstractString : false
    valid || throw(ArgumentError("invalid execution storage value"))
    return value
end

function _write_execution_contexts!(file, registry::ExecutionContextRegistry)
    root = AH5_EXECUTION_CONTEXTS_KEY
    file[_count_key(root)] = length(registry.contexts)
    for (index, context) in enumerate(registry.contexts)
        _write_execution_value!(file, _entry_key(root, index), to_namedtuple(context))
    end
    return file
end

function _read_execution_contexts(file)
    root = AH5_EXECUTION_CONTEXTS_KEY
    count = _jld2_get(file, _count_key(root))
    count isa Integer && !(count isa Bool) && count >= 0 ||
        throw(ArgumentError("missing or invalid execution context count"))
    contexts = [from_namedtuple(ExecutionContext,
        _read_execution_value(file, _entry_key(root, index))) for index in 1:count]
    length(unique(context.id for context in contexts)) == count ||
        throw(ArgumentError("duplicate recorded execution context"))
    return ExecutionContextRegistry(contexts)
end

function _execution_profile(profile::ArchiveProfile)
    AH5_EXECUTION_CONTEXTS_FEATURE in profile.required_features &&
        throw(ArgumentError("execution context records are an optional AH5 v1 feature"))
    for root in (profile.roots.namespaces, profile.roots.schemas, profile.roots.history,
        profile.roots.provenance, profile.roots.externals)
        _path_overlap(root, AH5_EXECUTION_CONTEXTS_KEY) &&
            throw(ArgumentError("archive root overlaps execution context metadata"))
    end
    return ArchiveProfile(; magic=profile.magic, profile_version=profile.profile_version,
        archive_id=profile.archive_id, created_at=profile.created_at, creator=profile.creator,
        features=Tuple(unique((profile.features..., AH5_EXECUTION_CONTEXTS_FEATURE))),
        required_features=profile.required_features, roots=profile.roots,
        package_version=profile.package_version)
end

function _execution_references(objects, runs, events=())
    references = Tuple{Union{Nothing,ExecutionContextId},String}[
        (object.provenance.execution_context, "object") for object in objects]
    for run in runs
        push!(references, (run.execution_context, "run"))
        for staged in run.staged
            push!(references, (staged.provenance.execution_context, "staged object"))
        end
        if run.restart !== nothing
            push!(references, (run.restart.execution_context, "restart requirement"))
        end
    end
    append!(references, ((event.execution_context, "event") for event in events))
    return references
end

function _refuse_missing_execution_contexts(graph, registry::ExecutionContextRegistry)
    graph === nothing && return nothing
    for (id, _) in _execution_references(graph.objects, graph.runs, graph.events)
        id === nothing && continue
        find_execution_context(registry, id) === nothing &&
            throw(ArgumentError("execution context reference has no recorded context"))
    end
    return nothing
end

"""Forensic view of optional AH5 execution facts, without scientific payloads."""
struct ArchiveExecutionContextInspection
    path::String
    identified::Bool
    feature_declared::Bool
    registry::Union{Nothing,ExecutionContextRegistry}
    diagnostics::Vector{DiagnosticMessage}
end
Base.isvalid(view::ArchiveExecutionContextInspection) =
    view.identified && !any(d -> d.severity === :error, view.diagnostics)
validate(view::ArchiveExecutionContextInspection) = ValidationReport(
    :ah5_execution_contexts, isvalid(view), copy(view.diagnostics),
    (; path=view.path, feature_declared=view.feature_declared,
        contexts=view.registry === nothing ? nothing :
            Tuple(_execution_summary(context) for context in view.registry.contexts)))
report(view::ArchiveExecutionContextInspection) = validate(view)
to_namedtuple(view::ArchiveExecutionContextInspection) = (
    path=view.path, identified=view.identified, feature_declared=view.feature_declared,
    valid=isvalid(view), registry=view.registry === nothing ? nothing : to_namedtuple(view.registry),
    diagnostics=Tuple(to_namedtuple.(view.diagnostics)))
