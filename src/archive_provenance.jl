# ---------------------------------------------------------------------------
# Practical provenance queries over ArchiveGraph (#107)
# ---------------------------------------------------------------------------

"""
    producing_run(graph, object) -> Union{RunRecord,Nothing}

The run that generated this envelope row, if recorded.
"""
function producing_run(graph::ArchiveGraph, object::ArchiveObject)
    object.run_id === nothing && return nothing
    return find_run(graph, object.run_id)
end

function producing_run(graph::ArchiveGraph, object_id::ObjectId, revision_id::RevisionId)
    object = find_object(graph, object_id, revision_id)
    object === nothing && return nothing
    return producing_run(graph, object)
end

"""
    producing_activity(graph, object) -> Union{ActivityRecord,Nothing}

The activity in the producing run that generated `object.object_id`.
"""
function producing_activity(graph::ArchiveGraph, object::ArchiveObject)
    run = producing_run(graph, object)
    run === nothing && return nothing
    for activity in run.activities
        for ref in activity.generated
            ref.target.object_id == object.object_id && return activity
        end
    end
    for staged in run.staged
        staged.object_id == object.object_id || continue
        staged.activity_id === nothing && continue
        for activity in run.activities
            activity.id == staged.activity_id && return activity
        end
    end
    return nothing
end

"""
    used_inputs(graph, object) -> Vector{ArchiveReference}

Named inputs recorded on the envelope and on the producing activity.
"""
function used_inputs(graph::ArchiveGraph, object::ArchiveObject)
    refs = ArchiveReference[object.references...]
    activity = producing_activity(graph, object)
    activity === nothing && return refs
    for ref in activity.used
        any(existing -> existing.target == ref.target && existing.name === ref.name, refs) &&
            continue
        push!(refs, ref)
    end
    return refs
end

"""
    previous_revision(graph, object_id, revision_id) -> Union{ArchiveObject,Nothing}

The same `ObjectId` at the nearest parent revision, if present.
"""
function previous_revision(graph::ArchiveGraph, object_id::ObjectId, revision_id::RevisionId)
    rec = find_revision(graph, revision_id)
    rec === nothing && return nothing
    for parent in rec.parents
        object = find_object(graph, object_id, parent)
        object === nothing || return object
        older = previous_revision(graph, object_id, parent)
        older === nothing || return older
    end
    return nothing
end

"""
    dependents(graph, object_id, revision_id) -> Vector{ArchiveObject}

Committed objects that name this object/revision as a reference.
"""
function dependents(graph::ArchiveGraph, object_id::ObjectId, revision_id::RevisionId)
    rows = ArchiveObject[]
    for object in ordered_objects(graph)
        for ref in object.references
            ref.target.object_id == object_id || continue
            if ref.target.revision_id === nothing || ref.target.revision_id == revision_id
                push!(rows, object)
            end
        end
    end
    return rows
end

"""
    software_environment_of(graph, object) -> Union{SoftwareEnvironmentId,Nothing}
"""
function software_environment_of(graph::ArchiveGraph, object::ArchiveObject)
    object.provenance.software_environment !== nothing &&
        return object.provenance.software_environment
    run = producing_run(graph, object)
    run === nothing && return nothing
    return run.software_environment
end

function validation_events(graph::ArchiveGraph, run_id::RunId)
    rows = EventRecord[]
    for event in ordered_run_events(graph, run_id)
        event.kind === :validation_failed || event.kind === :committed || continue
        push!(rows, event)
    end
    return rows
end
