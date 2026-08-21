# ---------------------------------------------------------------------------
# Explicit purge / compaction (#31)
#
# Ordinary writes never delete committed history. Purge computes reachability
# from selected roots and builds a *new* graph. The source is not mutated.
# ---------------------------------------------------------------------------

const RETENTION_ROOT_KINDS = (:head, :revision, :object, :run, :log_stream)
const REACHABILITY_CLASSES = (
    :reachable,
    :unreachable,
    :duplicated_content,
    :external,
    :purgeable_debug,
)

"""
    RetentionPolicy(; keep_ancestor_objects=false, keep_uncommitted_runs=false,
                    keep_debug_logs=false, keep_forensic_logs=true)

Explicit retention choices. Pinned log streams and pinned events always
survive and keep their run. Ancestor *revision records* of retained
revisions are always kept so parent edges stay valid.
`keep_ancestor_objects` also keeps every object materialized in those
ancestor revisions, not only the inspect closure.
"""
struct RetentionPolicy
    keep_ancestor_objects::Bool
    keep_uncommitted_runs::Bool
    keep_debug_logs::Bool
    keep_forensic_logs::Bool
end

function RetentionPolicy(;
    keep_ancestor_objects::Bool = false,
    keep_uncommitted_runs::Bool = false,
    keep_debug_logs::Bool = false,
    keep_forensic_logs::Bool = true,
)
    return RetentionPolicy(
        keep_ancestor_objects,
        keep_uncommitted_runs,
        keep_debug_logs,
        keep_forensic_logs,
    )
end

"""
    RetentionRoot(; kind, kwargs...)

A caller-selected retention root: a workflow head, revision, object
version, run, or log stream. A `:log_stream` root requires `run_id` and
`log_kind` and forces that stream to survive even when policy would
drop debug logs. An `:object` root keeps that object version's
reference closure, not every sibling materialized in the revision.
"""
struct RetentionRoot
    kind::Symbol
    head_id::Union{Nothing,WorkflowHeadId}
    head_name::Union{Nothing,Symbol}
    revision_id::Union{Nothing,RevisionId}
    object_id::Union{Nothing,ObjectId}
    run_id::Union{Nothing,RunId}
    log_kind::Union{Nothing,Symbol}
end

function RetentionRoot(;
    kind::Symbol,
    head_id = nothing,
    head_name = nothing,
    revision_id = nothing,
    object_id = nothing,
    run_id = nothing,
    log_kind = nothing,
)
    kind in RETENTION_ROOT_KINDS || throw(ArgumentError(
        "kind must be one of $RETENTION_ROOT_KINDS, got :$kind",
    ))
    return RetentionRoot(
        kind,
        _optional_id(WorkflowHeadId, head_id),
        head_name === nothing ? nothing : Symbol(head_name),
        _optional_id(RevisionId, revision_id),
        _optional_id(ObjectId, object_id),
        _optional_id(RunId, run_id),
        log_kind === nothing ? nothing : Symbol(log_kind),
    )
end

RetentionRoot(revision_id::RevisionId) = RetentionRoot(; kind = :revision, revision_id = revision_id)
RetentionRoot(head::WorkflowHead) = RetentionRoot(; kind = :head, head_id = head.id)
RetentionRoot(head_id::WorkflowHeadId) = RetentionRoot(; kind = :head, head_id = head_id)
RetentionRoot(run_id::RunId) = RetentionRoot(; kind = :run, run_id = run_id)
function RetentionRoot(object_id::ObjectId, revision_id::RevisionId)
    return RetentionRoot(; kind = :object, object_id = object_id, revision_id = revision_id)
end
function RetentionRoot(run_id::RunId, log_kind::Symbol)
    return RetentionRoot(; kind = :log_stream, run_id = run_id, log_kind = log_kind)
end

"""
    PurgeClassification(object_id, class; revision_id=nothing, content_id=nothing)

Reachability class of one object version or external/debug item.
"""
struct PurgeClassification
    object_id::ObjectId
    revision_id::Union{Nothing,RevisionId}
    content_id::Union{Nothing,ContentId}
    class::Symbol
end

function PurgeClassification(
    object_id::ObjectId,
    class::Symbol;
    revision_id = nothing,
    content_id = nothing,
)
    class in REACHABILITY_CLASSES || throw(ArgumentError(
        "class must be one of $REACHABILITY_CLASSES, got :$class",
    ))
    return PurgeClassification(
        object_id,
        _optional_id(RevisionId, revision_id),
        _optional_id(ContentId, content_id),
        class,
    )
end

"""
    PurgePlan(...)

Deterministic purge manifest: retained/omitted counts, unique content,
duplicated retained content, externals, optional byte totals, and
reachability diagnostics. `validate(plan)` is false when required
dependencies are unresolved.
"""
struct PurgePlan
    policy::RetentionPolicy
    diagnostics::Vector{DiagnosticMessage}
    classifications::Vector{PurgeClassification}
    retained_revisions::Vector{RevisionId}
    omitted_revisions::Vector{RevisionId}
    retained_runs::Vector{RunId}
    omitted_runs::Vector{RunId}
    retained_objects::Int
    omitted_objects::Int
    retained_content::Int
    omitted_content::Int
    duplicated_content::Int
    external_objects::Int
    purgeable_debug::Int
    retained_bytes::Union{Nothing,Int}
    omitted_bytes::Union{Nothing,Int}
end

"""
    PurgeResult(source_unchanged, graph, plan, report)

Outcome of [`compact_archive`](@ref). `graph` is `nothing` when
verification fails. The source archive is never mutated.
"""
struct PurgeResult
    source_unchanged::Bool
    graph::Union{Nothing,ArchiveGraph}
    plan::PurgePlan
    report::ValidationReport
end

struct _Reachability
    objects::Set{String}
    revisions::Set{String}
    runs::Set{String}
    heads::Set{String}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
    forced_streams::Set{Tuple{String,Symbol}}
end

function _Reachability()
    return _Reachability(
        Set{String}(),
        Set{String}(),
        Set{String}(),
        Set{String}(),
        ExternalRequirement[],
        DiagnosticMessage[],
        Set{Tuple{String,Symbol}}(),
    )
end

function _object_key(object::ArchiveObject)
    return _entry_key(object.object_id, object.revision_id)
end

function _stream_key(stream::LogStreamRecord)
    return (stream.run_id.value, stream.kind)
end

function _push_diagnostic!(diagnostics::Vector{DiagnosticMessage}, diag::DiagnosticMessage)
    for existing in diagnostics
        existing.code === diag.code && existing.message == diag.message &&
            existing.context == diag.context && return nothing
    end
    push!(diagnostics, diag)
    return nothing
end

function _push_external!(state::_Reachability, req::ExternalRequirement)
    any(e -> e.object_id == req.object_id && e.content_id == req.content_id, state.externals) &&
        return nothing
    push!(state.externals, req)
    return nothing
end

function _retain_object!(objects::Set{String}, revisions::Set{String}, object::ArchiveObject)
    push!(objects, _object_key(object))
    push!(revisions, object.revision_id.value)
    return nothing
end

function _retain_revision_records!(state::_Reachability, graph::ArchiveGraph, revision_id::RevisionId)
    push!(state.revisions, revision_id.value)
    rec = find_revision(graph, revision_id)
    rec === nothing && return nothing
    for id in _visible_revision_order(graph, revision_id)
        push!(state.revisions, id.value)
        parent = find_revision(graph, id)
        parent === nothing && continue
        parent.run_id === nothing && continue
        push!(state.runs, parent.run_id.value)
    end
    return nothing
end

function _retain_unresolved_target!(
    state::_Reachability,
    externals,
    revision_id::RevisionId,
    target::ObjectRef,
)
    req = _match_external(externals, target.object_id, nothing)
    if req !== nothing
        _push_external!(state, req)
        return nothing
    end
    _push_diagnostic!(state.diagnostics, error_diagnostic(
        :missing_manifest_object,
        "revision $(revision_id.value) names missing object $(target.object_id.value)";
        revision_id = revision_id.value,
        object_id = target.object_id.value,
        target_revision_id = target.revision_id === nothing ? nothing : target.revision_id.value,
    ))
    return nothing
end

function _retain_object_closure!(
    state::_Reachability,
    graph::ArchiveGraph,
    object::ArchiveObject,
    policy::RetentionPolicy,
    externals,
)
    visible = _visible_revision_order(graph, object.revision_id)
    _retain_revision_records!(state, graph, object.revision_id)
    queue = ArchiveObject[object]
    seen = Set{String}()
    while !isempty(queue)
        item = popfirst!(queue)
        key = _object_key(item)
        key in seen && continue
        push!(seen, key)
        _retain_object!(state.objects, state.revisions, item)
        _retain_revision_records!(state, graph, item.revision_id)
        for ref in ordered_references(item)
            resolved = _resolve_in_revision_scope(graph, ref.target, visible)
            if resolved === nothing
                _retain_unresolved_target!(state, externals, object.revision_id, ref.target)
            else
                push!(queue, resolved)
            end
        end
    end
    policy.keep_ancestor_objects || return nothing
    for rev_id in visible
        for obj in find_objects(graph, rev_id)
            _retain_object!(state.objects, state.revisions, obj)
        end
    end
    return nothing
end

function _retain_object_ref!(
    state::_Reachability,
    graph::ArchiveGraph,
    ref::ObjectRef,
    policy::RetentionPolicy,
    externals;
    code::Symbol,
    message::AbstractString,
    context...,
)
    matches = ArchiveObject[]
    if ref.revision_id !== nothing
        obj = find_object(graph, ref.object_id, ref.revision_id)
        obj === nothing || push!(matches, obj)
    else
        append!(matches, find_revisions(graph, ref.object_id))
    end
    if !isempty(matches)
        for obj in matches
            _retain_object_closure!(state, graph, obj, policy, externals)
        end
        return nothing
    end
    req = _match_external(externals, ref.object_id, nothing)
    if req !== nothing
        _push_external!(state, req)
        return nothing
    end
    _push_diagnostic!(state.diagnostics, error_diagnostic(
        code,
        message;
        object_id = ref.object_id.value,
        target_revision_id = ref.revision_id === nothing ? nothing : ref.revision_id.value,
        context...,
    ))
    return nothing
end

function _retain_revision_closure!(
    state::_Reachability,
    graph::ArchiveGraph,
    revision_id::RevisionId,
    policy::RetentionPolicy,
    externals,
)
    manifest = inspect(graph, revision_id; externals = externals)
    for diag in manifest.diagnostics
        _push_diagnostic!(state.diagnostics, diag)
    end
    _retain_revision_records!(state, graph, revision_id)
    for parent in manifest.parents
        push!(state.revisions, parent.value)
    end
    for anc in manifest.ancestors
        push!(state.revisions, anc.value)
    end
    if manifest.run !== nothing
        push!(state.runs, manifest.run.id.value)
    end
    for entry in manifest.entries
        if entry.availability === :envelope_only && entry.object !== nothing
            _retain_object!(state.objects, state.revisions, entry.object)
        elseif entry.availability === :external_required
            req = _match_external(externals, entry.object_id, entry.content_id)
            req === nothing && continue
            _push_external!(state, req)
        elseif entry.availability === :missing
            _push_diagnostic!(state.diagnostics, error_diagnostic(
                :missing_manifest_object,
                "revision $(revision_id.value) names missing object $(entry.object_id.value)";
                revision_id = revision_id.value,
                object_id = entry.object_id.value,
                target_revision_id = entry.revision_id === nothing ? nothing :
                    entry.revision_id.value,
            ))
        end
    end
    policy.keep_ancestor_objects || return nothing
    for rev_id in _visible_revision_order(graph, revision_id)
        for object in find_objects(graph, rev_id)
            _retain_object!(state.objects, state.revisions, object)
        end
    end
    return nothing
end

function _retain_run_seed!(
    state::_Reachability,
    graph::ArchiveGraph,
    run_id::RunId,
    policy::RetentionPolicy,
    externals;
    snapshot::Bool = true,
)
    push!(state.runs, run_id.value)
    run = find_run(graph, run_id)
    run === nothing && return nothing
    run.revision_id === nothing && return nothing
    if snapshot
        _retain_revision_closure!(state, graph, run.revision_id, policy, externals)
    else
        _retain_revision_records!(state, graph, run.revision_id)
    end
    return nothing
end

function _resolve_retention_root(graph::ArchiveGraph, root::RetentionRoot)
    if root.kind === :head
        head = root.head_id !== nothing ? find_head(graph, root.head_id) :
            root.head_name !== nothing ? find_head(graph, root.head_name) : nothing
        head === nothing && throw(ArgumentError("retention head root does not resolve"))
        return head
    elseif root.kind === :revision
        root.revision_id === nothing && throw(ArgumentError("revision root requires revision_id"))
        find_revision(graph, root.revision_id) === nothing &&
            throw(ArgumentError("retention revision $(root.revision_id.value) is not in the graph"))
        return root.revision_id
    elseif root.kind === :object
        (root.object_id === nothing || root.revision_id === nothing) &&
            throw(ArgumentError("object root requires object_id and revision_id"))
        find_object(graph, root.object_id, root.revision_id) === nothing &&
            throw(ArgumentError("retention object $(root.object_id.value) @ $(root.revision_id.value) is missing"))
        return (root.object_id, root.revision_id)
    elseif root.kind === :run
        root.run_id === nothing && throw(ArgumentError("run root requires run_id"))
        find_run(graph, root.run_id) === nothing &&
            throw(ArgumentError("retention run $(root.run_id.value) is not in the graph"))
        return root.run_id
    elseif root.kind === :log_stream
        root.run_id === nothing && throw(ArgumentError("log stream root requires run_id"))
        root.log_kind === nothing && throw(ArgumentError("log stream root requires log_kind"))
        find_run(graph, root.run_id) === nothing &&
            throw(ArgumentError("retention run $(root.run_id.value) is not in the graph"))
        found = false
        for stream in graph.log_streams
            stream.run_id == root.run_id && stream.kind === root.log_kind || continue
            found = true
            break
        end
        found || throw(ArgumentError(
            "retention log stream :$(root.log_kind) for run $(root.run_id.value) is not in the graph",
        ))
        return (root.run_id, root.log_kind)
    end
    throw(ArgumentError("unknown retention root kind :$(root.kind)"))
end

function _seed_root!(
    state::_Reachability,
    graph::ArchiveGraph,
    root::RetentionRoot,
    policy::RetentionPolicy,
    externals,
)
    if root.kind === :head
        head = _resolve_retention_root(graph, root)
        push!(state.heads, head.id.value)
        _retain_revision_closure!(state, graph, head.revision_id, policy, externals)
    elseif root.kind === :revision
        rid = _resolve_retention_root(graph, root)
        _retain_revision_closure!(state, graph, rid, policy, externals)
    elseif root.kind === :object
        object_id, revision_id = _resolve_retention_root(graph, root)
        object = find_object(graph, object_id, revision_id)
        _retain_object_closure!(state, graph, object, policy, externals)
    elseif root.kind === :run
        run_id = _resolve_retention_root(graph, root)
        _retain_run_seed!(state, graph, run_id, policy, externals)
    elseif root.kind === :log_stream
        run_id, log_kind = _resolve_retention_root(graph, root)
        push!(state.forced_streams, (run_id.value, log_kind))
        _retain_run_seed!(state, graph, run_id, policy, externals)
    end
    return nothing
end

function _keep_log_stream(
    stream::LogStreamRecord,
    policy::RetentionPolicy,
    runs::Set{String},
    forced_streams::Set{Tuple{String,Symbol}},
)
    _stream_key(stream) in forced_streams && return true
    stream.retention === :pinned && return true
    stream.run_id.value in runs || return false
    stream.retention === :forensic && return policy.keep_forensic_logs
    stream.retention === :debug && return policy.keep_debug_logs
    stream.retention === :ephemeral && return policy.keep_debug_logs
    return false
end

function _keep_event(event::EventRecord, policy::RetentionPolicy, runs::Set{String})
    event.retention === :pinned && return true
    event.run_id.value in runs || return false
    event.retention === :forensic && return policy.keep_forensic_logs
    event.retention === :debug && return policy.keep_debug_logs
    event.retention === :ephemeral && return policy.keep_debug_logs
    return true
end

function _close_parent_runs!(state::_Reachability, graph::ArchiveGraph)
    for run in graph.runs
        run.id.value in state.runs || continue
        run.parent_run_id === nothing && continue
        parent = find_run(graph, run.parent_run_id)
        if parent === nothing
            _push_diagnostic!(state.diagnostics, error_diagnostic(
                :missing_parent_run,
                "run $(run.id.value) names unknown parent run $(run.parent_run_id.value)";
                run_id = run.id.value,
                parent_run_id = run.parent_run_id.value,
            ))
            continue
        end
        parent.id.value in state.runs && continue
        push!(state.runs, parent.id.value)
        parent.revision_id === nothing && continue
        _retain_revision_records!(state, graph, parent.revision_id)
    end
    return nothing
end

function _close_activity_refs!(
    state::_Reachability,
    graph::ArchiveGraph,
    policy::RetentionPolicy,
    externals,
)
    for run in graph.runs
        run.id.value in state.runs || continue
        for activity in run.activities
            for ref in vcat(activity.used, activity.generated)
                _retain_object_ref!(
                    state,
                    graph,
                    ref.target,
                    policy,
                    externals;
                    code = :missing_activity_object,
                    message = "activity $(activity.id.value) names missing object $(ref.target.object_id.value)",
                    activity_id = activity.id.value,
                    run_id = run.id.value,
                    name = ref.name,
                )
            end
        end
    end
    return nothing
end

function _close_event_refs!(
    state::_Reachability,
    graph::ArchiveGraph,
    policy::RetentionPolicy,
    externals,
)
    for event in graph.events
        _keep_event(event, policy, state.runs) || continue
        push!(state.runs, event.run_id.value)
        if event.revision_id !== nothing
            _retain_revision_records!(state, graph, event.revision_id)
        end
        for ref in event.object_refs
            _retain_object_ref!(
                state,
                graph,
                ref,
                policy,
                externals;
                code = :dangling_event_object,
                message = "event :$(event.kind) names unknown object $(ref.object_id.value)",
                kind = event.kind,
                run_id = event.run_id.value,
            )
        end
    end
    return nothing
end

function _attach_committed_runs!(state::_Reachability, graph::ArchiveGraph)
    for run in graph.runs
        run.id.value in state.runs && continue
        run.revision_id === nothing && continue
        run.revision_id.value in state.revisions && push!(state.runs, run.id.value)
    end
    return nothing
end

function _attach_heads!(state::_Reachability, graph::ArchiveGraph)
    for head in graph.heads
        head.id.value in state.heads && continue
        head.revision_id.value in state.revisions && push!(state.heads, head.id.value)
    end
    return nothing
end

function _close_reachability!(
    state::_Reachability,
    graph::ArchiveGraph,
    policy::RetentionPolicy,
    externals,
)
    while true
        nobj = length(state.objects)
        nrev = length(state.revisions)
        nrun = length(state.runs)
        _close_parent_runs!(state, graph)
        _close_activity_refs!(state, graph, policy, externals)
        _close_event_refs!(state, graph, policy, externals)
        _attach_committed_runs!(state, graph)
        _attach_heads!(state, graph)
        length(state.objects) == nobj && length(state.revisions) == nrev &&
            length(state.runs) == nrun && break
    end
    return nothing
end

function _content_size(content_id, sizes)
    sizes === nothing && return nothing
    content_id === nothing && return 0
    if sizes isa AbstractDict
        haskey(sizes, content_id) && return Int(sizes[content_id])
        haskey(sizes, content_id.value) && return Int(sizes[content_id.value])
    end
    return 0
end

function _reachability(
    graph::ArchiveGraph,
    roots,
    policy::RetentionPolicy,
    externals,
)
    state = _Reachability()
    for root in roots
        root isa RetentionRoot || throw(ArgumentError("roots must contain RetentionRoot values"))
        _seed_root!(state, graph, root, policy, externals)
    end
    for stream in graph.log_streams
        stream.retention === :pinned || continue
        _retain_run_seed!(state, graph, stream.run_id, policy, externals; snapshot = false)
    end
    for event in graph.events
        event.retention === :pinned || continue
        _retain_run_seed!(state, graph, event.run_id, policy, externals; snapshot = false)
    end
    if policy.keep_uncommitted_runs
        for run in graph.runs
            run.revision_id === nothing && push!(state.runs, run.id.value)
        end
    end
    _close_reachability!(state, graph, policy, externals)
    return state
end

function _sorted_revision_ids(ids::Set{String})
    return sort!(RevisionId[RevisionId(id) for id in ids]; by = r -> r.value)
end

function _sorted_run_ids(ids::Set{String})
    return sort!(RunId[RunId(id) for id in ids]; by = r -> r.value)
end

"""
    plan_purge(graph, roots; policy=RetentionPolicy(), externals=(), content_sizes=nothing)
        -> PurgePlan

Dry-run reachability. Does not mutate `graph` and does not write files.
Unresolved required dependencies are recorded on `plan.diagnostics`.
"""
function plan_purge(
    graph::ArchiveGraph,
    roots;
    policy::RetentionPolicy = RetentionPolicy(),
    externals = ExternalRequirement[],
    content_sizes = nothing,
)
    reqs = _externals_vector(externals)
    state = _reachability(graph, roots, policy, reqs)
    classifications = PurgeClassification[]
    retained_content = Set{String}()
    omitted_content = Set{String}()
    content_rows = Dict{String,Int}()
    for object in ordered_objects(graph)
        key = _object_key(object)
        cid = object.content_id
        if key in state.objects
            class = :reachable
            if cid !== nothing
                push!(retained_content, cid.value)
                content_rows[cid.value] = get(content_rows, cid.value, 0) + 1
            end
        else
            class = :unreachable
            cid === nothing || push!(omitted_content, cid.value)
        end
        push!(classifications, PurgeClassification(
            object.object_id,
            class;
            revision_id = object.revision_id,
            content_id = cid,
        ))
    end
    duplicated = count(n -> n > 1, values(content_rows))
    for req in state.externals
        push!(classifications, PurgeClassification(
            req.object_id,
            :external;
            content_id = req.content_id,
        ))
    end
    debug_count = 0
    for (i, stream) in enumerate(graph.log_streams)
        _keep_log_stream(stream, policy, state.runs, state.forced_streams) && continue
        stream.run_id.value in state.runs || continue
        debug_count += 1
        push!(classifications, PurgeClassification(
            ObjectId("log-stream-$(i)-$(stream.run_id.value)"),
            :purgeable_debug;
        ))
    end
    for (i, event) in enumerate(graph.events)
        event.run_id.value in state.runs || continue
        _keep_event(event, policy, state.runs) && continue
        debug_count += 1
        push!(classifications, PurgeClassification(
            ObjectId("event-$(i)-$(event.run_id.value)"),
            :purgeable_debug;
        ))
    end
    sort!(classifications; by = c -> (
        String(c.class),
        c.object_id.value,
        c.revision_id === nothing ? "" : c.revision_id.value,
    ))
    all_revs = Set(rev.id.value for rev in graph.revisions)
    all_runs = Set(run.id.value for run in graph.runs)
    omitted_content_only = setdiff(omitted_content, retained_content)
    retained_bytes = nothing
    omitted_bytes = nothing
    if content_sizes !== nothing
        retained_bytes = 0
        omitted_bytes = 0
        for id in retained_content
            retained_bytes += _content_size(ContentId(id), content_sizes)
        end
        for id in omitted_content_only
            omitted_bytes += _content_size(ContentId(id), content_sizes)
        end
    end
    return PurgePlan(
        policy,
        copy(state.diagnostics),
        classifications,
        _sorted_revision_ids(state.revisions),
        _sorted_revision_ids(setdiff(all_revs, state.revisions)),
        _sorted_run_ids(state.runs),
        _sorted_run_ids(setdiff(all_runs, state.runs)),
        count(c -> c.class === :reachable, classifications),
        count(c -> c.class === :unreachable, classifications),
        length(retained_content),
        length(omitted_content_only),
        duplicated,
        length(state.externals),
        debug_count,
        retained_bytes,
        omitted_bytes,
    )
end

function _filter_copy(items, keep)
    out = eltype(items)[]
    for (i, item) in enumerate(items)
        keep(i, item) && push!(out, item)
    end
    return out
end

function _build_compacted(
    graph::ArchiveGraph,
    state::_Reachability,
    policy::RetentionPolicy,
)
    return ArchiveGraph(
        _filter_copy(ordered_objects(graph), (_, obj) -> _object_key(obj) in state.objects),
        _filter_copy(ordered_heads(graph), (_, head) -> head.id.value in state.heads),
        _filter_copy(ordered_revisions(graph), (_, rev) -> rev.id.value in state.revisions),
        _filter_copy(ordered_runs(graph), (_, run) -> run.id.value in state.runs),
        _filter_copy(graph.events, (_, event) -> _keep_event(event, policy, state.runs)),
        _filter_copy(graph.writes, (_, tx) -> tx.run_id !== nothing && tx.run_id.value in state.runs),
        _filter_copy(
            graph.log_streams,
            (_, stream) -> _keep_log_stream(stream, policy, state.runs, state.forced_streams),
        ),
    )
end

function _dangling_is_external(diag::DiagnosticMessage, externals)
    diag.code === :dangling_reference || return false
    target = get(diag.context, :target_object_id, nothing)
    target === nothing && return false
    return any(req -> req.object_id.value == target, externals)
end

function _verify_compacted(compacted::ArchiveGraph, retained_revisions, externals)
    diagnostics = DiagnosticMessage[]
    graph_report = validate(compacted)
    for d in graph_report.diagnostics
        _dangling_is_external(d, externals) && continue
        push!(diagnostics, d)
    end
    for rid in retained_revisions
        find_revision(compacted, rid) === nothing && continue
        manifest = inspect(compacted, rid; externals = externals)
        ready = readiness(manifest, PipelineTarget(:inspect))
        isready(ready) && continue
        append!(diagnostics, ready.diagnostics)
    end
    return ValidationReport(
        :purged_archive,
        isempty(diagnostics),
        diagnostics,
        (; revisions = length(retained_revisions), objects = length(compacted.objects)),
    )
end

"""
    compact_archive(graph, roots; policy=RetentionPolicy(), externals=(),
                    content_sizes=nothing) -> PurgeResult

Build a new compacted graph from `roots`. `graph` is not mutated. If
verification fails, `result.graph === nothing` and the source is still
unchanged.
"""
function compact_archive(
    graph::ArchiveGraph,
    roots;
    policy::RetentionPolicy = RetentionPolicy(),
    externals = ExternalRequirement[],
    content_sizes = nothing,
)
    reqs = _externals_vector(externals)
    state = _reachability(graph, roots, policy, reqs)
    plan = plan_purge(graph, roots; policy = policy, externals = reqs, content_sizes = content_sizes)
    compacted = _build_compacted(graph, state, policy)
    report = _verify_compacted(compacted, plan.retained_revisions, reqs)
    if !isvalid(report)
        return PurgeResult(true, nothing, plan, report)
    end
    return PurgeResult(true, compacted, plan, report)
end

function validate(plan::PurgePlan)
    diagnostics = copy(plan.diagnostics)
    return ValidationReport(
        :purge_plan,
        !any(d -> d.severity === :error, diagnostics),
        diagnostics,
        (;
            retained_objects = plan.retained_objects,
            omitted_objects = plan.omitted_objects,
            retained_revisions = length(plan.retained_revisions),
        ),
    )
end

function validate(result::PurgeResult)
    return result.report
end

function report(plan::PurgePlan)
    return ObjectReport(
        :purge_plan,
        "Purge plan retains $(plan.retained_objects) objects and omits $(plan.omitted_objects).",
        (;
            retained_objects = plan.retained_objects,
            omitted_objects = plan.omitted_objects,
            retained_revisions = length(plan.retained_revisions),
            omitted_revisions = length(plan.omitted_revisions),
            retained_content = plan.retained_content,
            omitted_content = plan.omitted_content,
            duplicated_content = plan.duplicated_content,
            external_objects = plan.external_objects,
            purgeable_debug = plan.purgeable_debug,
            retained_bytes = plan.retained_bytes,
            omitted_bytes = plan.omitted_bytes,
        ),
        copy(plan.diagnostics),
        ArtifactRef[],
    )
end

function report(result::PurgeResult)
    return ObjectReport(
        :purge_result,
        result.graph === nothing ?
            "Purge verification failed; source archive unchanged." :
            "Purged archive with $(length(result.graph.objects)) objects.",
        (;
            source_unchanged = result.source_unchanged,
            verified = result.graph !== nothing,
            retained_objects = result.plan.retained_objects,
            omitted_objects = result.plan.omitted_objects,
        ),
        copy(result.report.diagnostics),
        ArtifactRef[],
    )
end

function readiness(result::PurgeResult, target::PipelineTarget)
    target.name === :inspect || return ReadinessReport(
        :purge_result,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "purge result readiness target :$(target.name) is not :inspect";
            target = target.name,
        )],
        (;),
    )
    ready = result.graph !== nothing && isvalid(result.report)
    diagnostics = copy(result.report.diagnostics)
    ready || (isempty(diagnostics) && push!(diagnostics, error_diagnostic(
        :purge_unverified,
        "compacted archive was not verified",
    )))
    return ReadinessReport(
        :purge_result,
        target,
        ready,
        diagnostics,
        (; verified = result.graph !== nothing, source_unchanged = result.source_unchanged),
    )
end

to_namedtuple(policy::RetentionPolicy) = (
    keep_ancestor_objects = policy.keep_ancestor_objects,
    keep_uncommitted_runs = policy.keep_uncommitted_runs,
    keep_debug_logs = policy.keep_debug_logs,
    keep_forensic_logs = policy.keep_forensic_logs,
)

to_namedtuple(root::RetentionRoot) = (
    kind = root.kind,
    head_id = root.head_id === nothing ? nothing : root.head_id.value,
    head_name = root.head_name,
    revision_id = root.revision_id === nothing ? nothing : root.revision_id.value,
    object_id = root.object_id === nothing ? nothing : root.object_id.value,
    run_id = root.run_id === nothing ? nothing : root.run_id.value,
    log_kind = root.log_kind,
)

to_namedtuple(c::PurgeClassification) = (
    object_id = c.object_id.value,
    revision_id = c.revision_id === nothing ? nothing : c.revision_id.value,
    content_id = c.content_id === nothing ? nothing : c.content_id.value,
    class = c.class,
)

to_namedtuple(plan::PurgePlan) = (
    policy = to_namedtuple(plan.policy),
    diagnostics = Tuple(to_namedtuple.(plan.diagnostics)),
    classifications = Tuple(to_namedtuple.(plan.classifications)),
    retained_revisions = Tuple(id.value for id in plan.retained_revisions),
    omitted_revisions = Tuple(id.value for id in plan.omitted_revisions),
    retained_objects = plan.retained_objects,
    omitted_objects = plan.omitted_objects,
    retained_content = plan.retained_content,
    omitted_content = plan.omitted_content,
    duplicated_content = plan.duplicated_content,
    external_objects = plan.external_objects,
    purgeable_debug = plan.purgeable_debug,
    retained_bytes = plan.retained_bytes,
    omitted_bytes = plan.omitted_bytes,
)

to_namedtuple(result::PurgeResult) = (
    source_unchanged = result.source_unchanged,
    verified = result.graph !== nothing,
    plan = to_namedtuple(result.plan),
)
