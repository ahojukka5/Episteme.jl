# ---------------------------------------------------------------------------
# Lazy revision manifest (#33)
#
# In-memory inspect and checkout of committed revisions. No file I/O and
# no payload materialization. Later AH5 checkout fills the same manifest.
# ---------------------------------------------------------------------------

const MANIFEST_MODES = (:inspect, :checkout)
const PAYLOAD_AVAILABILITY = (:envelope_only, :external_required, :missing)

"""
    ExternalRequirement(object_id; content_id=nothing, artifact=ArtifactRef(:external))

Declared external content required by a revision but not stored in this
archive. Distinct from a missing/dangling archive object (`:missing`).
"""
struct ExternalRequirement
    object_id::ObjectId
    content_id::Union{Nothing,ContentId}
    artifact::ArtifactRef
end

function ExternalRequirement(
    object_id::ObjectId;
    content_id = nothing,
    artifact::ArtifactRef = ArtifactRef(:external),
)
    return ExternalRequirement(
        object_id,
        _optional_id(ContentId, content_id),
        artifact,
    )
end

"""
    ManifestEntry(object_id; object=nothing, revision_id=nothing,
                  content_id=nothing, availability=:envelope_only, artifact=nothing)

One lazy slot in a revision manifest. The envelope may be present;
payload bytes are never loaded here.
"""
struct ManifestEntry
    object_id::ObjectId
    object::Union{Nothing,ArchiveObject}
    revision_id::Union{Nothing,RevisionId}
    content_id::Union{Nothing,ContentId}
    availability::Symbol
    artifact::Union{Nothing,ArtifactRef}
end

function ManifestEntry(
    object_id::ObjectId;
    object = nothing,
    revision_id = nothing,
    content_id = nothing,
    availability::Symbol = :envelope_only,
    artifact = nothing,
)
    availability in PAYLOAD_AVAILABILITY || throw(ArgumentError(
        "availability must be one of $PAYLOAD_AVAILABILITY, got :$availability",
    ))
    object === nothing || object isa ArchiveObject || throw(ArgumentError(
        "object must be ArchiveObject or nothing, got $(typeof(object))",
    ))
    artifact === nothing || artifact isa ArtifactRef || throw(ArgumentError(
        "artifact must be ArtifactRef or nothing, got $(typeof(artifact))",
    ))
    return ManifestEntry(
        object_id,
        object,
        _optional_id(RevisionId, revision_id),
        _optional_id(ContentId, content_id),
        availability,
        artifact,
    )
end

"""
    RevisionManifest(...)

Immutable lazy scientific-state manifest for one committed revision.
Generic inspection uses envelope fields only; domain payload packages
are not required. Heads are bookmarks, not part of revision identity.
"""
struct RevisionManifest
    mode::Symbol
    revision::RevisionRecord
    entries::Vector{ManifestEntry}
    heads::Vector{WorkflowHead}
    run::Union{Nothing,RunRecord}
    plan_id::Union{Nothing,PlanId}
    parents::Vector{RevisionId}
    children::Vector{RevisionId}
    ancestors::Vector{RevisionId}
    descendants::Vector{RevisionId}
    externals::Vector{ExternalRequirement}
    diagnostics::Vector{DiagnosticMessage}
end

function find_head(graph::ArchiveGraph, head_id::WorkflowHeadId)
    for head in graph.heads
        head.id == head_id && return head
    end
    return nothing
end

function find_head(graph::ArchiveGraph, name::Symbol)
    matches = WorkflowHead[]
    for head in ordered_heads(graph)
        head.name === name && push!(matches, head)
    end
    isempty(matches) && return nothing
    length(matches) > 1 && throw(ArgumentError(
        "workflow head name :$name is ambiguous",
    ))
    return matches[1]
end

function _externals_vector(externals)
    return _typed_vector(ExternalRequirement, externals, "externals")
end

function _match_external(externals, object_id::ObjectId, content_id)
    for req in externals
        req.object_id == object_id || continue
        if req.content_id === nothing || content_id === nothing || req.content_id == content_id
            return req
        end
    end
    return nothing
end

function _visible_revision_order(graph::ArchiveGraph, revision_id::RevisionId)
    order = RevisionId[]
    seen = Set{String}()
    queue = RevisionId[revision_id]
    while !isempty(queue)
        id = popfirst!(queue)
        id.value in seen && continue
        push!(seen, id.value)
        rec = find_revision(graph, id)
        rec === nothing && continue
        push!(order, id)
        for parent in rec.parents
            parent.value in seen && continue
            push!(queue, parent)
        end
    end
    return order
end

function _resolve_in_revision_scope(graph::ArchiveGraph, target::ObjectRef, visible::Vector{RevisionId})
    vis = Set(id.value for id in visible)
    if target.revision_id !== nothing
        target.revision_id.value in vis || return nothing
        return find_object(graph, target.object_id, target.revision_id)
    end
    for rev in visible
        obj = find_object(graph, target.object_id, rev)
        obj === nothing || return obj
    end
    return nothing
end

function _entry_key(object_id::ObjectId, revision_id)
    return object_id.value * "@" * (revision_id === nothing ? "" : revision_id.value)
end

function _revision_has_parent_cycle(graph::ArchiveGraph, rec::RevisionRecord)
    seen = Set{String}([rec.id.value])
    stack = RevisionId[_unique_parents(rec)...]
    while !isempty(stack)
        id = pop!(stack)
        id == rec.id && return true
        id.value in seen && continue
        push!(seen, id.value)
        parent = find_revision(graph, id)
        parent === nothing && continue
        append!(stack, _unique_parents(parent))
    end
    return false
end

function _append_revision_record_diagnostics!(diagnostics, graph::ArchiveGraph, rec::RevisionRecord)
    if _revision_has_parent_cycle(graph, rec)
        push!(diagnostics, error_diagnostic(
            :cycle,
            "revision parent graph contains a cycle including $(rec.id.value)";
            revision_id = rec.id.value,
        ))
    end
    for parent_id in _unique_parents(rec)
        parent_id == rec.id && continue
        find_revision(graph, parent_id) === nothing || continue
        push!(diagnostics, error_diagnostic(
            :dangling_parent,
            "revision $(rec.id.value) names unknown parent $(parent_id.value)";
            revision_id = rec.id.value,
            parent_id = parent_id.value,
        ))
    end
    rec.run_id === nothing && return diagnostics
    run = find_run(graph, rec.run_id)
    if run === nothing
        push!(diagnostics, error_diagnostic(
            :missing_revision_run,
            "revision $(rec.id.value) names unknown run $(rec.run_id.value)";
            revision_id = rec.id.value,
            run_id = rec.run_id.value,
        ))
        return diagnostics
    end
    if run.revision_id !== nothing && run.revision_id != rec.id
        push!(diagnostics, error_diagnostic(
            :run_revision_mismatch,
            "revision $(rec.id.value) names run $(run.id.value) which commits $(run.revision_id.value)";
            revision_id = rec.id.value,
            run_id = run.id.value,
            run_revision_id = run.revision_id.value,
        ))
    elseif _plan_ids_conflict(run, rec)
        push!(diagnostics, error_diagnostic(
            :run_revision_plan_mismatch,
            "revision $(rec.id.value) plan $(rec.plan_id.value) does not match run $(run.id.value) plan $(run.plan_id.value)";
            revision_id = rec.id.value,
            run_id = run.id.value,
            run_plan_id = run.plan_id.value,
            revision_plan_id = rec.plan_id.value,
        ))
    end
    return diagnostics
end

function _append_visible_revision_diagnostics!(diagnostics, graph::ArchiveGraph, visible)
    for id in visible
        rec = find_revision(graph, id)
        rec === nothing && continue
        _append_revision_record_diagnostics!(diagnostics, graph, rec)
    end
    return diagnostics
end

function _push_unresolved_entry!(
    entries, diagnostics, reqs, revision_id, object_id, target_rev, seen_unresolved,
)
    key = _entry_key(object_id, target_rev)
    key in seen_unresolved && return nothing
    push!(seen_unresolved, key)
    req = _match_external(reqs, object_id, nothing)
    if req !== nothing
        push!(entries, ManifestEntry(
            object_id;
            revision_id = target_rev,
            content_id = req.content_id,
            availability = :external_required,
            artifact = req.artifact,
        ))
    else
        push!(entries, ManifestEntry(
            object_id;
            revision_id = target_rev,
            content_id = nothing,
            availability = :missing,
        ))
        push!(diagnostics, error_diagnostic(
            :missing_manifest_object,
            "revision $(revision_id.value) names missing object $(object_id.value)";
            revision_id = revision_id.value,
            object_id = object_id.value,
            target_revision_id = target_rev === nothing ? nothing : target_rev.value,
        ))
    end
    return nothing
end

function _revision_manifest(
    graph::ArchiveGraph,
    revision_id::RevisionId;
    mode::Symbol,
    externals = ExternalRequirement[],
)
    mode in MANIFEST_MODES || throw(ArgumentError(
        "mode must be one of $MANIFEST_MODES, got :$mode",
    ))
    rec = find_revision(graph, revision_id)
    rec === nothing && throw(ArgumentError(
        "revision $(revision_id.value) is not in the archive graph",
    ))
    reqs = _externals_vector(externals)
    diagnostics = DiagnosticMessage[]
    visible = _visible_revision_order(graph, revision_id)
    _append_visible_revision_diagnostics!(diagnostics, graph, visible)
    queue = find_objects(graph, revision_id)
    seen = Set{String}()
    entries = ManifestEntry[]
    unresolved = String[]
    while !isempty(queue)
        object = popfirst!(queue)
        key = _entry_key(object.object_id, object.revision_id)
        key in seen && continue
        push!(seen, key)
        push!(entries, ManifestEntry(
            object.object_id;
            object = object,
            revision_id = object.revision_id,
            content_id = object.content_id,
            availability = :envelope_only,
        ))
        for ref in ordered_references(object)
            resolved = _resolve_in_revision_scope(graph, ref.target, visible)
            if resolved === nothing
                _push_unresolved_entry!(
                    entries,
                    diagnostics,
                    reqs,
                    revision_id,
                    ref.target.object_id,
                    ref.target.revision_id,
                    unresolved,
                )
            else
                push!(queue, resolved)
            end
        end
    end
    heads = WorkflowHead[]
    for head in ordered_heads(graph)
        head.revision_id == revision_id && push!(heads, head)
    end
    run = rec.run_id === nothing ? nothing : find_run(graph, rec.run_id)
    return RevisionManifest(
        mode,
        rec,
        entries,
        heads,
        run,
        rec.plan_id,
        RevisionId[parent.id for parent in revision_parents(graph, revision_id)],
        RevisionId[child.id for child in revision_children(graph, revision_id)],
        RevisionId[anc.id for anc in revision_ancestors(graph, revision_id)],
        RevisionId[desc.id for desc in revision_descendants(graph, revision_id)],
        reqs,
        diagnostics,
    )
end

"""
    inspect(graph, revision_id; externals=()) -> RevisionManifest

In-memory lazy manifest. No file I/O and no payload load. Domain payload
packages are not required.
"""
function inspect(graph::ArchiveGraph, revision_id::RevisionId; externals = ExternalRequirement[])
    return _revision_manifest(graph, revision_id; mode = :inspect, externals = externals)
end

function inspect(graph::ArchiveGraph, head::WorkflowHead; externals = ExternalRequirement[])
    return inspect(graph, head.revision_id; externals = externals)
end

function inspect(graph::ArchiveGraph, head_id::WorkflowHeadId; externals = ExternalRequirement[])
    head = find_head(graph, head_id)
    head === nothing && throw(ArgumentError("workflow head $(head_id.value) is not in the archive graph"))
    return inspect(graph, head; externals = externals)
end

function inspect(graph::ArchiveGraph, name::Symbol; externals = ExternalRequirement[])
    head = find_head(graph, name)
    head === nothing && throw(ArgumentError("no workflow head named :$name"))
    return inspect(graph, head; externals = externals)
end

function inspect(graph::ArchiveGraph, run_id::RunId; externals = ExternalRequirement[])
    run = find_run(graph, run_id)
    run === nothing && throw(ArgumentError("run $(run_id.value) is not in the archive graph"))
    run.revision_id === nothing && throw(ArgumentError(
        "run $(run_id.value) has no committed revision to inspect",
    ))
    return inspect(graph, run.revision_id; externals = externals)
end

"""
    checkout(graph, revision_id; externals=()) -> RevisionManifest

Lazy checkout of a committed snapshot from an in-memory graph. Distinct
from [`inspect`](@ref): this is the state-manifest primitive. Payloads
stay unloaded. File-path AH5 checkout is later JLD2 work and must return
the same [`RevisionManifest`](@ref) contract.
"""
function checkout(graph::ArchiveGraph, revision_id::RevisionId; externals = ExternalRequirement[])
    return _revision_manifest(graph, revision_id; mode = :checkout, externals = externals)
end

function checkout(graph::ArchiveGraph, head::WorkflowHead; externals = ExternalRequirement[])
    return checkout(graph, head.revision_id; externals = externals)
end

"""
    select(manifest, object_id) -> Union{ManifestEntry,Nothing}
    select(manifest, object_id, revision_id)
    select(manifest, object_ref)

Return one lazy slot. Does not load payload bytes. If `object_id` alone
matches several versions in the closure, this throws; pin a
[`RevisionId`](@ref) or [`ObjectRef`](@ref).
"""
function select(manifest::RevisionManifest, object_id::ObjectId)
    matches = ManifestEntry[]
    for entry in manifest.entries
        entry.object_id == object_id && push!(matches, entry)
    end
    isempty(matches) && return nothing
    length(matches) > 1 && throw(ArgumentError(
        "object $(object_id.value) has multiple versions in this manifest; select by revision",
    ))
    return matches[1]
end

function select(manifest::RevisionManifest, object_id::ObjectId, revision_id::RevisionId)
    for entry in manifest.entries
        entry.object_id == object_id && entry.revision_id == revision_id && return entry
    end
    return nothing
end

function select(manifest::RevisionManifest, ref::ObjectRef)
    ref.revision_id === nothing && return select(manifest, ref.object_id)
    return select(manifest, ref.object_id, ref.revision_id)
end

"""
    branch_from(from; id, name) -> WorkflowHead

Bookmark a historical revision. Does not mutate the revision or its
objects. Caller inserts the head into a new graph if desired.
"""
function branch_from(from::RevisionId; id::WorkflowHeadId, name::Symbol)
    return WorkflowHead(id, name, from)
end

function validate(manifest::RevisionManifest)
    diagnostics = DiagnosticMessage[manifest.diagnostics...]
    for entry in manifest.entries
        entry.availability === :missing || continue
        any(d -> d.code === :missing_manifest_object &&
                get(d.context, :object_id, nothing) == entry.object_id.value,
            diagnostics) && continue
        push!(diagnostics, error_diagnostic(
            :missing_manifest_object,
            "manifest names missing object $(entry.object_id.value)";
            object_id = entry.object_id.value,
            revision_id = manifest.revision.id.value,
        ))
    end
    return ValidationReport(
        :revision_manifest,
        isempty(diagnostics),
        diagnostics,
        (;
            revision_id = manifest.revision.id.value,
            mode = manifest.mode,
            objects = count(e -> e.availability === :envelope_only, manifest.entries),
            externals = count(e -> e.availability === :external_required, manifest.entries),
            missing = count(e -> e.availability === :missing, manifest.entries),
        ),
    )
end

function report(manifest::RevisionManifest)
    n = count(e -> e.availability === :envelope_only, manifest.entries)
    return ObjectReport(
        :revision_manifest,
        "Revision manifest $(manifest.revision.id.value) with $n envelope objects.",
        (;
            revision_id = manifest.revision.id.value,
            mode = manifest.mode,
            objects = n,
            heads = length(manifest.heads),
            run_id = manifest.run === nothing ? nothing : manifest.run.id.value,
            externals = count(e -> e.availability === :external_required, manifest.entries),
            missing = count(e -> e.availability === :missing, manifest.entries),
        ),
        copy(manifest.diagnostics),
        ArtifactRef[],
    )
end

function readiness(manifest::RevisionManifest, target::PipelineTarget)
    if target.name === :inspect
        return _manifest_inspect_readiness(manifest, target)
    elseif target.name === :replay
        return _manifest_replay_readiness(manifest, target)
    elseif target.name === :restart
        return _manifest_restart_readiness(manifest, target)
    elseif target.name === :rerun
        return _manifest_rerun_readiness(manifest, target)
    end
    return ReadinessReport(
        :revision_manifest,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "revision manifest readiness target :$(target.name) is not :inspect, :replay, :restart, or :rerun";
            target = target.name,
        )],
        (; revision_id = manifest.revision.id.value),
    )
end

function _manifest_inspect_readiness(manifest::RevisionManifest, target::PipelineTarget)
    report = validate(manifest)
    return ReadinessReport(
        :revision_manifest,
        target,
        isvalid(report),
        copy(report.diagnostics),
        (; revision_id = manifest.revision.id.value, mode = manifest.mode),
    )
end

function _append_external_dependency_diagnostics!(diagnostics, manifest::RevisionManifest)
    for entry in manifest.entries
        entry.availability === :external_required || continue
        push!(diagnostics, error_diagnostic(
            :external_content_required,
            "revision $(manifest.revision.id.value) requires external object $(entry.object_id.value)";
            revision_id = manifest.revision.id.value,
            object_id = entry.object_id.value,
            content_id = entry.content_id === nothing ? nothing : entry.content_id.value,
        ))
    end
    return diagnostics
end

function _manifest_replay_readiness(manifest::RevisionManifest, target::PipelineTarget)
    diagnostics = DiagnosticMessage[validate(manifest).diagnostics...]
    _append_external_dependency_diagnostics!(diagnostics, manifest)
    if manifest.run === nothing
        push!(diagnostics, error_diagnostic(
            :replay_run_missing,
            "revision $(manifest.revision.id.value) has no producing run to replay";
            revision_id = manifest.revision.id.value,
        ))
    elseif manifest.run.software_environment === nothing
        push!(diagnostics, error_diagnostic(
            :replay_environment_unknown,
            "run $(manifest.run.id.value) did not record a software environment";
            revision_id = manifest.revision.id.value,
            run_id = manifest.run.id.value,
        ))
    end
    return ReadinessReport(
        :revision_manifest,
        target,
        isempty(diagnostics),
        diagnostics,
        (;
            revision_id = manifest.revision.id.value,
            run_id = manifest.run === nothing ? nothing : manifest.run.id.value,
        ),
    )
end

function _manifest_entry_satisfies(entry::ManifestEntry, checkpoint::CheckpointRef)
    entry.object_id == checkpoint.object_id || return false
    entry.availability === :envelope_only || return false
    if checkpoint.revision_id !== nothing
        entry.revision_id == checkpoint.revision_id || return false
    end
    if checkpoint.content_id !== nothing
        entry.content_id === nothing && return false
        entry.content_id == checkpoint.content_id || return false
    end
    return true
end

function _manifest_restart_readiness(manifest::RevisionManifest, target::PipelineTarget)
    diagnostics = DiagnosticMessage[validate(manifest).diagnostics...]
    run = manifest.run
    req = run === nothing ? nothing : run.restart
    if req === nothing || isempty(req.checkpoints)
        push!(diagnostics, error_diagnostic(
            :restart_not_declared,
            "revision $(manifest.revision.id.value) does not declare restart checkpoints";
            revision_id = manifest.revision.id.value,
            run_id = run === nothing ? nothing : run.id.value,
        ))
    else
        for checkpoint in req.checkpoints
            any(entry -> _manifest_entry_satisfies(entry, checkpoint), manifest.entries) && continue
            push!(diagnostics, error_diagnostic(
                :missing_restart_checkpoint,
                "restart checkpoint $(checkpoint.object_id.value) is not in this revision manifest";
                revision_id = manifest.revision.id.value,
                object_id = checkpoint.object_id.value,
                content_id = checkpoint.content_id === nothing ? nothing :
                    checkpoint.content_id.value,
            ))
        end
    end
    return ReadinessReport(
        :revision_manifest,
        target,
        isempty(diagnostics),
        diagnostics,
        (;
            revision_id = manifest.revision.id.value,
            run_id = run === nothing ? nothing : run.id.value,
        ),
    )
end

function _manifest_rerun_readiness(manifest::RevisionManifest, target::PipelineTarget)
    diagnostics = DiagnosticMessage[validate(manifest).diagnostics...]
    _append_external_dependency_diagnostics!(diagnostics, manifest)
    run = manifest.run
    if run === nothing
        push!(diagnostics, error_diagnostic(
            :rerun_run_missing,
            "revision $(manifest.revision.id.value) has no producing run to rerun";
            revision_id = manifest.revision.id.value,
        ))
    elseif isempty(run.activities)
        push!(diagnostics, error_diagnostic(
            :rerun_activity_missing,
            "run $(run.id.value) has no activity to rerun from";
            revision_id = manifest.revision.id.value,
            run_id = run.id.value,
        ))
    end
    return ReadinessReport(
        :revision_manifest,
        target,
        isempty(diagnostics),
        diagnostics,
        (;
            revision_id = manifest.revision.id.value,
            run_id = run === nothing ? nothing : run.id.value,
            activities = run === nothing ? 0 : length(run.activities),
        ),
    )
end

to_namedtuple(req::ExternalRequirement) = (
    object_id = req.object_id.value,
    content_id = req.content_id === nothing ? nothing : req.content_id.value,
    artifact = (
        kind = req.artifact.kind,
        path = req.artifact.path,
        uri = req.artifact.uri,
        description = req.artifact.description,
    ),
)

to_namedtuple(entry::ManifestEntry) = (
    object_id = entry.object_id.value,
    revision_id = entry.revision_id === nothing ? nothing : entry.revision_id.value,
    content_id = entry.content_id === nothing ? nothing : entry.content_id.value,
    availability = entry.availability,
    kind = entry.object === nothing ? nothing : entry.object.kind,
)

to_namedtuple(manifest::RevisionManifest) = (
    mode = manifest.mode,
    revision_id = manifest.revision.id.value,
    entries = Tuple(to_namedtuple.(manifest.entries)),
    heads = Tuple(to_namedtuple.(manifest.heads)),
    run_id = manifest.run === nothing ? nothing : manifest.run.id.value,
    plan_id = manifest.plan_id === nothing ? nothing : manifest.plan_id.value,
    parents = Tuple(id.value for id in manifest.parents),
    children = Tuple(id.value for id in manifest.children),
    ancestors = Tuple(id.value for id in manifest.ancestors),
    descendants = Tuple(id.value for id in manifest.descendants),
    externals = Tuple(to_namedtuple.(manifest.externals)),
)
