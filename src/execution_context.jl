const EXECUTION_CONTEXT_FORMAT = "episteme-execution-context-v1"
const EXECUTION_CONTEXT_FIELDS = (:hardware, :devices, :numerics, :parallelism,
    :ranks, :rng, :features, :plan_id, :revision_id, :event_sequence, :captured_at)

function _execution_text(value)
    value isa AbstractString || throw(ArgumentError("execution fact must be text"))
    text = String(strip(value))
    isempty(text) && throw(ArgumentError("execution fact must be nonempty or nothing"))
    (_looks_like_secret_value(text) || occursin(r"(?i)(password|secret|token|api[_-]?key|authorization|cookie)\s*[:=]", text)) &&
        throw(ArgumentError("credential-like execution fact is forbidden"))
    occursin(r"(?i)(/home/|/users/|/user/|[a-z]:\\users\\|~/)", text) &&
        throw(ArgumentError("machine-local user paths are not execution facts"))
    any(iscntrl, text) && throw(ArgumentError("control characters are not execution facts"))
    return text
end

function _execution_value(value, kind)
    value === nothing && return nothing
    kind === :text && return _execution_text(value)
    if kind in (:positive, :nonnegative)
        value isa Integer && !(value isa Bool) && value >= (kind === :positive ? 1 : 0) ||
            throw(ArgumentError("execution count is outside its declared range"))
        return Int(value)
    elseif kind === :bool
        value isa Bool || throw(ArgumentError("execution policy must be Bool or nothing"))
        return value
    elseif kind === :names
        value isa Tuple || value isa AbstractVector || throw(ArgumentError("execution names must be a sequence"))
        return Tuple(sort!(unique(_execution_text.(collect(value)))))
    elseif kind === :seed
        value isa Integer && !(value isa Bool) && value >= 0 ||
            throw(ArgumentError("RNG seed must be a nonnegative integer"))
        return string(value)
    elseif kind === :content
        value isa ContentId || throw(ArgumentError("RNG state requires a domain-owned ContentId"))
        return _execution_text(value.value)
    end
    throw(ArgumentError("unsupported execution fact kind"))
end

function _execution_record(value, schema)
    value === nothing && return nothing
    value isa NamedTuple || throw(ArgumentError("execution facts must be an allowlisted NamedTuple"))
    all(key -> key in keys(schema), keys(value)) ||
        throw(ArgumentError("unrecognized execution fact field"))
    return NamedTuple{keys(schema)}(Tuple(
        _execution_value(get(value, key, nothing), schema[key]) for key in keys(schema)))
end

const EXECUTION_HARDWARE_FIELDS = (cpu_architecture=:text, cpu_model=:text, memory_bytes=:positive)
const EXECUTION_DEVICE_FIELDS = (id=:text, architecture=:text, model=:text, memory_bytes=:positive)
const EXECUTION_NUMERICS_FIELDS = (precision=:text, accumulation=:text, deterministic=:bool,
    fast_math=:bool, backend=:text, provider=:text, solver=:text, compiler=:text)
const EXECUTION_PARALLEL_FIELDS = (rank_count=:positive, thread_count=:positive,
    partition=:text, allocation_id=:text)
const EXECUTION_RANK_FIELDS = (rank=:nonnegative, device_ids=:names, thread_count=:positive)
const EXECUTION_RNG_FIELDS = (algorithm=:text, version=:text, seed=:seed,
    state_content=:content, replay=:text)

function _execution_records(values, schema, key)
    values === nothing && return nothing
    values isa Tuple || values isa AbstractVector || throw(ArgumentError("execution records must be a sequence"))
    records = [_execution_record(value, schema) for value in values]
    all(record -> record !== nothing && record[key] !== nothing, records) ||
        throw(ArgumentError("execution record identity is required"))
    length(unique(record[key] for record in records)) == length(records) ||
        throw(ArgumentError("duplicate execution record identity"))
    return Tuple(sort!(records; by=record -> record[key]))
end

"""
    ExecutionContext(; hardware=nothing, devices=nothing, numerics=nothing,
        parallelism=nothing, ranks=nothing, rng=nothing, features=nothing,
        plan_id=nothing, revision_id=nothing, event_sequence=nothing,
        captured_at=nothing)

Immutable allowlisted execution facts, never inferred from the current machine.
Each group accepts only its documented NamedTuple fields. Missing facts remain
`nothing`; an empty device/rank/feature tuple is a recorded empty collection.
Device ids are caller-assigned logical ids, not live device handles or hostnames.
RNG state is a domain-owned content reference. Replay declarations describe the
caller's contract and do not guarantee bitwise agreement across hardware.

Identity covers all recorded facts, independently of software and schema versions.
Run/event identities and UTC capture time may be omitted when a context is shared.
"""
struct ExecutionContext
    id::ExecutionContextId
    facts::NamedTuple

    function ExecutionContext(; hardware=nothing, devices=nothing, numerics=nothing,
        parallelism=nothing, ranks=nothing, rng=nothing, features=nothing,
        plan_id=nothing, revision_id=nothing, event_sequence=nothing, captured_at=nothing)
        hardware = _execution_record(hardware, EXECUTION_HARDWARE_FIELDS)
        devices = _execution_records(devices, EXECUTION_DEVICE_FIELDS, :id)
        numerics = _execution_record(numerics, EXECUTION_NUMERICS_FIELDS)
        parallelism = _execution_record(parallelism, EXECUTION_PARALLEL_FIELDS)
        ranks = _execution_records(ranks, EXECUTION_RANK_FIELDS, :rank)
        rng = _execution_record(rng, EXECUTION_RNG_FIELDS)
        if ranks !== nothing
            for rank in ranks
                if parallelism !== nothing && parallelism.rank_count !== nothing
                    rank.rank < parallelism.rank_count || throw(ArgumentError("rank exceeds recorded rank count"))
                end
                if rank.device_ids !== nothing
                    devices !== nothing || throw(ArgumentError("rank devices require recorded device identities"))
                    all(id -> any(device -> device.id == id, devices), rank.device_ids) ||
                        throw(ArgumentError("rank references an unrecorded device"))
                end
            end
        end
        if rng !== nothing
            rng.replay in (nothing, "unspecified", "seed", "state") ||
                throw(ArgumentError("RNG replay must be unspecified, seed, or state"))
            if rng.replay in ("seed", "state")
                rng.algorithm !== nothing && rng.version !== nothing ||
                    throw(ArgumentError("RNG replay requires recorded algorithm and version"))
                required = rng.replay == "seed" ? rng.seed : rng.state_content
                required !== nothing || throw(ArgumentError("RNG replay prerequisite was not recorded"))
            end
        end
        plan_id === nothing || plan_id isa PlanId || throw(ArgumentError("plan_id must be PlanId"))
        revision_id === nothing || revision_id isa RevisionId || throw(ArgumentError("revision_id must be RevisionId"))
        if captured_at !== nothing
            captured_at = _execution_text(captured_at)
            occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$", captured_at) ||
                throw(ArgumentError("capture timestamp requires a complete UTC date and time"))
            try
                DateTime(chop(captured_at))
            catch
                throw(ArgumentError("invalid UTC capture timestamp"))
            end
        end
        facts = (; hardware, devices, numerics, parallelism, ranks, rng,
            features=_execution_value(features, :names),
            plan_id=plan_id === nothing ? nothing : _execution_text(plan_id.value),
            revision_id=revision_id === nothing ? nothing : _execution_text(revision_id.value),
            event_sequence=_execution_value(event_sequence, :nonnegative), captured_at)
        content = merge((; format=EXECUTION_CONTEXT_FORMAT), facts)
        return new(ExecutionContextId("execution:" * canonical_content_id(content).value), facts)
    end
end

to_namedtuple(context::ExecutionContext) = merge(
    (; id=context.id.value, format=EXECUTION_CONTEXT_FORMAT), context.facts)

function from_namedtuple(::Type{ExecutionContext}, nt)
    nt.format == EXECUTION_CONTEXT_FORMAT || throw(ArgumentError("unsupported execution context format"))
    Set(keys(nt)) == Set((:id, :format, EXECUTION_CONTEXT_FIELDS...)) ||
        throw(ArgumentError("unrecognized or missing execution context fields"))
    facts = NamedTuple{EXECUTION_CONTEXT_FIELDS}(Tuple(nt[key] for key in EXECUTION_CONTEXT_FIELDS))
    rng = facts.rng
    if rng !== nothing
        rng = merge(rng, (seed=rng.seed === nothing ? nothing : parse(BigInt, rng.seed),
            state_content=rng.state_content === nothing ? nothing : ContentId(rng.state_content)))
    end
    context = ExecutionContext(; facts..., rng,
        plan_id=facts.plan_id === nothing ? nothing : PlanId(facts.plan_id),
        revision_id=facts.revision_id === nothing ? nothing : RevisionId(facts.revision_id))
    context.id.value == nt.id || throw(ArgumentError("execution facts do not match recorded identity"))
    return context
end

function _execution_summary(context::ExecutionContext)
    facts = context.facts
    fact(group, field) = group === nothing ? nothing : group[field]
    return (id=context.id.value,
        cpu_architecture=fact(facts.hardware, :cpu_architecture),
        device_count=facts.devices === nothing ? nothing : length(facts.devices),
        precision=fact(facts.numerics, :precision),
        deterministic=fact(facts.numerics, :deterministic),
        rank_count=fact(facts.parallelism, :rank_count),
        rng_algorithm=fact(facts.rng, :algorithm), rng_replay=fact(facts.rng, :replay))
end

function validate(context::ExecutionContext)
    diagnostics = DiagnosticMessage[]
    for (field, value) in pairs(context.facts)
        value === nothing && push!(diagnostics, warning_diagnostic(:execution_provenance_unknown,
            "execution $field was not recorded"; field))
    end
    return ValidationReport(:execution_context, true, diagnostics, _execution_summary(context))
end
report(context::ExecutionContext) = validate(context)

"""Immutable shared execution records, deduplicated and ordered by identity."""
struct ExecutionContextRegistry
    contexts::Tuple{Vararg{ExecutionContext}}
    function ExecutionContextRegistry(contexts=())
        records = Dict{String,ExecutionContext}()
        for context in _typed_vector(ExecutionContext, contexts, "contexts")
            records[context.id.value] = context
        end
        return new(Tuple(records[key] for key in sort!(collect(keys(records)))))
    end
end
function find_execution_context(registry::ExecutionContextRegistry, id::ExecutionContextId)
    index = findfirst(context -> context.id == id, registry.contexts)
    return index === nothing ? nothing : registry.contexts[index]
end
to_namedtuple(registry::ExecutionContextRegistry) =
    (; contexts=Tuple(to_namedtuple(context) for context in registry.contexts))
from_namedtuple(::Type{ExecutionContextRegistry}, nt) = ExecutionContextRegistry(
    from_namedtuple(ExecutionContext, context) for context in nt.contexts)

function validate(registry::ExecutionContextRegistry)
    diagnostics = DiagnosticMessage[]
    for context in registry.contexts
        append!(diagnostics, validate(context).diagnostics)
    end
    return ValidationReport(:execution_context_registry, true, diagnostics,
        (; context_count=length(registry.contexts)))
end
report(registry::ExecutionContextRegistry) = validate(registry)
