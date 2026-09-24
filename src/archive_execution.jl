# ---------------------------------------------------------------------------
# In-memory execution lifecycle (#107)
#
# plan → readiness → execute → stage → validate → commit
# execute! never moves a head. commit! is the only head-mover.
# Domain packages bind behavior with apply_operation(::Val{kind}, ...).
# ---------------------------------------------------------------------------

const WORKFLOW_EVENT_KINDS = (
    :planned,
    :started,
    :staged,
    :validation_failed,
    :committed,
    :failed,
    :restarted,
)
const COMMIT_INTERRUPT_PHASES = (
    :begin,
    :appending,
    :objects,
    :revision,
    :run,
    :head,
)
const EXECUTE_INTERRUPT_PHASES = (:before_operation, :after_staging, :before_complete)
const OPERATION_OUTCOMES = (:completed, :failed, :reused)

"""
    WorkingStore()

Session-local payload map. Archive envelopes never store domain bytes;
this store keeps live values keyed by object identity, then by
`object@revision` after commit.
"""
struct WorkingStore
    payloads::Dict{String,Any}
end

WorkingStore() = WorkingStore(Dict{String,Any}())

_payload_key(object_id::ObjectId) = object_id.value
_payload_key(object_id::ObjectId, revision_id::RevisionId) =
    object_id.value * "@" * revision_id.value

function store_payload!(store::WorkingStore, object_id::ObjectId, payload; revision_id = nothing)
    store.payloads[_payload_key(object_id)] = payload
    revision_id === nothing || (store.payloads[_payload_key(object_id, revision_id)] = payload)
    return payload
end

"""
    fetch_payload(store, object_id; revision_id=nothing)

Return the stored domain payload for `object_id`.

When `revision_id` is set, only the revision-keyed payload is returned.
A missing exact revision does not fall back to the moving payload stored
under the bare ObjectId.
"""
function fetch_payload(store::WorkingStore, object_id::ObjectId; revision_id = nothing)
    if revision_id !== nothing
        return get(store.payloads, _payload_key(object_id, revision_id), nothing)
    end
    return get(store.payloads, object_id.value, nothing)
end

"""
    BoundInput

Resolved identity-bound input for one operation role. `object` is a
committed envelope; `staged` is a same-run uncommitted product.
"""
struct BoundInput
    role::Symbol
    object::Union{Nothing,ArchiveObject}
    staged::Union{Nothing,StagedObject}
    content_id::Union{Nothing,ContentId}
    payload
    artifact::Union{Nothing,ArtifactRef}
end

"""
    StagedPayload(staged, payload)

One staged envelope plus the domain payload that produced it.
"""
struct StagedPayload
    staged::StagedObject
    payload
end

"""
    OperationOutcome(; status=:completed, outputs=(), restart=nothing,
                     diagnostics=(), message="")

Result of [`apply_operation`](@ref). Episteme records this; it does not
interpret the payload.
"""
struct OperationOutcome
    status::Symbol
    outputs::Vector{StagedPayload}
    restart::Union{Nothing,RestartRequirement}
    diagnostics::Vector{DiagnosticMessage}
    message::String
end

function OperationOutcome(;
    status::Symbol = :completed,
    outputs = StagedPayload[],
    restart = nothing,
    diagnostics = DiagnosticMessage[],
    message::AbstractString = "",
)
    status in OPERATION_OUTCOMES || throw(ArgumentError(
        "operation outcome status must be one of $OPERATION_OUTCOMES, got :$status",
    ))
    restart === nothing || restart isa RestartRequirement || throw(ArgumentError(
        "restart must be RestartRequirement or nothing",
    ))
    return OperationOutcome(
        status,
        _typed_vector(StagedPayload, outputs, "outputs"),
        restart,
        _typed_vector(DiagnosticMessage, diagnostics, "diagnostics"),
        String(message),
    )
end

"""
    ExecutionInterrupted(phase, run_id)

Test and recovery hook. `execute!` / `commit!` throw this after recording
the named phase so `recover_writes!` can be exercised.
"""
struct ExecutionInterrupted <: Exception
    phase::Symbol
    run_id::RunId
end

function Base.showerror(io::IO, err::ExecutionInterrupted)
    print(io, "ExecutionInterrupted(:$(err.phase), ", err.run_id, ")")
end

"""
    RecoveryReport

Structured result of [`recover_writes!`](@ref).
"""
struct RecoveryReport <: AbstractValidationReport
    valid::Bool
    writes::Vector{WriteTransaction}
    diagnostics::Vector{DiagnosticMessage}
    metadata::NamedTuple
end

Base.isvalid(report::RecoveryReport) = report.valid

"""
    apply_operation(spec, inputs; context...)

Dispatch hook for domain packages. Add methods on
`apply_operation(::Val{kind}, spec, inputs; context...)` where `kind` is
the operation's `Symbol`. Episteme never serializes Julia functions.
"""
function apply_operation(spec::OperationSpec, inputs; context...)
    return apply_operation(Val(spec.kind), spec, inputs; context...)
end

function apply_operation(::Val{kind}, spec::OperationSpec, inputs; context...) where {kind}
    return OperationOutcome(;
        status = :failed,
        diagnostics = [error_diagnostic(
            :unknown_operation,
            "no apply_operation method is bound for $(spec.kind)",
            operation = spec.kind,
            name = spec.name,
        )],
        message = "unknown operation $(spec.kind)",
    )
end

"""
    reuse_equivalent(::Val{kind}, spec, activity)

Domain hook for `:allow_if_domain_says`. The default is fail-closed
(`false`): Episteme does not guess scientific equivalence.
"""
reuse_equivalent(::Val, spec::OperationSpec, activity::ActivityRecord) = false

"""
    staged_result(object_id; namespace, kind, schema, payload, kwargs...)

Domain helper: wrap a payload as a staged envelope without committing it.
"""
function staged_result(
    object_id::ObjectId,
    payload;
    namespace::ArchiveNamespace,
    kind::Symbol,
    schema::SchemaRef,
    content_id = nothing,
    origin::Symbol = :generated,
    source_revision_id = nothing,
    provenance::ProvenanceRefs = ProvenanceRefs(),
    references = ArchiveReference[],
)
    return StagedPayload(
        StagedObject(
            object_id;
            namespace = namespace,
            kind = kind,
            schema = schema,
            origin = origin,
            content_id = content_id,
            source_revision_id = source_revision_id,
            provenance = provenance,
            references = references,
        ),
        payload,
    )
end

function plan_roots(plan::Plan)
    produced = Set{Symbol}()
    for spec in plan.operations
        for role in spec.outputs
            push!(produced, role)
        end
    end
    roots = PlanBinding[]
    for binding in plan.bindings
        binding.source === nothing || continue
        push!(roots, binding)
    end
    for spec in plan.operations
        for role in spec.inputs
            any(b -> b.role === role, plan.bindings) && continue
            role in produced && continue
            push!(roots, PlanBinding(role))
        end
    end
    return roots
end

function plan_binding(plan::Plan, role::Symbol; source = :any)
    for binding in plan.bindings
        binding.role === role || continue
        source === :any && return binding
        binding.source == source && return binding
    end
    return nothing
end

function plan_output_id(plan::Plan, spec::OperationSpec, role::Symbol)
    binding = plan_binding(plan, role; source = spec.name)
    binding === nothing && (binding = plan_binding(plan, role))
    if binding !== nothing && binding.object_id !== nothing
        return binding.object_id
    end
    return ObjectId(string(UUIDs.uuid4()))
end

function _producer_of(plan::Plan, role::Symbol)
    matches = [binding for binding in plan.bindings if binding.role === role]
    length(matches) > 1 && throw(ArgumentError(
        "role :$role has $(length(matches)) bindings",
    ))
    producers = Symbol[spec.name for spec in plan.operations if role in spec.outputs]
    length(producers) > 1 && throw(ArgumentError(
        "role :$role is produced by $(join(string.(producers), ", "))",
    ))
    if !isempty(matches)
        source = matches[1].source
        if source !== nothing && any(spec.name === source for spec in plan.operations)
            source in producers || throw(ArgumentError(
                "role :$role is bound to :$source, which does not produce it",
            ))
        end
        return source
    end
    return isempty(producers) ? nothing : producers[1]
end

"""
    plan_operation_order(plan) -> Vector{OperationSpec}

Inspectable dependency order. Cycles fail `validate`/`readiness`.
"""
function plan_operation_order(plan::Plan)
    _plan_resolution_ambiguous(plan) && throw(ArgumentError(
        "plan $(plan.id.value) has an ambiguous role binding or producer",
    ))
    names = [spec.name for spec in plan.operations]
    index = Dict{Symbol,Int}(spec.name => i for (i, spec) in enumerate(plan.operations))
    indeg = zeros(Int, length(plan.operations))
    children = [Int[] for _ in plan.operations]
    for spec in plan.operations
        dst = index[spec.name]
        for role in spec.inputs
            source = _producer_of(plan, role)
            source === nothing && continue
            haskey(index, source) || continue
            src = index[source]
            src == dst && continue
            push!(children[src], dst)
            indeg[dst] += 1
        end
    end
    queue = Int[i for i in eachindex(plan.operations) if indeg[i] == 0]
    order = OperationSpec[]
    while !isempty(queue)
        i = popfirst!(queue)
        push!(order, plan.operations[i])
        for dst in children[i]
            indeg[dst] -= 1
            indeg[dst] == 0 && push!(queue, dst)
        end
    end
    return order
end

function _plan_has_cycle(plan::Plan)
    return length(plan_operation_order(plan)) != length(plan.operations)
end

function _plan_resolution_ambiguous(plan::Plan)
    report = validate(plan)
    return any(d -> d.code in (
        :ambiguous_producer, :ambiguous_binding, :binding_role_mismatch,
    ), report.diagnostics)
end

function report(plan::Plan)
    ambiguous = _plan_resolution_ambiguous(plan)
    order = ambiguous ? OperationSpec[] : plan_operation_order(plan)
    return ObjectReport(
        EPISTEME_PLAN_KIND,
        "Plan $(plan.id.value) with $(length(plan.operations)) operations.",
        (;
            plan_id = plan.id.value,
            operations = Tuple(spec.name for spec in plan.operations),
            order = Tuple(spec.name for spec in order),
            roots = Tuple(b.role for b in plan_roots(plan)),
            cyclic = !ambiguous && length(order) != length(plan.operations),
        ),
        DiagnosticMessage[],
        ArtifactRef[],
    )
end

function readiness(plan::Plan, target::PipelineTarget)
    diagnostics = DiagnosticMessage[]
    validation = validate(plan)
    append!(diagnostics, validation.diagnostics)
    if target.name !== :execute && target.name !== :inspect
        push!(diagnostics, error_diagnostic(
            :unsupported_target,
            "plan readiness target :$(target.name) is not :execute or :inspect",
            plan_id = plan.id.value,
            target = target.name,
        ))
    end
    if isvalid(validation) && _plan_has_cycle(plan)
        push!(diagnostics, error_diagnostic(
            :plan_cycle,
            "plan $(plan.id.value) has a cyclic operation dependency",
            plan_id = plan.id.value,
        ))
    end
    return ReadinessReport(
        EPISTEME_PLAN_KIND,
        target,
        isempty(diagnostics),
        diagnostics,
        (; plan_id = plan.id.value, operations = length(plan.operations)),
    )
end

function _graph_execute_readiness(graph::ArchiveGraph, target::PipelineTarget)
    plan = get(target.options, :plan, nothing)
    if !(plan isa Plan)
        return ReadinessReport(
            :archive_graph,
            target,
            false,
            [error_diagnostic(
                :missing_execute_plan,
                "execute readiness requires a Plan in the target options",
            )],
            (;),
        )
    end
    return readiness(plan, graph, PipelineTarget(:execute; target.options...))
end

function readiness(plan::Plan, graph::ArchiveGraph, target::PipelineTarget)
    local_report = readiness(plan, PipelineTarget(target.name))
    diagnostics = DiagnosticMessage[local_report.diagnostics...]
    store = get(target.options, :store, WorkingStore())
    store isa WorkingStore || (store = WorkingStore())
    head = _head_from_options(graph, target)
    dummy = OperationSpec(Symbol("episteme/root-check"))
    for binding in plan_roots(plan)
        port = OperationPort(
            binding.role;
            kind = binding.kind,
            schema = binding.schema,
            required = binding.required,
        )
        bound = _resolve_root_input(
            graph,
            store,
            dummy,
            binding.role,
            port,
            binding,
            head,
            DiagnosticMessage[],
        )
        append!(diagnostics, bound.diagnostics)
    end
    _append_writer_diagnostics!(diagnostics, graph)
    return ReadinessReport(
        EPISTEME_PLAN_KIND,
        target,
        !any(d -> d.severity === :error, diagnostics),
        diagnostics,
        (;
            plan_id = plan.id.value,
            operations = length(plan.operations),
            objects = length(graph.objects),
        ),
    )
end

function _head_from_options(graph::ArchiveGraph, target::PipelineTarget)
    raw = get(target.options, :head, nothing)
    raw === nothing && return nothing
    raw isa WorkflowHead && return raw
    raw isa WorkflowHeadId && return find_head(graph, raw)
    raw isa Symbol && return find_head(graph, raw)
    return nothing
end

function _append_writer_diagnostics!(diagnostics, graph::ArchiveGraph)
    for write in graph.writes
        write.scope === :archive || continue
        write.phase in IN_FLIGHT_WRITE_PHASES || write.phase === :uncertain || continue
        push!(diagnostics, error_diagnostic(
            write.phase === :uncertain ? :uncertain_side_effect : :in_flight_write,
            "archive has an in-flight :$(write.phase) writer; v1 is single-writer",
            scope = write.scope,
            phase = write.phase,
        ))
    end
    return diagnostics
end

struct _ResolvedInput
    input::Union{Nothing,BoundInput}
    diagnostics::Vector{DiagnosticMessage}
end

function _resolve_input(
    plan::Plan,
    graph::ArchiveGraph,
    store::WorkingStore,
    spec::OperationSpec,
    role::Symbol,
    port::OperationPort,
    head,
)
    diagnostics = DiagnosticMessage[]
    binding = plan_binding(plan, role)
    producer = _producer_of(plan, role)
    if producer !== nothing && producer != spec.name
        staged = _staged_for_role(graph, plan, role)
        if staged !== nothing
            payload = fetch_payload(store, staged.object_id)
            return _ResolvedInput(
                BoundInput(role, nothing, staged, staged.content_id, payload, nothing),
                diagnostics,
            )
        end
        if port.required
            push!(diagnostics, error_diagnostic(
                :incomplete_dependency,
                "operation :$(spec.name) input :$role is not yet staged by :$producer",
                operation = spec.name,
                role = role,
                producer = producer,
            ))
        end
        return _ResolvedInput(nothing, diagnostics)
    end
    return _resolve_root_input(graph, store, spec, role, port, binding, head, diagnostics)
end

function _staged_for_role(graph::ArchiveGraph, plan::Plan, role::Symbol)
    binding = plan_binding(plan, role)
    binding === nothing && return nothing
    binding.object_id === nothing && return nothing
    for run in graph.runs
        run.revision_id === nothing || continue
        for staged in run.staged
            staged.object_id == binding.object_id && return staged
        end
    end
    return nothing
end

function _resolve_root_input(
    graph::ArchiveGraph,
    store::WorkingStore,
    spec::OperationSpec,
    role::Symbol,
    port::OperationPort,
    binding,
    head,
    diagnostics,
)
    if binding === nothing
        port.required && push!(diagnostics, error_diagnostic(
            :missing_input,
            "operation :$(spec.name) has no binding for required input :$role",
            operation = spec.name,
            role = role,
        ))
        return _ResolvedInput(nothing, diagnostics)
    end
    expected_schema = port.schema === nothing ? binding.schema : port.schema
    expected_kind = port.kind === nothing ? binding.kind : port.kind
    object = _find_bound_object(graph, binding, head)
    if object === nothing
        if binding.artifact !== nothing
            artifact_diag = _verify_external_artifact(binding)
            append!(diagnostics, artifact_diag)
            isempty(artifact_diag) || return _ResolvedInput(nothing, diagnostics)
            payload = fetch_payload(store, something(binding.object_id, ObjectId("external-$role")))
            return _ResolvedInput(
                BoundInput(role, nothing, nothing, binding.content_id, payload, binding.artifact),
                diagnostics,
            )
        end
        if port.required || binding.required
            if binding.object_id === nothing
                push!(diagnostics, error_diagnostic(
                    :missing_input,
                    "operation :$(spec.name) required input :$role has no object identity",
                    operation = spec.name,
                    role = role,
                ))
            else
                push!(diagnostics, error_diagnostic(
                    :unresolved_reference,
                    "operation :$(spec.name) input :$role references missing object $(binding.object_id.value)",
                    operation = spec.name,
                    role = role,
                    object_id = binding.object_id.value,
                    revision_id = binding.revision_id === nothing ? nothing :
                        binding.revision_id.value,
                ))
            end
        end
        return _ResolvedInput(nothing, diagnostics)
    end
    _append_identity_mismatch!(
        diagnostics, graph, spec, role, binding, object, head, expected_schema, expected_kind,
    )
    payload = if binding.revision_id !== nothing
        fetch_payload(store, object.object_id; revision_id = binding.revision_id)
    else
        fetch_payload(store, object.object_id)
    end
    if binding.revision_id !== nothing && payload === nothing
        push!(diagnostics, error_diagnostic(
            :missing_revision_payload,
            "operation :$(spec.name) input :$role has no payload for $(object.object_id.value)@$(binding.revision_id.value)",
            operation = spec.name,
            role = role,
            object_id = object.object_id.value,
            revision_id = binding.revision_id.value,
        ))
        return _ResolvedInput(nothing, diagnostics)
    end
    if binding.artifact !== nothing
        append!(diagnostics, _verify_external_artifact(binding))
    end
    if spec.validation_target !== nothing && payload !== nothing
        _append_payload_validation!(diagnostics, spec, role, payload)
    end
    if spec.readiness_target !== nothing && payload !== nothing
        _append_payload_readiness!(diagnostics, spec, role, payload)
    end
    return _ResolvedInput(
        BoundInput(role, object, nothing, object.content_id, payload, binding.artifact),
        diagnostics,
    )
end

function _find_bound_object(graph::ArchiveGraph, binding::PlanBinding, head)
    binding.object_id === nothing && return nothing
    if binding.revision_id !== nothing
        return find_object(graph, binding.object_id, binding.revision_id)
    end
    if head !== nothing
        visible = find_objects(graph, head.revision_id)
        for object in visible
            object.object_id == binding.object_id && return object
        end
        # Walk ancestors of the head so a later revision can reuse identity.
        rec = find_revision(graph, head.revision_id)
        if rec !== nothing
            for ancestor in revision_ancestors(graph, rec.id)
                for object in find_objects(graph, ancestor.id)
                    object.object_id == binding.object_id && return object
                end
            end
        end
    end
    matches = ArchiveObject[]
    for object in graph.objects
        object.object_id == binding.object_id && push!(matches, object)
    end
    isempty(matches) && return nothing
    length(matches) == 1 && return matches[1]
    return nothing
end

function _append_identity_mismatch!(
    diagnostics,
    graph::ArchiveGraph,
    spec,
    role,
    binding::PlanBinding,
    object::ArchiveObject,
    head,
    expected_schema,
    expected_kind,
)
    head_object = nothing
    if head !== nothing
        head_object = find_object(graph, object.object_id, head.revision_id)
        if head_object === nothing
            for ancestor in revision_ancestors(graph, head.revision_id)
                head_object = find_object(graph, object.object_id, ancestor.id)
                head_object === nothing || break
            end
        end
    end
    if binding.revision_id !== nothing && head_object !== nothing &&
            head_object.revision_id != binding.revision_id
        produced_from = _producer_revision(head_object)
        push!(diagnostics, error_diagnostic(
            :wrong_revision,
            _head_revision_message(spec, role, binding, head_object, head, produced_from);
            operation = spec.name,
            role = role,
            object_id = object.object_id.value,
            required_revision_id = binding.revision_id.value,
            head_revision_id = head_object.revision_id.value,
            head_name = head === nothing ? nothing : head.name,
            produced_from_revision_id = produced_from === nothing ? nothing : produced_from.value,
        ))
    elseif binding.revision_id !== nothing && object.revision_id != binding.revision_id
        push!(diagnostics, error_diagnostic(
            :wrong_revision,
            "operation :$(spec.name) input :$role references revision $(binding.revision_id.value), but the archive object is revision $(object.revision_id.value)",
            operation = spec.name,
            role = role,
            object_id = object.object_id.value,
            required_revision_id = binding.revision_id.value,
            found_revision_id = object.revision_id.value,
        ))
    end
    if binding.content_id !== nothing
        if object.content_id === nothing
            push!(diagnostics, error_diagnostic(
                :unverified_content_identity,
                "operation :$(spec.name) input :$role requires content $(binding.content_id.value) but the object has none",
                operation = spec.name,
                role = role,
                object_id = object.object_id.value,
                required_content_id = binding.content_id.value,
            ))
        elseif object.content_id != binding.content_id
            push!(diagnostics, error_diagnostic(
                :stale_content,
                "operation :$(spec.name) input :$role expected content $(binding.content_id.value), found $(object.content_id.value) at revision $(object.revision_id.value)",
                operation = spec.name,
                role = role,
                object_id = object.object_id.value,
                required_content_id = binding.content_id.value,
                found_content_id = object.content_id.value,
                found_revision_id = object.revision_id.value,
            ))
        end
    end
    if expected_schema !== nothing && object.schema != expected_schema
        push!(diagnostics, error_diagnostic(
            :schema_mismatch,
            "operation :$(spec.name) input :$role has schema $(schema_kind(object.schema))@$(object.schema.version), expected $(schema_kind(expected_schema))@$(expected_schema.version)",
            operation = spec.name,
            role = role,
            object_id = object.object_id.value,
            found_schema = schema_kind(object.schema),
            found_version = object.schema.version,
            required_schema = schema_kind(expected_schema),
            required_version = expected_schema.version,
        ))
    end
    if expected_kind !== nothing && object.kind != expected_kind
        push!(diagnostics, error_diagnostic(
            :kind_mismatch,
            "operation :$(spec.name) input :$role has kind $(object.kind), expected $expected_kind",
            operation = spec.name,
            role = role,
            object_id = object.object_id.value,
            found_kind = object.kind,
            required_kind = expected_kind,
        ))
    end
    return diagnostics
end

function _producer_revision(object::ArchiveObject)
    for ref in object.references
        return ref.target.revision_id
    end
    return nothing
end

function _head_revision_message(spec, role, binding, head_object, head, produced_from)
    head_name = head === nothing ? :unknown : head.name
    if produced_from === nothing
        return "operation :$(spec.name) input :$role references revision $(binding.revision_id.value), but workflow head :$head_name requires revision $(head_object.revision_id.value)"
    end
    return "operation :$(spec.name) input :$role references $role revision $(binding.revision_id.value), but workflow head :$head_name requires $role revision $(head_object.revision_id.value) produced from revision $(produced_from.value)"
end

function _verify_external_artifact(binding::PlanBinding)
    diagnostics = DiagnosticMessage[]
    artifact = binding.artifact
    artifact === nothing && return diagnostics
    path = artifact.path
    path === nothing && return diagnostics
    if !isfile(path)
        push!(diagnostics, error_diagnostic(
            :missing_input,
            "external artifact for :$(binding.role) is missing at $(path)",
            role = binding.role,
            path = path,
        ))
        return diagnostics
    end
    binding.content_id === nothing && return diagnostics
    found = try
        external_file_content_id(path)
    catch err
        push!(diagnostics, error_diagnostic(
            :unverified_content_identity,
            "could not hash external artifact for :$(binding.role)",
            role = binding.role,
            path = path,
            error = sprint(showerror, err),
        ))
        return diagnostics
    end
    found == binding.content_id && return diagnostics
    push!(diagnostics, error_diagnostic(
        :stale_content,
        "external artifact for :$(binding.role) no longer matches content $(binding.content_id.value)",
        role = binding.role,
        path = path,
        required_content_id = binding.content_id.value,
        found_content_id = found.value,
    ))
    return diagnostics
end

function _append_payload_validation!(diagnostics, spec, role, payload)
    result = try
        validate(payload)
    catch err
        push!(diagnostics, error_diagnostic(
            :missing_validation_method,
            "operation :$(spec.name) input :$role has no validate method",
            operation = spec.name,
            role = role,
            error = sprint(showerror, err),
        ))
        return diagnostics
    end
    isvalid(result) && return diagnostics
    push!(diagnostics, error_diagnostic(
        :invalid_input,
        "operation :$(spec.name) input :$role failed domain validation",
        operation = spec.name,
        role = role,
    ))
    append!(diagnostics, result.diagnostics)
    return diagnostics
end

function _append_payload_readiness!(diagnostics, spec, role, payload)
    result = try
        readiness(payload, PipelineTarget(spec.readiness_target))
    catch err
        push!(diagnostics, error_diagnostic(
            :missing_readiness_method,
            "operation :$(spec.name) input :$role has no readiness method for :$(spec.readiness_target)",
            operation = spec.name,
            role = role,
            target = spec.readiness_target,
            error = sprint(showerror, err),
        ))
        return diagnostics
    end
    isready(result) && return diagnostics
    push!(diagnostics, error_diagnostic(
        :input_not_ready,
        "operation :$(spec.name) input :$role is not ready for :$(spec.readiness_target)",
        operation = spec.name,
        role = role,
        target = spec.readiness_target,
    ))
    append!(diagnostics, result.diagnostics)
    return diagnostics
end

function _copy_run(
    run::RunRecord;
    plan_id = run.plan_id,
    parent_run_id = run.parent_run_id,
    revision_id = run.revision_id,
    status = run.status,
    software_environment = run.software_environment,
    execution_context = run.execution_context,
    agent_id = run.agent_id,
    activities = run.activities,
    staged = run.staged,
    restart = run.restart,
)
    return RunRecord(
        run.id;
        plan_id = plan_id,
        parent_run_id = parent_run_id,
        revision_id = revision_id,
        status = status,
        software_environment = software_environment,
        execution_context = execution_context,
        agent_id = agent_id,
        activities = activities,
        staged = staged,
        restart = restart,
    )
end

function _replace_run!(graph::ArchiveGraph, run::RunRecord)
    for i in eachindex(graph.runs)
        if graph.runs[i].id == run.id
            graph.runs[i] = run
            return run
        end
    end
    push!(graph.runs, run)
    return run
end

function _replace_head!(graph::ArchiveGraph, head::WorkflowHead)
    for i in eachindex(graph.heads)
        if graph.heads[i].id == head.id
            graph.heads[i] = head
            return head
        end
    end
    push!(graph.heads, head)
    return head
end

function _replace_write!(graph::ArchiveGraph, tx::WriteTransaction)
    for i in eachindex(graph.writes)
        if graph.writes[i].scope === tx.scope && graph.writes[i].run_id == tx.run_id &&
                graph.writes[i].sequence == tx.sequence
            graph.writes[i] = tx
            return tx
        end
    end
    push!(graph.writes, tx)
    return tx
end

function _next_write_sequence(graph::ArchiveGraph)
    isempty(graph.writes) && return 0
    return maximum(tx.sequence for tx in graph.writes) + 1
end

function _next_event_sequence(graph::ArchiveGraph, run_id::RunId; source = "episteme")
    n = 0
    for event in graph.events
        event.run_id == run_id || continue
        event.source == source || continue
        event.sequence === nothing && continue
        n = max(n, event.sequence)
    end
    return n + 1
end

function _emit_event!(
    graph::ArchiveGraph,
    run_id::RunId,
    kind::Symbol;
    activity_id = nothing,
    message = "",
    payload = (;),
    severity = :info,
    revision_id = nothing,
)
    seq = _next_event_sequence(graph, run_id)
    push!(graph.events, EventRecord(
        kind,
        run_id;
        activity_id = activity_id,
        sequence = seq,
        source = "episteme",
        severity = severity,
        message = message,
        retention = :forensic,
        payload = payload,
        revision_id = revision_id,
    ))
    return nothing
end

function _new_id(::Type{T}) where {T}
    return T(string(UUIDs.uuid4()))
end

function _maybe_interrupt(interrupt_after, phase, run_id)
    interrupt_after === phase || return nothing
    throw(ExecutionInterrupted(phase, run_id))
end

function _find_idempotent_activity(graph::ArchiveGraph, spec::OperationSpec)
    spec.idempotency_key === nothing && return nothing
    for run in graph.runs
        for activity in run.activities
            activity.operation == spec.kind || continue
            activity.idempotency_key == spec.idempotency_key || continue
            return (run, activity)
        end
    end
    return nothing
end

function _head_conflict_diagnostic(head::WorkflowHead, expected::RevisionId)
    return error_diagnostic(
        :head_conflict,
        "workflow head :$(head.name) is at revision $(head.revision_id.value), not the expected parent $(expected.value)",
        head_id = head.id.value,
        name = head.name,
        found_revision_id = head.revision_id.value,
        expected_revision_id = expected.value,
    )
end

"""
    execute!(graph, plan; head=nothing, store=WorkingStore(), ...) -> RunRecord

Record a run and stage outputs. Never moves a workflow head. Domain
payloads are applied through [`apply_operation`](@ref).
"""
function execute!(
    graph::ArchiveGraph,
    plan::Plan;
    head = nothing,
    store::WorkingStore = WorkingStore(),
    run_id = nothing,
    writer_token = nothing,
    parent_run_id = nothing,
    software_environment = nothing,
    execution_context = nothing,
    agent_id = nothing,
    interrupt_after = nothing,
    restart = nothing,
)
    resolved_head = _resolve_head(graph, head)
    target = PipelineTarget(:execute; plan = plan, store = store, head = resolved_head)
    ready = readiness(plan, graph, target)
    rid = run_id === nothing ? _new_id(RunId) : (run_id isa RunId ? run_id : RunId(string(run_id)))
    token = writer_token === nothing ? string(UUIDs.uuid4()) : String(writer_token)
    parent = resolved_head === nothing ? nothing : resolved_head.revision_id
    tx = WriteTransaction(;
        scope = :run,
        phase = :begin,
        sequence = _next_write_sequence(graph),
        run_id = rid,
        writer_token = token,
    )
    push!(graph.writes, tx)
    run = RunRecord(
        rid;
        plan_id = plan.id,
        parent_run_id = parent_run_id,
        status = :running,
        software_environment = software_environment,
        execution_context = execution_context,
        agent_id = agent_id,
        restart = restart,
    )
    push!(graph.runs, run)
    _emit_event!(
        graph,
        rid,
        :planned;
        message = "planned $(plan.id.value)",
        payload = (;
            plan_id = plan.id.value,
            head_id = resolved_head === nothing ? nothing : resolved_head.id.value,
            parent_revision_id = parent === nothing ? nothing : parent.value,
        ),
    )
    if !isready(ready)
        failed = _copy_run(run; status = :failed)
        _replace_run!(graph, failed)
        _replace_write!(graph, WriteTransaction(;
            scope = :run,
            phase = :aborted,
            sequence = tx.sequence,
            run_id = rid,
            writer_token = token,
        ))
        _emit_event!(
            graph,
            rid,
            :failed;
            message = "readiness failed before execute",
            severity = :error,
            payload = (; codes = Tuple(d.code for d in ready.diagnostics)),
        )
        return failed
    end
    _replace_write!(graph, WriteTransaction(;
        scope = :run,
        phase = :appending,
        sequence = tx.sequence,
        run_id = rid,
        writer_token = token,
    ))
    _emit_event!(graph, rid, :started; message = "execute started")
    activities = ActivityRecord[]
    staged_rows = StagedObject[]
    run_restart = restart
    try
        for spec in plan_operation_order(plan)
            _maybe_interrupt(interrupt_after, :before_operation, rid)
            duplicate = _find_idempotent_activity(graph, spec)
            if duplicate !== nothing && spec.default_reuse === :forbid
                failed = _copy_run(run; status = :failed, activities = activities, staged = staged_rows)
                _replace_run!(graph, failed)
                _replace_write!(graph, WriteTransaction(;
                    scope = :run,
                    phase = :aborted,
                    sequence = tx.sequence,
                    run_id = rid,
                    writer_token = token,
                ))
                _emit_event!(
                    graph,
                    rid,
                    :failed;
                    message = "duplicate idempotency key $(spec.idempotency_key)",
                    severity = :error,
                    payload = (; operation = spec.kind, idempotency_key = spec.idempotency_key),
                )
                return failed
            end
            if spec.environment !== nothing && run.software_environment !== nothing &&
                    spec.environment != run.software_environment
                failed = _copy_run(run; status = :failed, activities = activities, staged = staged_rows)
                _replace_run!(graph, failed)
                _replace_write!(graph, WriteTransaction(;
                    scope = :run,
                    phase = :aborted,
                    sequence = tx.sequence,
                    run_id = rid,
                    writer_token = token,
                ))
                _emit_event!(
                    graph,
                    rid,
                    :failed;
                    message = "software environment mismatch",
                    severity = :error,
                    payload = (;
                        required = spec.environment.value,
                        found = run.software_environment.value,
                    ),
                )
                return failed
            end
            inputs, input_refs, input_diags = _bind_operation_inputs(
                plan, graph, store, spec, resolved_head,
            )
            if any(d -> d.severity === :error, input_diags)
                failed = _copy_run(run; status = :failed, activities = activities, staged = staged_rows)
                _replace_run!(graph, failed)
                _replace_write!(graph, WriteTransaction(;
                    scope = :run,
                    phase = :aborted,
                    sequence = tx.sequence,
                    run_id = rid,
                    writer_token = token,
                ))
                _emit_event!(
                    graph,
                    rid,
                    :failed;
                    message = "input binding failed for :$(spec.name)",
                    severity = :error,
                    payload = (; operation = spec.name, codes = Tuple(d.code for d in input_diags)),
                )
                return failed
            end
            activity_id = _new_id(ActivityId)
            outcome = _dispatch_or_reuse(spec, inputs, duplicate; plan = plan, run_id = rid)
            reuse_state = outcome.status === :reused ? :reused :
                (spec.default_reuse === :force_recompute ? :forced : :computed)
            generated = ArchiveReference[]
            new_staged = StagedObject[]
            for item in outcome.outputs
                staged = item.staged
                object_id = staged.object_id
                store_payload!(store, object_id, item.payload)
                push!(new_staged, staged)
                push!(generated, ArchiveReference(something(_role_of_staged(plan, spec, staged), :output), object_id))
            end
            activity = ActivityRecord(
                activity_id,
                rid,
                spec.kind;
                idempotency_key = spec.idempotency_key,
                used = input_refs,
                generated = generated,
                reuse = reuse_state,
            )
            push!(activities, activity)
            for staged in new_staged
                row = StagedObject(
                    staged.object_id;
                    namespace = staged.namespace,
                    kind = staged.kind,
                    schema = staged.schema,
                    origin = staged.origin,
                    content_id = staged.content_id,
                    source_revision_id = staged.source_revision_id,
                    activity_id = activity_id,
                    provenance = staged.provenance,
                    references = staged.references,
                )
                push!(staged_rows, row)
                _emit_event!(
                    graph,
                    rid,
                    :staged;
                    activity_id = activity_id,
                    message = "staged $(row.object_id.value)",
                    payload = (; object_id = row.object_id.value, origin = row.origin),
                )
            end
            run = _copy_run(run; activities = activities, staged = staged_rows, restart = outcome.restart === nothing ? run_restart : outcome.restart)
            _replace_run!(graph, run)
            _maybe_interrupt(interrupt_after, :after_staging, rid)
            if outcome.status === :failed
                failed = _copy_run(run; status = :failed, restart = outcome.restart)
                _replace_run!(graph, failed)
                _replace_write!(graph, WriteTransaction(;
                    scope = :run,
                    phase = :aborted,
                    sequence = tx.sequence,
                    run_id = rid,
                    writer_token = token,
                ))
                _emit_event!(
                    graph,
                    rid,
                    :failed;
                    activity_id = activity_id,
                    message = outcome.message,
                    severity = :error,
                    payload = (; operation = spec.kind),
                )
                return failed
            end
            if outcome.restart !== nothing
                run_restart = outcome.restart
            end
        end
        _maybe_interrupt(interrupt_after, :before_complete, rid)
        completed = _copy_run(run; status = :completed, activities = activities, staged = staged_rows, restart = run_restart)
        _replace_run!(graph, completed)
        _replace_write!(graph, WriteTransaction(;
            scope = :run,
            phase = :aborted,
            sequence = tx.sequence,
            run_id = rid,
            writer_token = token,
        ))
        return completed
    catch err
        if err isa ExecutionInterrupted
            interrupted = _copy_run(run; status = :interrupted, activities = activities, staged = staged_rows, restart = run_restart)
            _replace_run!(graph, interrupted)
            _replace_write!(graph, WriteTransaction(;
                scope = :run,
                phase = :appending,
                sequence = tx.sequence,
                run_id = rid,
                writer_token = token,
            ))
            rethrow()
        end
        rethrow()
    end
end

function _resolve_head(graph::ArchiveGraph, head)
    head === nothing && return nothing
    head isa WorkflowHead && return head
    head isa WorkflowHeadId && return find_head(graph, head)
    head isa Symbol && return find_head(graph, head)
    throw(ArgumentError("head must be WorkflowHead, WorkflowHeadId, Symbol, or nothing"))
end

function _role_of_staged(plan::Plan, spec::OperationSpec, staged::StagedObject)
    for (role, port) in zip(spec.outputs, spec.output_ports)
        binding = plan_binding(plan, role)
        if binding !== nothing && binding.object_id == staged.object_id
            return role
        end
        port.kind === staged.kind && return role
    end
    isempty(spec.outputs) && return :output
    return spec.outputs[1]
end

function _bind_operation_inputs(plan, graph, store, spec, head)
    inputs = Dict{Symbol,BoundInput}()
    refs = ArchiveReference[]
    diagnostics = DiagnosticMessage[]
    for (role, port) in zip(spec.inputs, spec.input_ports)
        bound = _resolve_input(plan, graph, store, spec, role, port, head)
        append!(diagnostics, bound.diagnostics)
        bound.input === nothing && continue
        inputs[role] = bound.input
        object = bound.input.object
        staged = bound.input.staged
        if object !== nothing
            push!(refs, ArchiveReference(role, object.object_id; revision_id = object.revision_id))
        elseif staged !== nothing
            push!(refs, ArchiveReference(role, staged.object_id))
        elseif bound.input.artifact !== nothing && plan_binding(plan, role) !== nothing
            binding = plan_binding(plan, role)
            if binding.object_id !== nothing
                push!(refs, ArchiveReference(role, binding.object_id; revision_id = binding.revision_id))
            end
        end
    end
    return inputs, refs, diagnostics
end

function _dispatch_or_reuse(spec, inputs, duplicate; context...)
    if duplicate !== nothing && spec.default_reuse === :allow_if_domain_says
        _, activity = duplicate
        if reuse_equivalent(spec, activity)
            return OperationOutcome(;
                status = :reused,
                message = "reused activity $(activity.id.value)",
            )
        end
    end
    return apply_operation(spec, inputs; context...)
end

function _validate_staged_payloads(store::WorkingStore, staged_rows)
    diagnostics = DiagnosticMessage[]
    for staged in staged_rows
        payload = fetch_payload(store, staged.object_id)
        payload === nothing && continue
        result = try
            validate(payload)
        catch
            continue
        end
        isvalid(result) && continue
        push!(diagnostics, error_diagnostic(
            :validation_failed,
            "staged object $(staged.object_id.value) failed domain validation",
            object_id = staged.object_id.value,
        ))
        append!(diagnostics, result.diagnostics)
    end
    return diagnostics
end

"""
    commit!(graph, run_id; head, revision_id=nothing, writer_token=nothing,
            interrupt_after=nothing) -> RevisionRecord

Promote a completed run's staging set, mint one revision, and move one
head. Fails closed if another writer already moved the head.
"""
function commit!(
    graph::ArchiveGraph,
    run_id;
    head,
    revision_id = nothing,
    writer_token = nothing,
    store::WorkingStore = WorkingStore(),
    interrupt_after = nothing,
)
    rid = run_id isa RunId ? run_id : RunId(string(run_id))
    resolved_head = _resolve_head(graph, head)
    resolved_head === nothing && throw(ArgumentError("commit! requires a workflow head"))
    ready = readiness(graph, PipelineTarget(:commit; run_id = rid))
    run = find_run(graph, rid)
    new_rev = revision_id === nothing ? _new_id(RevisionId) :
        (revision_id isa RevisionId ? revision_id : RevisionId(string(revision_id)))
    token = writer_token === nothing ? string(UUIDs.uuid4()) : String(writer_token)
    seq = _next_write_sequence(graph)
    expected_parent = _planned_parent(graph, rid)
    if expected_parent !== nothing && resolved_head.revision_id != expected_parent
        _emit_event!(
            graph,
            rid,
            :failed;
            message = "head conflict at commit",
            severity = :error,
            payload = (;
                found = resolved_head.revision_id.value,
                expected = expected_parent.value,
            ),
        )
        throw(ArgumentError(_head_conflict_diagnostic(resolved_head, expected_parent).message))
    end
    tx = WriteTransaction(;
        scope = :archive,
        phase = :begin,
        sequence = seq,
        run_id = rid,
        writer_token = token,
    )
    push!(graph.writes, tx)
    _maybe_interrupt(interrupt_after, :begin, rid)
    if !isready(ready)
        _replace_write!(graph, WriteTransaction(;
            scope = :archive,
            phase = :aborted,
            sequence = seq,
            run_id = rid,
            writer_token = token,
        ))
        throw(ArgumentError("run $(rid.value) is not ready to commit"))
    end
    staged_errors = _validate_staged_payloads(store, run.staged)
    if !isempty(staged_errors)
        _replace_write!(graph, WriteTransaction(;
            scope = :archive,
            phase = :aborted,
            sequence = seq,
            run_id = rid,
            writer_token = token,
        ))
        _emit_event!(
            graph,
            rid,
            :validation_failed;
            message = "staged validation failed",
            severity = :error,
            payload = (; codes = Tuple(d.code for d in staged_errors)),
        )
        throw(ArgumentError("staged outputs failed validation before commit"))
    end
    _replace_write!(graph, WriteTransaction(;
        scope = :archive,
        phase = :appending,
        sequence = seq,
        run_id = rid,
        writer_token = token,
    ))
    _maybe_interrupt(interrupt_after, :appending, rid)
    _replace_write!(graph, WriteTransaction(;
        scope = :archive,
        phase = :committing,
        sequence = seq,
        run_id = rid,
        writer_token = token,
    ))
    parents = expected_parent === nothing ? RevisionId[] : RevisionId[expected_parent]
    rec = RevisionRecord(new_rev; parents = parents, run_id = rid, plan_id = run.plan_id)
    promoted = promote_staged(run, new_rev)
    for object in promoted
        push!(graph.objects, object)
        payload = fetch_payload(store, object.object_id)
        payload === nothing || store_payload!(store, object.object_id, payload; revision_id = new_rev)
    end
    _reindex_graph!(graph)
    _maybe_interrupt(interrupt_after, :objects, rid)
    push!(graph.revisions, rec)
    _reindex_graph!(graph)
    _maybe_interrupt(interrupt_after, :revision, rid)
    committed_run = _copy_run(run; revision_id = new_rev, status = :completed)
    _replace_run!(graph, committed_run)
    _maybe_interrupt(interrupt_after, :run, rid)
    moved = WorkflowHead(resolved_head.id, resolved_head.name, new_rev)
    _replace_head!(graph, moved)
    _maybe_interrupt(interrupt_after, :head, rid)
    _replace_write!(graph, WriteTransaction(;
        scope = :archive,
        phase = :committed,
        sequence = seq,
        run_id = rid,
        writer_token = token,
    ))
    _emit_event!(
        graph,
        rid,
        :committed;
        message = "committed revision $(new_rev.value)",
        revision_id = new_rev,
        payload = (; revision_id = new_rev.value, head_id = resolved_head.id.value),
    )
    return rec
end

function _planned_parent(graph::ArchiveGraph, run_id::RunId)
    for event in graph.events
        event.run_id == run_id || continue
        event.kind === :planned || continue
        raw = get(event.payload, :parent_revision_id, nothing)
        raw === nothing && return nothing
        return RevisionId(string(raw))
    end
    head = isempty(graph.heads) ? nothing : graph.heads[1]
    return head === nothing ? nothing : head.revision_id
end

"""
    recover_writes!(graph) -> RecoveryReport

Deterministic recovery for in-flight or uncertain write transactions.
Incomplete commits never remain presented as published heads.
"""
function recover_writes!(graph::ArchiveGraph)
    diagnostics = DiagnosticMessage[]
    recovered = WriteTransaction[]
    for tx in copy(graph.writes)
        if tx.phase in (:begin, :appending)
            _abort_incomplete_write!(graph, tx, diagnostics)
            push!(recovered, find_write(graph; scope = tx.scope, run_id = tx.run_id))
        elseif tx.phase === :committing
            _recover_commit_phase!(graph, tx, diagnostics)
            push!(recovered, find_write(graph; scope = tx.scope, run_id = tx.run_id))
        elseif tx.phase === :uncertain
            push!(diagnostics, error_diagnostic(
                :uncertain_side_effect,
                "write sequence $(tx.sequence) remains :uncertain; commit is fail-closed",
                scope = tx.scope,
                sequence = tx.sequence,
                run_id = tx.run_id === nothing ? nothing : tx.run_id.value,
            ))
            push!(recovered, tx)
        end
    end
    return RecoveryReport(
        !any(d -> d.severity === :error, diagnostics),
        recovered,
        diagnostics,
        (; writes = length(graph.writes)),
    )
end

function _abort_incomplete_write!(graph, tx::WriteTransaction, diagnostics)
    _replace_write!(graph, WriteTransaction(;
        scope = tx.scope,
        phase = :aborted,
        sequence = tx.sequence,
        run_id = tx.run_id,
        writer_token = tx.writer_token,
    ))
    tx.run_id === nothing && return diagnostics
    run = find_run(graph, tx.run_id)
    run === nothing && return diagnostics
    if run.status === :running
        _replace_run!(graph, _copy_run(run; status = :interrupted))
        push!(diagnostics, warning_diagnostic(
            :recovered_interrupted_run,
            "run $(run.id.value) was interrupted before completion",
            run_id = run.id.value,
        ))
    end
    return diagnostics
end

function _recover_commit_phase!(graph, tx::WriteTransaction, diagnostics)
    run = tx.run_id === nothing ? nothing : find_run(graph, tx.run_id)
    run === nothing && return _abort_incomplete_write!(graph, tx, diagnostics)
    rec = run.revision_id === nothing ? _dangling_revision(graph, run) :
        find_revision(graph, run.revision_id)
    if rec === nothing
        _rollback_orphan_promotions!(graph, run, diagnostics)
        _abort_incomplete_write!(graph, tx, diagnostics)
        return diagnostics
    end
    promoted = find_objects(graph, rec.id)
    head = _head_at_revision(graph, rec.id)
    if length(promoted) == length(run.staged) && head !== nothing && run.revision_id == rec.id
        _replace_write!(graph, WriteTransaction(;
            scope = tx.scope,
            phase = :committed,
            sequence = tx.sequence,
            run_id = tx.run_id,
            writer_token = tx.writer_token,
        ))
        push!(diagnostics, info_diagnostic(
            :recovered_committed_write,
            "completed interrupted commit of revision $(rec.id.value)",
            run_id = run.id.value,
            revision_id = rec.id.value,
        ))
        return diagnostics
    end
    _rollback_revision!(graph, rec, run, diagnostics)
    _abort_incomplete_write!(graph, tx, diagnostics)
    return diagnostics
end

function _dangling_revision(graph::ArchiveGraph, run::RunRecord)
    for rec in graph.revisions
        rec.run_id == run.id || continue
        run.revision_id == rec.id && continue
        return rec
    end
    return nothing
end

function _head_at_revision(graph::ArchiveGraph, revision_id::RevisionId)
    for head in graph.heads
        head.revision_id == revision_id && return head
    end
    return nothing
end

function _rollback_orphan_promotions!(graph, run::RunRecord, diagnostics)
    remaining = ArchiveObject[]
    for object in graph.objects
        if run.revision_id !== nothing && object.revision_id == run.revision_id
            continue
        end
        if object.run_id == run.id && find_revision(graph, object.revision_id) === nothing
            continue
        end
        push!(remaining, object)
    end
    if length(remaining) != length(graph.objects)
        empty!(graph.objects)
        append!(graph.objects, remaining)
        _reindex_graph!(graph)
        push!(diagnostics, warning_diagnostic(
            :rolled_back_partial_commit,
            "removed uncommitted objects from run $(run.id.value)",
            run_id = run.id.value,
        ))
    end
    return diagnostics
end

function _rollback_revision!(graph, rec::RevisionRecord, run::RunRecord, diagnostics)
    filter!(object -> object.revision_id != rec.id, graph.objects)
    filter!(rev -> rev.id != rec.id, graph.revisions)
    _reindex_graph!(graph)
    parent = isempty(rec.parents) ? nothing : rec.parents[1]
    for i in eachindex(graph.heads)
        graph.heads[i].revision_id == rec.id || continue
        parent === nothing && continue
        old = graph.heads[i]
        graph.heads[i] = WorkflowHead(old.id, old.name, parent)
    end
    _replace_run!(graph, _copy_run(run; revision_id = nothing))
    push!(diagnostics, warning_diagnostic(
        :rolled_back_partial_commit,
        "rolled back incomplete commit of revision $(rec.id.value)",
        run_id = run.id.value,
        revision_id = rec.id.value,
    ))
    return diagnostics
end

"""
    restart!(graph, plan, run_id; store=WorkingStore(), ...) -> RunRecord

Start a new run linked to an incomplete run's [`RestartRequirement`].
Fail-closed when checkpoint identity or original inputs do not match.
"""
function restart!(
    graph::ArchiveGraph,
    plan::Plan,
    run_id;
    store::WorkingStore = WorkingStore(),
    writer_token = nothing,
    head = nothing,
    interrupt_after = nothing,
    software_environment = nothing,
    execution_context = nothing,
    agent_id = nothing,
)
    rid = run_id isa RunId ? run_id : RunId(string(run_id))
    ready = readiness(graph, PipelineTarget(:restart; run_id = rid))
    if !isready(ready)
        _emit_event!(
            graph,
            rid,
            :failed;
            message = "restart readiness failed",
            severity = :error,
            payload = (; codes = Tuple(d.code for d in ready.diagnostics)),
        )
        throw(ArgumentError("run $(rid.value) is not ready to restart"))
    end
    old = find_run(graph, rid)
    child = execute!(
        graph,
        plan;
        head = head,
        store = store,
        writer_token = writer_token,
        parent_run_id = rid,
        software_environment = software_environment === nothing ? old.software_environment :
            software_environment,
        execution_context = execution_context === nothing ? old.execution_context :
            execution_context,
        agent_id = agent_id,
        interrupt_after = interrupt_after,
        restart = old.restart,
    )
    _emit_event!(
        graph,
        child.id,
        :restarted;
        message = "restarted from $(rid.value)",
        payload = (; parent_run_id = rid.value),
    )
    return child
end
