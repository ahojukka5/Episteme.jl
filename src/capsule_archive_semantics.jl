# ---------------------------------------------------------------------------
# Capsule materialization semantic refinements (#87)
# ---------------------------------------------------------------------------

# Capsule materialization composes the event-history writer with a later
# integrity append rather than entering through #77's positional writer. Run
# the same integrity-root collision guard when the final ArchiveProfile is
# assembled so custom inspectable roots cannot occupy episteme/integrity.
function _capsule_archive_profile(profile::ArchiveProfile, capsule_archive_id)
    result = invoke(
        _capsule_archive_profile,
        Tuple{Any,Any},
        profile,
        capsule_archive_id,
    )
    _refuse_integrity_root_collision(result)
    return result
end

function _capsule_run_signature(run)
    run === nothing && return nothing
    run isa RunRecord || throw(ArgumentError("capsule manifest run must be RunRecord or nothing"))
    return _run_record_storage(run)
end

function _refuse_capsule_run_mismatch(source::RevisionManifest, planned::RevisionManifest)
    _capsule_run_signature(source.run) == _capsule_run_signature(planned.run) ||
        throw(ArgumentError("capsule plan producing-run provenance no longer matches source graph"))
    return planned
end

# The main writer already re-checks state closure and retention. This String
# specialization adds exact producing-run/activity/staged/restart binding before
# delegating to the canonical AbstractString implementation.
function write_capsule_archive(
    path::String,
    source_graph::ArchiveGraph,
    plan::CapsulePlan,
    schemas::SchemaRegistry;
    source_archive_id::AbstractString,
    namespaces = nothing,
    externals = ExternalRequirement[],
    capsule_archive_id = nothing,
    profile = nothing,
)
    source_manifest = inspect(source_graph, plan.source_revision; externals = externals)
    _refuse_capsule_run_mismatch(source_manifest, plan.manifest)
    return invoke(
        write_capsule_archive,
        Tuple{AbstractString,ArchiveGraph,CapsulePlan,SchemaRegistry},
        path,
        source_graph,
        plan,
        schemas;
        source_archive_id = source_archive_id,
        namespaces = namespaces,
        externals = externals,
        capsule_archive_id = capsule_archive_id,
        profile = profile,
    )
end

function _capsule_schema_registry_from_listings(listings::Vector{SchemaListing})
    definitions = SchemaDefinition[]
    for listing in listings
        push!(definitions, SchemaDefinition(
            listing.schema;
            namespace = listing.namespace,
            compatibility = listing.compatibility,
            fields = SchemaField[listing.fields...],
            node_schema = listing.node_schema,
            documentation = listing.documentation,
            package_version = listing.package_version,
            replaces = listing.replaces,
            replaced_by = listing.replaced_by,
            migration = listing.migration,
        ))
    end
    return SchemaRegistry(definitions)
end

# The base capsule inspector proves each optional layer is internally valid.
# This String specialization additionally re-binds persisted integrity trust
# records to the reconstructed graph + embedded schemas + external requirements,
# so a crafted state/schema mutation cannot survive as a valid capsule merely
# because both layers remain individually parseable.
function inspect_archive(path::String, ::Type{CapsuleArchiveManifest})
    view = invoke(
        inspect_archive,
        Tuple{AbstractString,Type{CapsuleArchiveManifest}},
        path,
        CapsuleArchiveManifest,
    )
    isvalid(view) || return view

    diagnostics = copy(view.diagnostics)
    try
        core = inspect_archive(path)
        event_view = inspect_archive(path, ArchiveEventHistory)
        integrity_view = inspect_archive(path, RevisionIntegrityManifest)
        isvalid(event_view) || throw(ArgumentError("capsule event history is invalid"))
        isvalid(integrity_view) || throw(ArgumentError("capsule integrity records are invalid"))
        graph = reconstruct_graph(event_view)
        schemas = _capsule_schema_registry_from_listings(core.schemas)
        _refuse_integrity_archive_mismatch(
            integrity_view.manifests,
            graph,
            schemas,
            core.externals,
        )
    catch err
        push!(diagnostics, error_diagnostic(
            :capsule_integrity_binding_mismatch,
            "capsule integrity trust records do not bind to reconstructed archive metadata";
            path = path,
            reason = sprint(showerror, err),
        ))
        return CapsuleArchiveInspection(
            path,
            true,
            true,
            false,
            nothing,
            diagnostics,
        )
    end
    return view
end
