function Episteme.write_capsule_archive(
    path::AbstractString, source::ArchiveGraph, plan::CapsulePlan, schemas::SchemaRegistry;
    source_archive_id::AbstractString, namespaces = nothing,
    externals = ExternalRequirement[], profile = nothing,
    software_environments = nothing, kwargs...,
)
    (ispath(path) || islink(path)) && throw(ArgumentError("archive already exists: $path"))
    compacted = Episteme._compact_capsule_source(source, plan, schemas; externals = externals)
    graph = compacted.graph::ArchiveGraph
    retained_schemas = Episteme._capsule_schemas(graph, schemas)
    retained_externals = Episteme._capsule_retained_externals(graph, plan, externals)
    integrity = [plan.integrity]
    Episteme._refuse_integrity_archive_mismatch(integrity, graph, retained_schemas, retained_externals)
    record = Episteme._capsule_profile(Episteme._profile_with_integrity(profile, kwargs))
    Episteme._refuse_integrity_root_collision(record)
    Episteme._refuse_capsule_root_collision(record)
    manifest = Episteme._capsule_manifest(record, source_archive_id, plan)

    # Keep intermediate layers private, and publish only after forensic
    # inspection verifies the complete metadata bundle.
    mktempdir(dirname(abspath(path)); prefix = ".episteme-capsule-") do dir
        staged_path = joinpath(dir, "capsule.ah5")
        write_event_archive(staged_path, graph;
            namespaces = namespaces, schemas = retained_schemas,
            externals = retained_externals, profile = record,
            software_environments = software_environments)
        JLD2.jldopen(staged_path, "r+") do file
            Episteme._write_indexed!(file, Episteme.AH5_INTEGRITY_KEY, integrity,
                Episteme._integrity_manifest_storage)
            file[Episteme.AH5_CAPSULE_KEY] = Episteme._capsule_manifest_storage(manifest)
        end
        view = inspect_archive(staged_path, CapsuleManifest)
        if software_environments !== nothing
            isvalid(inspect_archive(staged_path, SoftwareEnvironmentRegistry)) ||
                throw(ArgumentError("new capsule failed software environment validation"))
        end
        isvalid(view) || throw(ArgumentError(
            "new capsule failed forensic validation: $(Tuple(d.code for d in view.diagnostics))",
        ))
        # Both paths are on the same filesystem. Link creation atomically
        # refuses an existing name, including one created during validation.
        hardlink(staged_path, path)
    end
    return CapsuleArchiveResult(String(path), manifest, compacted.source_unchanged)
end

function Episteme.inspect_archive(path::AbstractString, ::Type{CapsuleManifest})
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    declared = base.profile !== nothing && Episteme.AH5_CAPSULE_FEATURE in base.profile.features
    manifest = nothing
    if base.identified && declared && !any(d -> d.severity === :error, diagnostics)
        try
            manifest = JLD2.jldopen(path, "r"; plain = true) do file
                Episteme._restore_capsule_manifest(file[Episteme.AH5_CAPSULE_KEY])
            end
            manifest.archive_id == base.profile.archive_id || throw(ArgumentError(
                "capsule manifest identity differs from AH5 profile",
            ))
            history = inspect_archive(path, ArchiveEventHistory)
            integrity = inspect_archive(path, RevisionIntegrityManifest)
            append!(diagnostics, history.diagnostics)
            append!(diagnostics, integrity.diagnostics)
            history.feature_declared && isvalid(history) || throw(ArgumentError(
                "capsule requires valid authoritative event history",
            ))
            integrity.feature_declared && isvalid(integrity) || throw(ArgumentError(
                "capsule requires valid revision integrity metadata",
            ))
            graph = reconstruct_graph(history)
            length(integrity.manifests) == 1 || throw(ArgumentError("capsule requires one integrity manifest"))
            selected = only(integrity.manifests)
            selected.revision_id == only(manifest.root_revisions) || throw(ArgumentError(
                "capsule root differs from integrity revision",
            ))
            selected.requested_level === manifest.verification || throw(ArgumentError(
                "capsule verification differs from integrity metadata",
            ))
            (length(graph.objects), length(graph.revisions), length(graph.runs)) ==
                (manifest.counts.retained_objects, manifest.counts.retained_revisions,
                 manifest.counts.retained_runs) || throw(ArgumentError("capsule retained counts disagree with metadata"))
            schemas = Episteme._capsule_schema_registry(base.schemas)
            filtered = Episteme._capsule_schemas(graph, schemas)
            length(filtered.entries) == length(schemas.entries) || throw(ArgumentError(
                "capsule includes schemas outside its retained envelopes",
            ))
            Episteme._refuse_integrity_archive_mismatch(integrity.manifests, graph, schemas, history.externals)
        catch err
            push!(diagnostics, error_diagnostic(:corrupt_capsule_manifest,
                "AH5 capsule metadata is invalid"; reason = sprint(showerror, err)))
        end
    end
    return ArchiveCapsuleInspection(String(path), base.identified, declared,
        base.identified && !any(d -> d.severity === :error, diagnostics), manifest, diagnostics)
end
