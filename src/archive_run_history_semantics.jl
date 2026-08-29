# ---------------------------------------------------------------------------
# Run-scope semantic refinements for AH5 run-history validation (#83)
# ---------------------------------------------------------------------------

function _run_local_staged_resolves(graph::ArchiveGraph, run_id, ref::ObjectRef)
    ref.revision_id === nothing || return false
    run_id === nothing && return false
    rid = run_id isa RunId ? run_id : RunId(string(run_id))
    run = find_run(graph, rid)
    run === nothing && return false
    return any(staged -> staged.object_id == ref.object_id, run.staged)
end

# More specific than the generic implementation in archive_run_history.jl.
# Activity/staged references are allowed to name an uncommitted staged object
# only inside the same run and only when the ObjectRef is unpinned.
function _validate_run_ref!(
    diagnostics,
    graph::ArchiveGraph,
    externals::Vector{ExternalRequirement},
    ref::ArchiveReference,
    code::Symbol,
    message::AbstractString;
    context...,
)
    run_id = get(context, :run_id, nothing)
    if _reference_resolves(graph, ref.target) ||
            _run_local_staged_resolves(graph, run_id, ref.target) ||
            _match_external(externals, ref.target.object_id, nothing) !== nothing
        return diagnostics
    end
    push!(diagnostics, error_diagnostic(
        code,
        message;
        object_id = ref.target.object_id.value,
        target_revision_id = ref.target.revision_id === nothing ? nothing : ref.target.revision_id.value,
        name = ref.name,
        context...,
    ))
    return diagnostics
end
