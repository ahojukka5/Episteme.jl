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

Explicit retention choices. Pinned log streams always survive. Ancestor
*revision records* of retained revisions are always kept so parent edges
stay valid. `keep_ancestor_objects` also keeps every object materialized
in those ancestor revisions, not only the inspect closure.
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
version, run, or log stream.
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
duplicated retained content, externals, and optional byte totals.
"""
struct PurgePlan
    policy::RetentionPolicy
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

function _object_key(object::ArchiveObject)
    return _entry_key(object.object_id, object.revision_id)
end

function _retain_object!(objects::Set{String}, revisions::Set{String}, object::ArchiveObject)
    push!(objects, _object_key(object))
    push!(revisions, object.revision_id.value)
    return nothing
end

function _retain_revision_closure!(
    objects::Set{String},
    revisions::Set{String},
    runs::Set{String},
    externals_found::Vector{ExternalRequirement},
    graph::ArchiveGraph,
    revision_id::RevisionId,
    policy::RetentionPolicy,
    externals,
)
    manifest = inspect(graph, revision_id; externals = externals)
    push!(revisions, manifest.revision.id.value)
    for parent in manifest.parents
        push!(revisions, parent.value)
    end
    for anc in manifest.ancestors
        push!(revisions, anc.value)
    end
    if manifest.run !== nothing
        push!(runs, manifest.run.id.value)
    end
    for entry in manifest.entries
        if entry.availability === :envelope_only && entry.object !== nothing
            _retain_object!(objects, revisions, entry.object)
        elseif entry.availability === :external_required
            req = _match_external(externals, entry.object_id, entry.content_id)
            req === nothing && continue
            any(e -> e.object_id == req.object_id && e.content_id == req.content_id, externals_found) &&
                continue
            push!(externals_found, req)
        end
    end
    policy.keep_ancestor_objects || return nothing
    for rev_id in _visible_revision_order(graph, revision_id)
        for object in find_objects(graph, rev_id)
            _retain_object!(objects, revisions, object)
        end
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
        return (root.run_id, root.log_kind)
    end
    throw(ArgumentError("unknown retention root kind :$(root.kind)"))
end

function _seed_root!(
    objects, revisions, runs, heads, graph, root, policy, externals, externals_found,
)
    if root.kind === :head
        head = _resolve_retention_root(graph, root)
        push!(heads, head.id.value)
        _retain_revision_closure!(
            objects, revisions, runs, externals_found, graph, head.revision_id, policy, externals,
        )
    elseif root.kind === :revision
        rid = _resolve_retention_root(graph, root)
        _retain_revision_closure!(
            objects, revisions, runs, externals_found, graph, rid, policy, externals,
        )
    elseif root.kind === :object
        object_id, revision_id = _resolve_retention_root(graph, root)
        object = find_object(graph, object_id, revision_id)
        _retain_object!(objects, revisions, object)
        _retain_revision_closure!(
            objects, revisions, runs, externals_found, graph, revision_id, policy, externals,
        )
    elseif root.kind === :run
        run_id = _resolve_retention_root(graph, root)
        push!(runs, run_id.value)
        run = find_run(graph, run_id)
        if run.revision_id !== nothing
            _retain_revision_closure!(
                objects, revisions, runs, externals_found, graph, run.revision_id, policy, externals,
            )
        end
    elseif root.kind === :log_stream
        run_id, _ = _resolve_retention_root(graph, root)
        push!(runs, run_id.value)
        run = find_run(graph, run_id)
        if run !== nothing && run.revision_id !== nothing
            _retain_revision_closure!(
                objects, revisions, runs, externals_found, graph, run.revision_id, policy, externals,
            )
        end
    end
    return nothing
end

function _keep_log_stream(stream::LogStreamRecord, policy::RetentionPolicy, runs::Set{String})
    stream.retention === :pinned && return true
    stream.run_id.value in runs || return false
    stream.retention === :forensic && return policy.keep_forensic_logs
    stream.retention === :debug && return policy.keep_debug_logs
    stream.retention === :ephemeral && return policy.keep_debug_logs
    return false
end

function _keep_event(event::EventRecord, policy::RetentionPolicy, runs::Set{String})
    event.run_id.value in runs || return false
    event.retention === :pinned && return true
    event.retention === :forensic && return policy.keep_forensic_logs
    event.retention === :debug && return policy.keep_debug_logs
    event.retention === :ephemeral && return policy.keep_debug_logs
    return true
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
    objects = Set{String}()
    revisions = Set{String}()
    runs = Set{String}()
    heads = Set{String}()
    externals_found = ExternalRequirement[]
    root_list = RetentionRoot[]
    for root in roots
        root isa RetentionRoot || throw(ArgumentError("roots must contain RetentionRoot values"))
        push!(root_list, root)
        _seed_root!(
            objects, revisions, runs, heads, graph, root, policy, externals, externals_found,
        )
    end
    for stream in graph.log_streams
        stream.retention === :pinned || continue
        push!(runs, stream.run_id.value)
        run = find_run(graph, stream.run_id)
        if run !== nothing && run.revision_id !== nothing
            _retain_revision_closure!(
                objects, revisions, runs, externals_found, graph, run.revision_id, policy, externals,
            )
        end
    end
    if policy.keep_uncommitted_runs
        for run in graph.runs
            run.revision_id === nothing && push!(runs, run.id.value)
        end
    end
    for run in graph.runs
        run.id.value in runs && continue
        run.revision_id === nothing && continue
        run.revision_id.value in revisions && push!(runs, run.id.value)
    end
    for head in graph.heads
        head.id.value in heads && continue
        head.revision_id.value in revisions && push!(heads, head.id.value)
    end
    return objects, revisions, runs, heads, externals_found, root_list
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
"""
function plan_purge(
    graph::ArchiveGraph,
    roots;
    policy::RetentionPolicy = RetentionPolicy(),
    externals = ExternalRequirement[],
    content_sizes = nothing,
)
    reqs = _externals_vector(externals)
    objects, revisions, runs, _, externals_found, _ = _reachability(graph, roots, policy, reqs)
    classifications = PurgeClassification[]
    retained_content = Set{String}()
    omitted_content = Set{String}()
    content_rows = Dict{String,Int}()
    for object in ordered_objects(graph)
        key = _object_key(object)
        cid = object.content_id
        if key in objects
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
    for req in externals_found
        push!(classifications, PurgeClassification(
            req.object_id,
            :external;
            content_id = req.content_id,
        ))
    end
    debug_count = 0
    for (i, stream) in enumerate(graph.log_streams)
        _keep_log_stream(stream, policy, runs) && continue
        stream.run_id.value in runs || continue
        debug_count += 1
        push!(classifications, PurgeClassification(
            ObjectId("log-stream-$(i)-$(stream.run_id.value)"),
            :purgeable_debug;
        ))
    end
    for (i, event) in enumerate(graph.events)
        event.run_id.value in runs || continue
        _keep_event(event, policy, runs) && continue
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
        classifications,
        _sorted_revision_ids(revisions),
        _sorted_revision_ids(setdiff(all_revs, revisions)),
        _sorted_run_ids(runs),
        _sorted_run_ids(setdiff(all_runs, runs)),
        count(c -> c.class === :reachable, classifications),
        count(c -> c.class === :unreachable, classifications),
        length(retained_content),
        length(omitted_content_only),
        duplicated,
        length(externals_found),
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
    objects::Set{String},
    revisions::Set{String},
    runs::Set{String},
    heads::Set{String},
    policy::RetentionPolicy,
)
    return ArchiveGraph(
        _filter_copy(ordered_objects(graph), (_, obj) -> _object_key(obj) in objects),
        _filter_copy(ordered_heads(graph), (_, head) -> head.id.value in heads),
        _filter_copy(ordered_revisions(graph), (_, rev) -> rev.id.value in revisions),
        _filter_copy(ordered_runs(graph), (_, run) -> run.id.value in runs),
        _filter_copy(graph.events, (_, event) -> _keep_event(event, policy, runs)),
        _filter_copy(graph.writes, (_, tx) -> tx.run_id !== nothing && tx.run_id.value in runs),
        _filter_copy(graph.log_streams, (_, stream) -> _keep_log_stream(stream, policy, runs)),
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
    objects, revisions, runs, heads, _, _ = _reachability(graph, roots, policy, reqs)
    plan = plan_purge(graph, roots; policy = policy, externals = reqs, content_sizes = content_sizes)
    compacted = _build_compacted(graph, objects, revisions, runs, heads, policy)
    report = _verify_compacted(compacted, plan.retained_revisions, reqs)
    if !isvalid(report)
        return PurgeResult(true, nothing, plan, report)
    end
    return PurgeResult(true, compacted, plan, report)
end

function validate(plan::PurgePlan)
    diagnostics = DiagnosticMessage[]
    return ValidationReport(
        :purge_plan,
        true,
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
        DiagnosticMessage[],
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
