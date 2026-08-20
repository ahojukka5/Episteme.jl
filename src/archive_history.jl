# ---------------------------------------------------------------------------
# Dual-history records: plan, run, activity, event, revision
#
# Structural types only. No execute!/commit!, no file I/O.
# ---------------------------------------------------------------------------

const EPISTEME_DOCUMENT_KIND = Symbol("episteme/document")
const EPISTEME_PLAN_KIND = Symbol("episteme/plan")

const OPERATION_REUSE_POLICIES = (:forbid, :allow_if_domain_says, :force_recompute)
const ACTIVITY_REUSE_STATES = (:computed, :reused, :forced)
const RUN_STATUSES = (:queued, :running, :completed, :failed, :interrupted)

episteme_document_schema(version::AbstractString = "1.0.0") =
    SchemaRef(:episteme, "document", version)

episteme_plan_schema(version::AbstractString = "1.0.0") =
    SchemaRef(:episteme, "plan", version)

"""
    OperationSpec(kind; inputs=(), outputs=(), effects=(), default_reuse=:forbid,
                  idempotency_key=nothing)

One domain-owned operation declaration used by a [`Plan`](@ref) or
[`ActivityRecord`](@ref). Episteme does not implement the operation.
`idempotency_key` is domain-owned data; it is never an [`ActivityId`](@ref).
"""
struct OperationSpec
    kind::Symbol
    inputs::Vector{Symbol}
    outputs::Vector{Symbol}
    effects::Tuple{Vararg{Symbol}}
    default_reuse::Symbol
    idempotency_key::Union{Nothing,String}
end

function OperationSpec(
    kind::Symbol;
    inputs = Symbol[],
    outputs = Symbol[],
    effects = (),
    default_reuse::Symbol = :forbid,
    idempotency_key = nothing,
)
    default_reuse in OPERATION_REUSE_POLICIES || throw(ArgumentError(
        "default_reuse must be one of $OPERATION_REUSE_POLICIES, got :$default_reuse",
    ))
    key = _optional_nonempty_string(idempotency_key)
    return OperationSpec(
        kind,
        collect(Symbol, inputs),
        collect(Symbol, outputs),
        Tuple(Symbol(effect) for effect in effects),
        default_reuse,
        key,
    )
end

function _optional_nonempty_string(value)
    value === nothing && return nothing
    value isa AbstractString ||
        throw(ArgumentError("expected String or nothing, got $(typeof(value))"))
    stripped = String(strip(value))
    return isempty(stripped) ? nothing : stripped
end

"""
    Plan(id; document_id=nothing, operations=(), schema=episteme_plan_schema())

Resolved executable recipe identified by [`PlanId`](@ref). Distinct from the
authored document and from a later [`RunRecord`](@ref).
"""
struct Plan
    id::PlanId
    document_id::Union{Nothing,DocumentId}
    operations::Vector{OperationSpec}
    schema::SchemaRef
end

function Plan(
    id::PlanId;
    document_id = nothing,
    operations = OperationSpec[],
    schema::SchemaRef = episteme_plan_schema(),
)
    schema_kind(schema) === EPISTEME_PLAN_KIND || throw(ArgumentError(
        "plan schema kind must be $EPISTEME_PLAN_KIND, got $(schema_kind(schema))",
    ))
    return Plan(
        id,
        _optional_id(DocumentId, document_id),
        _typed_vector(OperationSpec, operations, "operations"),
        schema,
    )
end

"""
    RevisionRecord(id; parents=(), run_id=nothing, plan_id=nothing)

Committed snapshot node. Object membership is derived via
[`find_objects`](@ref); this record does not store an object-id list.
`parents` may be empty (root), one parent (linear history), or several
(merge). Dangling parents and cycles fail `validate`.
"""
struct RevisionRecord
    id::RevisionId
    parents::Vector{RevisionId}
    run_id::Union{Nothing,RunId}
    plan_id::Union{Nothing,PlanId}
end

function RevisionRecord(
    id::RevisionId;
    parents = RevisionId[],
    run_id = nothing,
    plan_id = nothing,
)
    return RevisionRecord(
        id,
        _typed_vector(RevisionId, parents, "parents"),
        _optional_id(RunId, run_id),
        _optional_id(PlanId, plan_id),
    )
end

"""
    ActivityRecord(id, run_id, operation; idempotency_key=nothing, used=(),
                   generated=(), reuse=:computed)

One operation instance inside a run. `id` is bookkeeping; the optional
`idempotency_key` is domain-owned and is never the activity id.
"""
struct ActivityRecord
    id::ActivityId
    run_id::RunId
    operation::Symbol
    idempotency_key::Union{Nothing,String}
    used::Vector{ArchiveReference}
    generated::Vector{ArchiveReference}
    reuse::Symbol
end

function ActivityRecord(
    id::ActivityId,
    run_id::RunId,
    operation::Symbol;
    idempotency_key = nothing,
    used = ArchiveReference[],
    generated = ArchiveReference[],
    reuse::Symbol = :computed,
)
    reuse in ACTIVITY_REUSE_STATES || throw(ArgumentError(
        "reuse must be one of $ACTIVITY_REUSE_STATES, got :$reuse",
    ))
    return ActivityRecord(
        id,
        run_id,
        operation,
        _optional_nonempty_string(idempotency_key),
        _typed_vector(ArchiveReference, used, "used"),
        _typed_vector(ArchiveReference, generated, "generated"),
        reuse,
    )
end

"""
    RunRecord(id; plan_id=nothing, parent_run_id=nothing, revision_id=nothing,
              status=:queued, software_environment=nothing,
              execution_context=nothing, agent_id=nothing, activities=())

One execution of a plan. `revision_id` is `nothing` until a later `commit!`.
Activities live here; they are not duplicated on [`ArchiveGraph`](@ref).
"""
struct RunRecord
    id::RunId
    plan_id::Union{Nothing,PlanId}
    parent_run_id::Union{Nothing,RunId}
    revision_id::Union{Nothing,RevisionId}
    status::Symbol
    software_environment::Union{Nothing,SoftwareEnvironmentId}
    execution_context::Union{Nothing,ExecutionContextId}
    agent_id::Union{Nothing,AgentId}
    activities::Vector{ActivityRecord}
end

function RunRecord(
    id::RunId;
    plan_id = nothing,
    parent_run_id = nothing,
    revision_id = nothing,
    status::Symbol = :queued,
    software_environment = nothing,
    execution_context = nothing,
    agent_id = nothing,
    activities = ActivityRecord[],
)
    status in RUN_STATUSES || throw(ArgumentError(
        "status must be one of $RUN_STATUSES, got :$status",
    ))
    return RunRecord(
        id,
        _optional_id(PlanId, plan_id),
        _optional_id(RunId, parent_run_id),
        _optional_id(RevisionId, revision_id),
        status,
        _optional_id(SoftwareEnvironmentId, software_environment),
        _optional_id(ExecutionContextId, execution_context),
        _optional_id(AgentId, agent_id),
        _typed_vector(ActivityRecord, activities, "activities"),
    )
end

"""
    EventRecord(kind, run_id; activity_id=nothing, payload=(;))

Append-only timeline fact inside a run. Not a [`RevisionRecord`](@ref).
"""
struct EventRecord
    kind::Symbol
    run_id::RunId
    activity_id::Union{Nothing,ActivityId}
    payload::NamedTuple
end

function EventRecord(
    kind::Symbol,
    run_id::RunId;
    activity_id = nothing,
    payload::NamedTuple = (;),
)
    return EventRecord(kind, run_id, _optional_id(ActivityId, activity_id), payload)
end

function validate(plan::Plan)
    diagnostics = DiagnosticMessage[]
    for (i, spec) in enumerate(plan.operations)
        spec.kind === Symbol("") || continue
        push!(diagnostics, error_diagnostic(
            :empty_operation_kind,
            "plan operation $i has an empty kind";
            plan_id = plan.id.value,
            index = i,
        ))
    end
    return ValidationReport(
        EPISTEME_PLAN_KIND,
        isempty(diagnostics),
        diagnostics,
        (; plan_id = plan.id.value, operations = length(plan.operations)),
    )
end

to_namedtuple(spec::OperationSpec) = (
    kind = spec.kind,
    inputs = Tuple(spec.inputs),
    outputs = Tuple(spec.outputs),
    effects = spec.effects,
    default_reuse = spec.default_reuse,
    idempotency_key = spec.idempotency_key,
)

to_namedtuple(plan::Plan) = (
    id = plan.id.value,
    document_id = plan.document_id === nothing ? nothing : plan.document_id.value,
    operations = Tuple(to_namedtuple.(plan.operations)),
    schema = to_namedtuple(plan.schema),
)

to_namedtuple(rev::RevisionRecord) = (
    id = rev.id.value,
    parents = Tuple(parent.value for parent in rev.parents),
    run_id = rev.run_id === nothing ? nothing : rev.run_id.value,
    plan_id = rev.plan_id === nothing ? nothing : rev.plan_id.value,
)

to_namedtuple(activity::ActivityRecord) = (
    id = activity.id.value,
    run_id = activity.run_id.value,
    operation = activity.operation,
    idempotency_key = activity.idempotency_key,
    used = Tuple(to_namedtuple.(activity.used)),
    generated = Tuple(to_namedtuple.(activity.generated)),
    reuse = activity.reuse,
)

to_namedtuple(run::RunRecord) = (
    id = run.id.value,
    plan_id = run.plan_id === nothing ? nothing : run.plan_id.value,
    parent_run_id = run.parent_run_id === nothing ? nothing : run.parent_run_id.value,
    revision_id = run.revision_id === nothing ? nothing : run.revision_id.value,
    status = run.status,
    software_environment = run.software_environment === nothing ? nothing :
        run.software_environment.value,
    execution_context = run.execution_context === nothing ? nothing :
        run.execution_context.value,
    agent_id = run.agent_id === nothing ? nothing : run.agent_id.value,
    activities = Tuple(to_namedtuple.(run.activities)),
)

to_namedtuple(event::EventRecord) = (
    kind = event.kind,
    run_id = event.run_id.value,
    activity_id = event.activity_id === nothing ? nothing : event.activity_id.value,
    payload = event.payload,
)
