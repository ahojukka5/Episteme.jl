# ---------------------------------------------------------------------------
# Dual-history records: plan, run, activity, event, revision
#
# Structural types and the durable run/commit/restart contract (#27).
# No execute!/commit! runtime and no file I/O.
# ---------------------------------------------------------------------------

const EPISTEME_DOCUMENT_KIND = Symbol("episteme/document")
const EPISTEME_PLAN_KIND = Symbol("episteme/plan")

const OPERATION_REUSE_POLICIES = (:forbid, :allow_if_domain_says, :force_recompute)
const ACTIVITY_REUSE_STATES = (:computed, :reused, :forced)
const RUN_STATUSES = (
    :queued,
    :running,
    :completed,
    :failed,
    :interrupted,
    :cancelled,
    :uncertain,
)
const INCOMPLETE_RUN_STATUSES = (
    :queued,
    :running,
    :failed,
    :interrupted,
    :cancelled,
    :uncertain,
)
const RESTARTABLE_RUN_STATUSES = (:failed, :interrupted, :cancelled, :uncertain)
const STAGED_ORIGINS = (:generated, :reused)
const WRITE_PHASES = (:begin, :appending, :committing, :committed, :aborted, :uncertain)
const IN_FLIGHT_WRITE_PHASES = (:begin, :appending, :committing)
const WRITE_SCOPES = (:archive, :run)
const EVENT_SEVERITIES = (:debug, :info, :warn, :error)
const EVENT_RETENTION = (:ephemeral, :debug, :forensic, :pinned)
const LOG_STREAM_KINDS = (:stdout, :stderr, :trace)
const SECRET_NAME_MARKERS = (
    "password",
    "secret",
    "token",
    "api_key",
    "apikey",
    "authorization",
    "private_key",
    "privatekey",
    "cookie",
    "credential",
    "passwd",
)

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
    CheckpointRef(object_id; content_id=nothing, revision_id=nothing, kind=:checkpoint)

Exact scientific state required to restart. Domain packages decide what
the checkpoint *contains*; Episteme records which object/content/revision
must be present. Missing or mismatched identity fails closed.
"""
struct CheckpointRef
    object_id::ObjectId
    content_id::Union{Nothing,ContentId}
    revision_id::Union{Nothing,RevisionId}
    kind::Symbol
end

function CheckpointRef(
    object_id::ObjectId;
    content_id = nothing,
    revision_id = nothing,
    kind::Symbol = :checkpoint,
)
    return CheckpointRef(
        object_id,
        _optional_id(ContentId, content_id),
        _optional_id(RevisionId, revision_id),
        kind,
    )
end

"""
    RestartRequirement(; checkpoints=(), execution_context=nothing,
                       from_activity_id=nothing)

Declared restart contract for a run. Identifies the object/content and
optional execution context a later restart needs. Episteme does not guess
a checkpoint when this is absent.
"""
struct RestartRequirement
    checkpoints::Vector{CheckpointRef}
    execution_context::Union{Nothing,ExecutionContextId}
    from_activity_id::Union{Nothing,ActivityId}
end

function RestartRequirement(;
    checkpoints = CheckpointRef[],
    execution_context = nothing,
    from_activity_id = nothing,
)
    return RestartRequirement(
        _typed_vector(CheckpointRef, checkpoints, "checkpoints"),
        _optional_id(ExecutionContextId, execution_context),
        _optional_id(ActivityId, from_activity_id),
    )
end

"""
    StagedObject(object_id; namespace, kind, schema, origin=:generated,
                 content_id=nothing, source_revision_id=nothing,
                 activity_id=nothing, provenance=ProvenanceRefs(),
                 references=())

Run-local uncommitted snapshot envelope. Not an [`ArchiveObject`](@ref)
until a later `commit!` promotes it under a new [`RevisionId`](@ref).
`origin === :reused` copies identity from an existing committed version
and requires `source_revision_id`. If that source has a `ContentId`,
the staged row must keep the same id. Provenance and named references
are part of the envelope and must survive promotion.
"""
struct StagedObject
    object_id::ObjectId
    content_id::Union{Nothing,ContentId}
    namespace::ArchiveNamespace
    kind::Symbol
    schema::SchemaRef
    origin::Symbol
    source_revision_id::Union{Nothing,RevisionId}
    activity_id::Union{Nothing,ActivityId}
    provenance::ProvenanceRefs
    references::Vector{ArchiveReference}
end

function StagedObject(
    object_id::ObjectId;
    namespace::ArchiveNamespace,
    kind::Symbol,
    schema::SchemaRef,
    origin::Symbol = :generated,
    content_id = nothing,
    source_revision_id = nothing,
    activity_id = nothing,
    provenance::ProvenanceRefs = ProvenanceRefs(),
    references = ArchiveReference[],
)
    origin in STAGED_ORIGINS || throw(ArgumentError(
        "origin must be one of $STAGED_ORIGINS, got :$origin",
    ))
    origin === :reused && source_revision_id === nothing && throw(ArgumentError(
        "reused staged objects require source_revision_id",
    ))
    return StagedObject(
        object_id,
        _optional_id(ContentId, content_id),
        namespace,
        kind,
        schema,
        origin,
        _optional_id(RevisionId, source_revision_id),
        _optional_id(ActivityId, activity_id),
        provenance,
        _archive_references(references),
    )
end

"""
    WriteTransaction(; scope, phase, sequence, run_id=nothing, writer_token=nothing)

Logical begin/append/commit marker for durable history writes. This is
not a file handle and not an HDF5 transaction. v1 JLD2 persistence is
single-writer: at most one in-flight `:archive` transaction at a time.
`phase === :uncertain` is fail-closed (do not treat the write as
committed).
"""
struct WriteTransaction
    scope::Symbol
    phase::Symbol
    sequence::Int
    run_id::Union{Nothing,RunId}
    writer_token::Union{Nothing,String}
end

function WriteTransaction(;
    scope::Symbol,
    phase::Symbol,
    sequence::Integer,
    run_id = nothing,
    writer_token = nothing,
)
    scope in WRITE_SCOPES || throw(ArgumentError(
        "scope must be one of $WRITE_SCOPES, got :$scope",
    ))
    phase in WRITE_PHASES || throw(ArgumentError(
        "phase must be one of $WRITE_PHASES, got :$phase",
    ))
    Int(sequence) < 0 && throw(ArgumentError("write sequence must be non-negative"))
    scope === :run && run_id === nothing && throw(ArgumentError(
        "run-scoped write transactions require run_id",
    ))
    return WriteTransaction(
        scope,
        phase,
        Int(sequence),
        _optional_id(RunId, run_id),
        _optional_nonempty_string(writer_token),
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
              execution_context=nothing, agent_id=nothing, activities=(),
              staged=(), restart=nothing)

One execution of a plan. `revision_id` is `nothing` until a later `commit!`.
Activities and staged snapshot envelopes live here; they are not
duplicated on [`ArchiveGraph`](@ref). Incomplete statuses never name a
committed revision.
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
    staged::Vector{StagedObject}
    restart::Union{Nothing,RestartRequirement}
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
    staged = StagedObject[],
    restart = nothing,
)
    status in RUN_STATUSES || throw(ArgumentError(
        "status must be one of $RUN_STATUSES, got :$status",
    ))
    restart === nothing || restart isa RestartRequirement || throw(ArgumentError(
        "restart must be RestartRequirement or nothing, got $(typeof(restart))",
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
        _typed_vector(StagedObject, staged, "staged"),
        restart,
    )
end

"""
    EventRecord(kind, run_id; activity_id=nothing, sequence=nothing,
                source=nothing, severity=:info, message="", timestamp=nothing,
                scope=nothing, revision_id=nothing, object_refs=(),
                producer_id=nothing, execution_context=nothing,
                retention=:forensic, payload=(;))

Append-only timeline fact inside a run. Not a [`RevisionRecord`](@ref)
and not authoritative scientific state. `sequence` is the source-local
causal identity; `timestamp` is optional UTC metadata and is never the
only ordering primitive.
"""
struct EventRecord
    kind::Symbol
    run_id::RunId
    activity_id::Union{Nothing,ActivityId}
    sequence::Union{Nothing,Int}
    source::Union{Nothing,String}
    severity::Symbol
    message::String
    timestamp::Union{Nothing,String}
    scope::Union{Nothing,Symbol}
    revision_id::Union{Nothing,RevisionId}
    object_refs::Vector{ObjectRef}
    producer_id::Union{Nothing,AgentId}
    execution_context::Union{Nothing,ExecutionContextId}
    retention::Symbol
    payload::NamedTuple
end

function EventRecord(
    kind::Symbol,
    run_id::RunId;
    activity_id = nothing,
    sequence = nothing,
    source = nothing,
    severity::Symbol = :info,
    message::AbstractString = "",
    timestamp = nothing,
    scope = nothing,
    revision_id = nothing,
    object_refs = ObjectRef[],
    producer_id = nothing,
    execution_context = nothing,
    retention::Symbol = :forensic,
    payload::NamedTuple = (;),
)
    severity in EVENT_SEVERITIES || throw(ArgumentError(
        "severity must be one of $EVENT_SEVERITIES, got :$severity",
    ))
    retention in EVENT_RETENTION || throw(ArgumentError(
        "retention must be one of $EVENT_RETENTION, got :$retention",
    ))
    scope === nothing || scope isa Symbol || throw(ArgumentError(
        "scope must be a Symbol or nothing, got $(typeof(scope))",
    ))
    return EventRecord(
        kind,
        run_id,
        _optional_id(ActivityId, activity_id),
        _optional_sequence(sequence),
        _optional_nonempty_string(source),
        severity,
        String(message),
        _optional_nonempty_string(timestamp),
        scope,
        _optional_id(RevisionId, revision_id),
        _object_refs(object_refs),
        _optional_id(AgentId, producer_id),
        _optional_id(ExecutionContextId, execution_context),
        retention,
        payload,
    )
end

function _object_refs(values)
    refs = ObjectRef[]
    for value in values
        if value isa ObjectRef
            push!(refs, value)
        elseif value isa ObjectId
            push!(refs, ObjectRef(value))
        else
            throw(ArgumentError("object_refs must contain ObjectRef or ObjectId values"))
        end
    end
    return refs
end

"""
    EventBatch(events; write=nothing)

Logical grouping of timeline events published in one durable append.
v1 writers persist the batch in one metadata transaction, not one
transaction per event. Not a revision.
"""
struct EventBatch
    events::Vector{EventRecord}
    write::Union{Nothing,WriteTransaction}
end

function EventBatch(events; write = nothing)
    write === nothing || write isa WriteTransaction || throw(ArgumentError(
        "write must be WriteTransaction or nothing, got $(typeof(write))",
    ))
    return EventBatch(_typed_vector(EventRecord, events, "events"), write)
end

"""
    LogStreamRecord(run_id, kind; activity_id=nothing, source=nothing,
                    retention=:debug, content_id=nothing, summary=nothing)

Optional archived stdout/stderr/trace. Never authoritative scientific
state and never a substitute for typed provenance. Default retention
`:debug` is purgeable unless `:pinned` or `:forensic`.
"""
struct LogStreamRecord
    run_id::RunId
    kind::Symbol
    activity_id::Union{Nothing,ActivityId}
    source::Union{Nothing,String}
    retention::Symbol
    content_id::Union{Nothing,ContentId}
    summary::Union{Nothing,String}
end

function LogStreamRecord(
    run_id::RunId,
    kind::Symbol;
    activity_id = nothing,
    source = nothing,
    retention::Symbol = :debug,
    content_id = nothing,
    summary = nothing,
)
    kind in LOG_STREAM_KINDS || throw(ArgumentError(
        "log stream kind must be one of $LOG_STREAM_KINDS, got :$kind",
    ))
    retention in EVENT_RETENTION || throw(ArgumentError(
        "retention must be one of $EVENT_RETENTION, got :$retention",
    ))
    return LogStreamRecord(
        run_id,
        kind,
        _optional_id(ActivityId, activity_id),
        _optional_nonempty_string(source),
        retention,
        _optional_id(ContentId, content_id),
        _optional_nonempty_string(summary),
    )
end

function _optional_sequence(value)
    value === nothing && return nothing
    value isa Integer || throw(ArgumentError(
        "sequence must be an integer or nothing, got $(typeof(value))",
    ))
    Int(value) < 0 && throw(ArgumentError("event sequence must be non-negative"))
    return Int(value)
end

function _looks_like_secret_name(name::AbstractString)
    lowered = lowercase(name)
    return any(marker -> occursin(marker, lowered), SECRET_NAME_MARKERS)
end

function _looks_like_secret_value(text::AbstractString)
    occursin(r"-----BEGIN [A-Z ]*PRIVATE KEY-----", text) && return true
    occursin(r"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]{20,}", text) && return true
    occursin(r"(?i)\b(sk|ghp|gho|xox[baprs])-[A-Za-z0-9]{16,}", text) && return true
    return false
end

function _credential_like_diagnostics!(diagnostics, text, context)
    text === nothing && return diagnostics
    _looks_like_secret_value(text) || return diagnostics
    push!(diagnostics, error_diagnostic(
        :credential_like_content,
        "credential-like content is not allowed on the generic event/log path";
        context...,
    ))
    return diagnostics
end

function _validate_event_record!(diagnostics, event::EventRecord)
    _credential_like_diagnostics!(
        diagnostics,
        event.message,
        (; kind = event.kind, run_id = event.run_id.value, field = :message),
    )
    for name in keys(event.payload)
        if _looks_like_secret_name(String(name))
            push!(diagnostics, error_diagnostic(
                :credential_like_content,
                "payload key :$name looks like a secret name";
                kind = event.kind,
                run_id = event.run_id.value,
                field = name,
            ))
        end
        value = event.payload[name]
        value isa AbstractString || continue
        _credential_like_diagnostics!(
            diagnostics,
            value,
            (; kind = event.kind, run_id = event.run_id.value, field = name),
        )
    end
    return diagnostics
end

function validate(event::EventRecord)
    diagnostics = DiagnosticMessage[]
    _validate_event_record!(diagnostics, event)
    return ValidationReport(
        :event,
        isempty(diagnostics),
        diagnostics,
        (;
            kind = event.kind,
            run_id = event.run_id.value,
            sequence = event.sequence,
            severity = event.severity,
        ),
    )
end

function _validate_event_sequence_uniqueness!(diagnostics, events)
    seen = Dict{Tuple{String,String,Int},Symbol}()
    for event in events
        event.sequence === nothing && continue
        source = event.source === nothing ? "" : event.source
        key = (event.run_id.value, source, event.sequence)
        if haskey(seen, key)
            push!(diagnostics, error_diagnostic(
                :duplicate_event_sequence,
                "run $(event.run_id.value) has two events with sequence $(event.sequence)";
                run_id = event.run_id.value,
                source = event.source,
                sequence = event.sequence,
                kind = event.kind,
            ))
        else
            seen[key] = event.kind
        end
    end
    return diagnostics
end

function validate(batch::EventBatch)
    diagnostics = DiagnosticMessage[]
    write = batch.write
    write === nothing || _validate_write_transaction!(diagnostics, write)
    isempty(batch.events) && return ValidationReport(
        :event_batch,
        isempty(diagnostics),
        diagnostics,
        (; count = 0, write_sequence = write === nothing ? nothing : write.sequence),
    )
    run_id = batch.events[1].run_id
    for event in batch.events
        _validate_event_record!(diagnostics, event)
        event.run_id == run_id && continue
        push!(diagnostics, error_diagnostic(
            :event_batch_run_mismatch,
            "event batch mixes run $(run_id.value) with $(event.run_id.value)";
            run_id = run_id.value,
            other_run_id = event.run_id.value,
            kind = event.kind,
        ))
    end
    _validate_event_sequence_uniqueness!(diagnostics, batch.events)
    if write !== nothing
        if write.scope !== :run
            push!(diagnostics, error_diagnostic(
                :event_batch_write_scope,
                "event batch write must be run-scoped, got :$(write.scope)";
                scope = write.scope,
            ))
        elseif write.run_id !== nothing && write.run_id != run_id
            push!(diagnostics, error_diagnostic(
                :event_batch_write_run_mismatch,
                "event batch write names run $(write.run_id.value), not $(run_id.value)";
                run_id = run_id.value,
                write_run_id = write.run_id.value,
            ))
        end
    end
    return ValidationReport(
        :event_batch,
        isempty(diagnostics),
        diagnostics,
        (;
            run_id = run_id.value,
            count = length(batch.events),
            write_sequence = write === nothing ? nothing : write.sequence,
        ),
    )
end

function validate(stream::LogStreamRecord)
    diagnostics = DiagnosticMessage[]
    _credential_like_diagnostics!(
        diagnostics,
        stream.summary,
        (; kind = stream.kind, run_id = stream.run_id.value, field = :summary),
    )
    return ValidationReport(
        :log_stream,
        isempty(diagnostics),
        diagnostics,
        (;
            kind = stream.kind,
            run_id = stream.run_id.value,
            retention = stream.retention,
        ),
    )
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

function validate(staged::StagedObject)
    diagnostics = DiagnosticMessage[]
    _validate_staged_object!(diagnostics, staged)
    return ValidationReport(
        staged.kind,
        isempty(diagnostics),
        diagnostics,
        (; object_id = staged.object_id.value, origin = staged.origin),
    )
end

function validate(run::RunRecord)
    diagnostics = DiagnosticMessage[]
    _validate_run_record!(diagnostics, run)
    return ValidationReport(
        :run,
        isempty(diagnostics),
        diagnostics,
        (;
            run_id = run.id.value,
            status = run.status,
            revision_id = run.revision_id === nothing ? nothing : run.revision_id.value,
            staged = length(run.staged),
        ),
    )
end

function validate(tx::WriteTransaction)
    diagnostics = DiagnosticMessage[]
    _validate_write_transaction!(diagnostics, tx)
    return ValidationReport(
        :write_transaction,
        isempty(diagnostics),
        diagnostics,
        (; scope = tx.scope, phase = tx.phase, sequence = tx.sequence),
    )
end

function _validate_staged_object!(diagnostics, staged::StagedObject)
    prefix = String(staged.namespace.id) * "/"
    startswith(String(staged.kind), prefix) || push!(diagnostics, error_diagnostic(
        :kind_namespace_mismatch,
        "kind $(staged.kind) is not owned by namespace :$(staged.namespace.id)";
        object_id = staged.object_id.value,
        kind = staged.kind,
        namespace = staged.namespace.id,
    ))
    staged.schema.namespace_id == staged.namespace.id || push!(
        diagnostics,
        error_diagnostic(
            :schema_namespace_mismatch,
            "schema namespace :$(staged.schema.namespace_id) does not match object namespace :$(staged.namespace.id)";
            object_id = staged.object_id.value,
            schema_namespace = staged.schema.namespace_id,
            namespace = staged.namespace.id,
        ),
    )
    schema_kind(staged.schema) == staged.kind || push!(diagnostics, error_diagnostic(
        :schema_kind_mismatch,
        "schema $(schema_kind(staged.schema)) does not match kind $(staged.kind)";
        object_id = staged.object_id.value,
        schema_kind = schema_kind(staged.schema),
        kind = staged.kind,
    ))
    if staged.origin === :reused && staged.source_revision_id === nothing
        push!(diagnostics, error_diagnostic(
            :reused_without_source,
            "reused staged object $(staged.object_id.value) has no source_revision_id";
            object_id = staged.object_id.value,
        ))
    end
    return diagnostics
end

function _validate_run_record!(diagnostics, run::RunRecord)
    if run.revision_id !== nothing && run.status in INCOMPLETE_RUN_STATUSES
        code = run.status === :uncertain ? :uncertain_run_has_revision :
            :incomplete_run_has_revision
        push!(diagnostics, error_diagnostic(
            code,
            "run $(run.id.value) status :$(run.status) must not name a committed revision";
            run_id = run.id.value,
            status = run.status,
            revision_id = run.revision_id.value,
        ))
    end
    seen_staged = String[]
    for staged in run.staged
        _validate_staged_object!(diagnostics, staged)
        if staged.object_id.value in seen_staged
            push!(diagnostics, error_diagnostic(
                :duplicate_staged_object,
                "run $(run.id.value) stages object $(staged.object_id.value) more than once";
                run_id = run.id.value,
                object_id = staged.object_id.value,
            ))
        else
            push!(seen_staged, staged.object_id.value)
        end
        staged.activity_id === nothing && continue
        any(activity -> activity.id == staged.activity_id, run.activities) && continue
        push!(diagnostics, error_diagnostic(
            :missing_staged_activity,
            "staged object $(staged.object_id.value) names unknown activity $(staged.activity_id.value)";
            run_id = run.id.value,
            object_id = staged.object_id.value,
            activity_id = staged.activity_id.value,
        ))
    end
    req = run.restart
    if req !== nothing && req.from_activity_id !== nothing
        if !any(activity -> activity.id == req.from_activity_id, run.activities)
            push!(diagnostics, error_diagnostic(
                :missing_restart_activity,
                "run $(run.id.value) restart names unknown activity $(req.from_activity_id.value)";
                run_id = run.id.value,
                activity_id = req.from_activity_id.value,
            ))
        end
    end
    return diagnostics
end

function _validate_write_transaction!(diagnostics, tx::WriteTransaction)
    if tx.phase in IN_FLIGHT_WRITE_PHASES && tx.writer_token === nothing
        push!(diagnostics, error_diagnostic(
            :missing_writer_token,
            "$(tx.scope) write sequence $(tx.sequence) is in flight without a writer token";
            scope = tx.scope,
            phase = tx.phase,
            sequence = tx.sequence,
        ))
    end
    return diagnostics
end

"""
    promote_staged(run, revision_id) -> Vector{ArchiveObject}

Pure mapping of a run's staging set into envelope rows for `revision_id`.
Does not mutate the run, move a head, or write a file. Later `commit!`
uses this promotion; this helper exists so the contract is testable now.
"""
function promote_staged(run::RunRecord, revision_id::RevisionId)
    objects = ArchiveObject[]
    for staged in run.staged
        push!(objects, ArchiveObject(
            staged.object_id,
            revision_id;
            content_id = staged.content_id,
            run_id = run.id,
            namespace = staged.namespace,
            kind = staged.kind,
            schema = staged.schema,
            provenance = staged.provenance,
            references = staged.references,
        ))
    end
    return objects
end

function report(run::RunRecord)
    committed = run.revision_id !== nothing
    return ObjectReport(
        :run,
        "Run $(run.id.value) status=:$(run.status) committed=$committed.",
        (;
            run_id = run.id.value,
            status = run.status,
            revision_id = run.revision_id === nothing ? nothing : run.revision_id.value,
            staged = length(run.staged),
            activities = length(run.activities),
            committed = committed,
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function readiness(run::RunRecord, target::PipelineTarget)
    if target.name === :commit
        return _run_commit_readiness(run)
    elseif target.name === :restart
        return _run_restart_readiness(run)
    end
    return ReadinessReport(
        :run,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "run readiness target :$(target.name) is not :commit or :restart";
            run_id = run.id.value,
            target = target.name,
        )],
        (; run_id = run.id.value, status = run.status),
    )
end

function _run_commit_readiness(run::RunRecord)
    target = PipelineTarget(:commit)
    diagnostics = DiagnosticMessage[]
    if run.status !== :completed
        push!(diagnostics, error_diagnostic(
            :run_not_completed,
            "run $(run.id.value) status :$(run.status) is not ready to commit";
            run_id = run.id.value,
            status = run.status,
        ))
    end
    if run.revision_id !== nothing
        push!(diagnostics, error_diagnostic(
            :run_already_committed,
            "run $(run.id.value) already names revision $(run.revision_id.value)";
            run_id = run.id.value,
            revision_id = run.revision_id.value,
        ))
    end
    if run.status === :uncertain
        push!(diagnostics, error_diagnostic(
            :uncertain_side_effect,
            "run $(run.id.value) has uncertain durable side effects; commit is fail-closed";
            run_id = run.id.value,
        ))
    end
    return ReadinessReport(
        :run,
        target,
        isempty(diagnostics),
        diagnostics,
        (; run_id = run.id.value, status = run.status, staged = length(run.staged)),
    )
end

function _run_restart_readiness(run::RunRecord)
    target = PipelineTarget(:restart)
    diagnostics = DiagnosticMessage[]
    if run.revision_id !== nothing
        push!(diagnostics, error_diagnostic(
            :run_already_committed,
            "run $(run.id.value) already committed revision $(run.revision_id.value)";
            run_id = run.id.value,
            revision_id = run.revision_id.value,
        ))
    end
    if !(run.status in RESTARTABLE_RUN_STATUSES)
        push!(diagnostics, error_diagnostic(
            :run_not_restartable,
            "run $(run.id.value) status :$(run.status) is not a restartable incomplete state";
            run_id = run.id.value,
            status = run.status,
        ))
    end
    if run.restart === nothing
        push!(diagnostics, error_diagnostic(
            :restart_not_declared,
            "run $(run.id.value) does not declare a restart requirement";
            run_id = run.id.value,
        ))
    elseif isempty(run.restart.checkpoints)
        push!(diagnostics, error_diagnostic(
            :restart_not_declared,
            "run $(run.id.value) restart requirement lists no checkpoints";
            run_id = run.id.value,
        ))
    end
    return ReadinessReport(
        :run,
        target,
        isempty(diagnostics),
        diagnostics,
        (;
            run_id = run.id.value,
            status = run.status,
            checkpoints = run.restart === nothing ? 0 : length(run.restart.checkpoints),
        ),
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

to_namedtuple(checkpoint::CheckpointRef) = (
    object_id = checkpoint.object_id.value,
    content_id = checkpoint.content_id === nothing ? nothing : checkpoint.content_id.value,
    revision_id = checkpoint.revision_id === nothing ? nothing : checkpoint.revision_id.value,
    kind = checkpoint.kind,
)

to_namedtuple(req::RestartRequirement) = (
    checkpoints = Tuple(to_namedtuple.(req.checkpoints)),
    execution_context = req.execution_context === nothing ? nothing :
        req.execution_context.value,
    from_activity_id = req.from_activity_id === nothing ? nothing :
        req.from_activity_id.value,
)

to_namedtuple(staged::StagedObject) = (
    object_id = staged.object_id.value,
    content_id = staged.content_id === nothing ? nothing : staged.content_id.value,
    namespace = to_namedtuple(staged.namespace),
    kind = staged.kind,
    schema = to_namedtuple(staged.schema),
    origin = staged.origin,
    source_revision_id = staged.source_revision_id === nothing ? nothing :
        staged.source_revision_id.value,
    activity_id = staged.activity_id === nothing ? nothing : staged.activity_id.value,
    provenance = to_namedtuple(staged.provenance),
    references = Tuple(to_namedtuple.(staged.references)),
)

to_namedtuple(tx::WriteTransaction) = (
    scope = tx.scope,
    phase = tx.phase,
    sequence = tx.sequence,
    run_id = tx.run_id === nothing ? nothing : tx.run_id.value,
    writer_token = tx.writer_token,
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
    staged = Tuple(to_namedtuple.(run.staged)),
    restart = run.restart === nothing ? nothing : to_namedtuple(run.restart),
)

to_namedtuple(event::EventRecord) = (
    kind = event.kind,
    run_id = event.run_id.value,
    activity_id = event.activity_id === nothing ? nothing : event.activity_id.value,
    sequence = event.sequence,
    source = event.source,
    severity = event.severity,
    message = event.message,
    timestamp = event.timestamp,
    scope = event.scope,
    revision_id = event.revision_id === nothing ? nothing : event.revision_id.value,
    object_refs = Tuple(to_namedtuple.(event.object_refs)),
    producer_id = event.producer_id === nothing ? nothing : event.producer_id.value,
    execution_context = event.execution_context === nothing ? nothing :
        event.execution_context.value,
    retention = event.retention,
    payload = event.payload,
)

to_namedtuple(batch::EventBatch) = (
    events = Tuple(to_namedtuple.(batch.events)),
    write = batch.write === nothing ? nothing : to_namedtuple(batch.write),
    count = length(batch.events),
)

to_namedtuple(stream::LogStreamRecord) = (
    run_id = stream.run_id.value,
    kind = stream.kind,
    activity_id = stream.activity_id === nothing ? nothing : stream.activity_id.value,
    source = stream.source,
    retention = stream.retention,
    content_id = stream.content_id === nothing ? nothing : stream.content_id.value,
    summary = stream.summary,
)
