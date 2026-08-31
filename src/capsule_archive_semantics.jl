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

function _refuse_capsule_source_signature_mismatch(
    source_graph::ArchiveGraph,
    plan::CapsulePlan,
    externals,
)
    expected = plan.source_signature
    expected === nothing && throw(ArgumentError(
        "capsule plan has no frozen retained-source signature",
    ))
    compacted = compact_archive(
        source_graph,
        [RetentionRoot(plan.source_revision)];
        policy = plan.retention.policy,
        externals = externals,
    )
    compacted.graph === nothing && throw(ArgumentError(
        "cannot re-freeze capsule source metadata: $(Tuple(d.code for d in compacted.report.diagnostics))",
    ))
    capsule_externals = _capsule_external_requirements(compacted.plan, externals)
    actual = _capsule_source_signature(compacted.graph, capsule_externals)
    actual == expected || throw(ArgumentError(
        "capsule retained-source signature no longer matches source graph",
    ))
    return expected
end

# The canonical writer re-checks state closure, compaction, schema/external sets,
# and integrity binding. This String specialization additionally proves that the
# entire retained metadata closure is still byte-for-byte logically identical
# to the snapshot frozen when CapsulePlan was created.
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
    _refuse_capsule_source_signature_mismatch(source_graph, plan, externals)
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

function _capsule_schema_ref_set(graph::ArchiveGraph)
    return Set(_integrity_schema_key(ref) for ref in _capsule_required_schema_refs(graph))
end

function _capsule_listing_schema_set(listings::Vector{SchemaListing})
    return Set(_integrity_schema_key(listing.schema) for listing in listings)
end

# The base capsule inspector proves each optional layer is internally valid.
# This String specialization additionally re-binds persisted integrity trust
# records to the reconstructed graph + embedded schemas + external requirements,
# checks minimality, and rejects payload-completeness claims this v1 slice could
# not have produced.
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

        manifest = view.manifest
        manifest === nothing && throw(ArgumentError("capsule manifest disappeared during inspection"))
        manifest.payloads_embedded && push!(diagnostics, error_diagnostic(
            :capsule_payload_claim_unsupported,
            "this capsule profile slice cannot claim embedded scientific payload bytes";
            capsule_archive_id = manifest.capsule_archive_id,
        ))
        manifest.external_objects == length(core.externals) || push!(diagnostics, error_diagnostic(
            :capsule_manifest_count_mismatch,
            "capsule external-object count disagrees with persisted external requirements";
            manifest = manifest.external_objects,
            records = length(core.externals),
        ))
        expected_schemas = _capsule_schema_ref_set(graph)
        stored_schemas = _capsule_listing_schema_set(core.schemas)
        expected_schemas == stored_schemas || push!(diagnostics, error_diagnostic(
            :capsule_schema_set_mismatch,
            "capsule embedded schema set is not the exact retained metadata schema closure";
            expected = Tuple(sort!(collect(expected_schemas))),
            stored = Tuple(sort!(collect(stored_schemas))),
        ))
    catch err
        push!(diagnostics, error_diagnostic(
            :capsule_integrity_binding_mismatch,
            "capsule integrity trust records do not bind to reconstructed archive metadata";
            path = path,
            reason = sprint(showerror, err),
        ))
    end

    if any(d -> d.severity === :error, diagnostics)
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

"""
    readiness(view::CapsuleArchiveInspection, target::PipelineTarget)

Capsule-level readiness includes physical payload availability, not merely the
reconstructed metadata graph. This first materialization slice is inspectable
but deliberately not replay/restart/rerun ready because scientific payload
bytes are not embedded.
"""
function readiness(view::CapsuleArchiveInspection, target::PipelineTarget)
    target.name in CAPSULE_TARGETS || return ReadinessReport(
        :capsule_archive,
        target,
        false,
        [error_diagnostic(
            :unsupported_target,
            "capsule readiness target :$(target.name) is not one of $CAPSULE_TARGETS";
            target = target.name,
        )],
        (; path = view.path),
    )
    if !isvalid(view) || view.manifest === nothing
        return ReadinessReport(
            :capsule_archive,
            target,
            false,
            copy(view.diagnostics),
            (; path = view.path),
        )
    end
    target.name === :inspect && return ReadinessReport(
        :capsule_archive,
        target,
        true,
        DiagnosticMessage[],
        (;
            path = view.path,
            capsule_archive_id = view.manifest.capsule_archive_id,
            payloads_embedded = view.manifest.payloads_embedded,
        ),
    )
    if !view.manifest.payloads_embedded
        return ReadinessReport(
            :capsule_archive,
            target,
            false,
            [error_diagnostic(
                :capsule_payloads_not_embedded,
                "capsule does not embed scientific payload bytes required for :$(target.name)";
                target = target.name,
                capsule_archive_id = view.manifest.capsule_archive_id,
            )],
            (;
                path = view.path,
                capsule_archive_id = view.manifest.capsule_archive_id,
                payloads_embedded = false,
            ),
        )
    end
    return ReadinessReport(
        :capsule_archive,
        target,
        false,
        [error_diagnostic(
            :capsule_payload_readiness_unimplemented,
            "payload-bearing capsule readiness is not implemented in this slice";
            target = target.name,
        )],
        (; path = view.path),
    )
end
