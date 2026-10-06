function _capsule_native_bytes(dir, payload)
    path = joinpath(dir, "native-$(payload.object_id.value)-$(payload.revision_id.value).jld2")
    JLD2.jldopen(path, "w") do file
        file["payload"] = payload.value
    end
    bytes = read(path)
    rm(path)
    return bytes
end

function _read_capsule_native_records(path)
    return JLD2.jldopen(path, "r"; plain = true) do file
        # NamedTuple is not concrete, so the indexed reader cannot allocate it.
        Episteme._read_indexed(Any, file, Episteme.AH5_CAPSULE_NATIVE_KEY,
            Episteme._refuse_capsule_native_record)
    end
end

function _capsule_native_keys(records)
    return Set(
        (record.object_id, record.revision_id, record.content_id) for record in records
    )
end

function _load_verified_native_payloads(path, entries)
    records = _read_capsule_native_records(path)
    payloads = Episteme.CapsulePayload[]
    for entry in entries
        entry.kind === :payload && entry.status === :included && entry.encoding == "native" || continue
        matched = nothing
        for record in records
            record.object_id == entry.object_id || continue
            record.revision_id == entry.revision_id || continue
            matched = record
            break
        end
        matched === nothing && throw(ArgumentError(
            "native capsule payload $(entry.object_id) @ $(entry.revision_id) is missing",
        ))
        matched.content_id == entry.content_id || throw(ArgumentError(
            "capsule native payload content identity mismatch",
        ))
        value = mktemp() do native_path, io
            write(io, matched.bytes)
            close(io)
            JLD2.jldopen(native_path, "r") do file
                file["payload"]
            end
        end
        identity = Episteme.canonical_content_id(value)
        identity.value == entry.content_id || throw(ArgumentError(
            "capsule native payload content identity mismatch",
        ))
        push!(payloads, Episteme.CapsulePayload(
            Episteme.ObjectId(entry.object_id), Episteme.RevisionId(entry.revision_id), value,
        ))
    end
    return payloads
end

function _capsule_software_registry(path, profile)
    profile === nothing && return nothing
    Episteme.AH5_SOFTWARE_ENVIRONMENTS_FEATURE in profile.features || return nothing
    view = Episteme.inspect_archive(path, Episteme.SoftwareEnvironmentRegistry)
    isvalid(view) || throw(ArgumentError("capsule software environment records are invalid"))
    return view.registry
end

function Episteme.write_capsule_archive(
    path::AbstractString, source::ArchiveGraph, plan::CapsulePlan, schemas::SchemaRegistry;
    source_archive_id::AbstractString, namespaces = nothing,
    externals = ExternalRequirement[], profile = nothing,
    software_environments = nothing, execution_contexts = nothing,
    payloads = Episteme.CapsulePayload[], documents = Episteme.PortableSemanticDocument[],
    redactions = Episteme.CapsuleRedaction[], native_policy::Bool = false, kwargs...,
)
    (ispath(path) || islink(path)) && throw(ArgumentError("archive already exists: $path"))
    compacted = Episteme._compact_capsule_source(source, plan, schemas; externals = externals)
    graph = compacted.graph::ArchiveGraph
    retained_schemas = Episteme._capsule_schemas(graph, schemas)
    retained_externals = Episteme._capsule_retained_externals(graph, plan, externals)
    bound = Episteme._bind_capsule_content(
        graph, plan, retained_schemas;
        payloads = payloads, documents = documents, redactions = redactions,
        native_policy = native_policy, software_environments = software_environments,
        execution_contexts = execution_contexts,
    )
    integrity = [plan.integrity]
    Episteme._refuse_integrity_archive_mismatch(
        integrity, graph, retained_schemas, retained_externals,
    )
    record = Episteme._capsule_profile(Episteme._profile_with_integrity(profile, kwargs))
    Episteme._refuse_integrity_root_collision(record)
    Episteme._refuse_capsule_root_collision(record)
    manifest = Episteme._capsule_manifest(
        record, source_archive_id, plan, bound.entries, bound.readiness, bound.payloads_embedded,
    )

    # Keep intermediate layers private, and publish only after forensic
    # inspection verifies the complete bundle. Native bytes are hashed before
    # they are stored and are not opened by plain inspection.
    mktempdir(dirname(abspath(path)); prefix = ".episteme-capsule-") do dir
        staged_path = joinpath(dir, "capsule.ah5")
        write_event_archive(staged_path, graph;
            namespaces = namespaces, schemas = retained_schemas,
            externals = retained_externals, profile = record,
            software_environments = bound.software, execution_contexts = bound.contexts)
        native_records = [
            Episteme._capsule_native_storage(payload, _capsule_native_bytes(dir, payload))
            for payload in bound.native
        ]
        JLD2.jldopen(staged_path, "r+") do file
            Episteme._write_indexed!(file, Episteme.AH5_INTEGRITY_KEY, integrity,
                Episteme._integrity_manifest_storage)
            file[Episteme.AH5_CAPSULE_KEY] = Episteme._capsule_manifest_storage(manifest)
            Episteme._write_indexed!(file, Episteme.AH5_CAPSULE_PAYLOADS_KEY, bound.portable,
                Episteme._capsule_payload_storage)
            Episteme._write_indexed!(file, Episteme.AH5_CAPSULE_DOCUMENTS_KEY, bound.documents,
                Episteme._capsule_document_storage)
            Episteme._write_indexed!(file, Episteme.AH5_CAPSULE_NATIVE_KEY, native_records, identity)
        end
        view = inspect_archive(staged_path, CapsuleManifest)
        if bound.contexts !== nothing
            isvalid(inspect_archive(staged_path, ExecutionContextRegistry)) ||
                throw(ArgumentError("new capsule failed execution context validation"))
        end
        if bound.software !== nothing
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

function _inspect_capsule_bundle(path, manifest, profile)
    history = inspect_archive(path, ArchiveEventHistory)
    integrity = inspect_archive(path, RevisionIntegrityManifest)
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
    core = inspect_archive(path)
    schemas = Episteme._capsule_schema_registry(core.schemas)
    filtered = Episteme._capsule_schemas(graph, schemas)
    length(filtered.entries) == length(schemas.entries) || throw(ArgumentError(
        "capsule includes schemas outside its retained envelopes",
    ))
    Episteme._refuse_integrity_archive_mismatch(integrity.manifests, graph, schemas, history.externals)
    payloads, documents, native_keys = JLD2.jldopen(path, "r"; plain = true) do file
        loaded_payloads = Episteme._read_indexed(
            Episteme.CapsulePayload, file, Episteme.AH5_CAPSULE_PAYLOADS_KEY,
            Episteme._restore_capsule_payload,
        )
        loaded_documents = Episteme._read_indexed(
            Episteme.PortableSemanticDocument, file, Episteme.AH5_CAPSULE_DOCUMENTS_KEY,
            Episteme._restore_capsule_document,
        )
        loaded_native = Any[]
        if Episteme._jld2_get(file, Episteme._count_key(Episteme.AH5_CAPSULE_NATIVE_KEY)) !== nothing
            loaded_native = Episteme._read_indexed(
                Any, file, Episteme.AH5_CAPSULE_NATIVE_KEY, Episteme._refuse_capsule_native_record,
            )
        end
        return loaded_payloads, loaded_documents, _capsule_native_keys(loaded_native)
    end
    Episteme._verify_portable_capsule_payloads(payloads, manifest.content, selected)
    Episteme._verify_capsule_dispositions(graph, manifest, documents, native_keys)
    software = _capsule_software_registry(path, profile)
    achieved = Episteme._capsule_achieved_readiness(
        graph, only(manifest.root_revisions), manifest.content;
        externals = history.externals, software = software, native_verified = false,
    )
    (achieved.inspectable, achieved.replayable, achieved.restartable, achieved.rerunnable) ==
        (manifest.readiness.inspectable, manifest.readiness.replayable,
         manifest.readiness.restartable, manifest.readiness.rerunnable) || throw(ArgumentError(
        "capsule readiness claim does not match its content",
    ))
    manifest = Episteme.CapsuleManifest(
        manifest.format_version, manifest.archive_id, manifest.source_archive_id,
        manifest.root_revisions, manifest.target, manifest.verification, manifest.counts,
        manifest.payloads_embedded, manifest.content,
        Episteme.CapsuleReadiness(
            achieved.inspectable, achieved.replayable, achieved.restartable, achieved.rerunnable,
            achieved.diagnostics,
        ),
    )
    return manifest, payloads, documents, achieved
end

function Episteme.inspect_archive(path::AbstractString, ::Type{CapsuleManifest})
    base = inspect_archive(path)
    diagnostics = copy(base.diagnostics)
    declared = base.profile !== nothing && Episteme.AH5_CAPSULE_FEATURE in base.profile.features
    manifest = nothing
    payloads = Episteme.CapsulePayload[]
    documents = Episteme.PortableSemanticDocument[]
    achieved = Episteme._empty_capsule_readiness()
    if base.identified && declared && !any(d -> d.severity === :error, diagnostics)
        try
            manifest = JLD2.jldopen(path, "r"; plain = true) do file
                Episteme._restore_capsule_manifest(file[Episteme.AH5_CAPSULE_KEY])
            end
            manifest.archive_id == base.profile.archive_id || throw(ArgumentError(
                "capsule manifest identity differs from AH5 profile",
            ))
            if manifest.format_version == 1
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
                     manifest.counts.retained_runs) || throw(ArgumentError(
                    "capsule retained counts disagree with metadata",
                ))
                schemas = Episteme._capsule_schema_registry(base.schemas)
                filtered = Episteme._capsule_schemas(graph, schemas)
                length(filtered.entries) == length(schemas.entries) || throw(ArgumentError(
                    "capsule includes schemas outside its retained envelopes",
                ))
                Episteme._refuse_integrity_archive_mismatch(
                    integrity.manifests, graph, schemas, history.externals,
                )
                achieved = Episteme.CapsuleReadiness(true, false, false, false)
                manifest = Episteme.CapsuleManifest(
                    manifest.format_version, manifest.archive_id, manifest.source_archive_id,
                    manifest.root_revisions, manifest.target, manifest.verification, manifest.counts,
                    manifest.payloads_embedded, manifest.content, achieved,
                )
            else
                manifest, payloads, documents, achieved = _inspect_capsule_bundle(path, manifest, base.profile)
            end
        catch err
            manifest = nothing
            payloads = Episteme.CapsulePayload[]
            documents = Episteme.PortableSemanticDocument[]
            achieved = Episteme._empty_capsule_readiness()
            push!(diagnostics, error_diagnostic(:corrupt_capsule_manifest,
                "AH5 capsule metadata is invalid"; reason = sprint(showerror, err)))
        end
    end
    return ArchiveCapsuleInspection(String(path), base.identified, declared,
        base.identified && !any(d -> d.severity === :error, diagnostics), manifest,
        payloads, documents, achieved, diagnostics)
end

function Episteme.verify_capsule(path::AbstractString; native_policy::Bool = false)
    view = inspect_archive(path, CapsuleManifest)
    diagnostics = copy(view.diagnostics)
    if !isvalid(view) || view.manifest === nothing
        return Episteme.CapsuleVerification(
            String(path), false, Episteme._empty_capsule_readiness(diagnostics),
            Episteme.CapsulePayload[], diagnostics,
        )
    end
    native_payloads = Episteme.CapsulePayload[]
    native_ok = true
    if native_policy && Episteme._capsule_needs_native(view.manifest.content)
        try
            native_payloads = _load_verified_native_payloads(path, view.manifest.content)
        catch err
            native_ok = false
            push!(diagnostics, error_diagnostic(
                :capsule_native_verification_failed,
                "trusted native capsule replay failed integrity verification";
                reason = sprint(showerror, err),
            ))
        end
    end
    achieved = view.achieved
    if native_policy && native_ok && Episteme._capsule_needs_native(view.manifest.content)
        history = inspect_archive(path, ArchiveEventHistory)
        graph = reconstruct_graph(history)
        software = _capsule_software_registry(path, inspect_archive(path).profile)
        achieved = Episteme._capsule_achieved_readiness(
            graph, only(view.manifest.root_revisions), view.manifest.content;
            externals = history.externals, software = software, native_verified = true,
        )
    end
    payloads = Episteme.CapsulePayload[]
    append!(payloads, view.payloads)
    native_ok && append!(payloads, native_payloads)
    return Episteme.CapsuleVerification(String(path), native_ok, achieved, payloads, diagnostics)
end
