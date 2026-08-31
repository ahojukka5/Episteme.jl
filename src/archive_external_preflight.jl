# ---------------------------------------------------------------------------
# External-aware core AH5 preflight (#88)
# ---------------------------------------------------------------------------

"""
Return a validation-only copy of `graph` in which an otherwise dangling
ArchiveObject reference is removed when the same target ObjectId is satisfied
by a declared ExternalRequirement. Core AH5 only persists summaries/listings,
not ArchiveObject envelopes, so this copy changes no published authoritative
state. Higher state-history writers persist the original references unchanged.
"""
function _external_preflight_graph(
    graph::ArchiveGraph,
    externals::Vector{ExternalRequirement},
)
    isempty(externals) && return graph
    objects = ArchiveObject[]
    changed = false
    for object in graph.objects
        refs = ArchiveReference[]
        object_changed = false
        for ref in object.references
            if !_reference_resolves(graph, ref.target) &&
                    _match_external(externals, ref.target.object_id, nothing) !== nothing
                object_changed = true
                changed = true
                continue
            end
            push!(refs, ref)
        end
        if object_changed
            push!(objects, ArchiveObject(
                object.object_id,
                object.revision_id;
                content_id = object.content_id,
                run_id = object.run_id,
                namespace = object.namespace,
                kind = object.kind,
                schema = object.schema,
                provenance = object.provenance,
                references = refs,
            ))
        else
            push!(objects, object)
        end
    end
    changed || return graph
    return ArchiveGraph(
        objects;
        heads = graph.heads,
        revisions = graph.revisions,
        runs = graph.runs,
        events = graph.events,
        writes = graph.writes,
        log_streams = graph.log_streams,
    )
end

# The canonical writer is defined for AbstractString in archive_profile.jl.
# String is the normal filesystem-path type. This more-specific method performs
# only external-aware validation shaping, then invokes the canonical writer.
# Keyword arguments do not participate in Julia dispatch, so the positional
# String specialization is what makes this non-overwriting and precompile-safe.
function write_archive(
    path::String;
    graph = nothing,
    namespaces = nothing,
    schemas = nothing,
    externals = ExternalRequirement[],
    profile = nothing,
    kwargs...,
)
    external_values = _typed_vector(ExternalRequirement, externals, "external requirements")
    preflight_graph = graph isa ArchiveGraph ?
        _external_preflight_graph(graph, external_values) : graph
    return invoke(
        write_archive,
        Tuple{AbstractString},
        path;
        graph = preflight_graph,
        namespaces = namespaces,
        schemas = schemas,
        externals = external_values,
        profile = profile,
        kwargs...,
    )
end
