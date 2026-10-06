# ---------------------------------------------------------------------------
# Reproduction-capsule content, disposition, and achieved readiness (#35)
#
# Planning (#79) and metadata publication (#87) stay in place. This layer
# embeds portable or explicitly trusted native state, records what was left
# out, and refuses to claim replay, restart, or rerun without that evidence.
# OS, language-runtime, and container images are never packaged.
# ---------------------------------------------------------------------------

struct CapsuleBoundContent
    entries::Vector{CapsuleContentEntry}
    portable::Vector{CapsulePayload}
    native::Vector{CapsulePayload}
    documents::Vector{PortableSemanticDocument}
    readiness::CapsuleReadiness
    software::Union{Nothing,SoftwareEnvironmentRegistry}
    contexts::Union{Nothing,ExecutionContextRegistry}
    payloads_embedded::Bool
end

"""Trusted replay result. Generic inspection does not deserialize native state."""
struct CapsuleVerification <: AbstractValidationReport
    path::String
    valid::Bool
    readiness::CapsuleReadiness
    payloads::Vector{CapsulePayload}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(report::CapsuleVerification) = report.valid

function _capsule_documents(documents)
    documents === nothing && return PortableSemanticDocument[]
    documents isa PortableSemanticDocument && return PortableSemanticDocument[documents]
    return _typed_vector(PortableSemanticDocument, documents, "documents")
end

function _capsule_payload_vector(payloads)
    payloads === nothing && return CapsulePayload[]
    payloads isa CapsulePayload && return CapsulePayload[payloads]
    return _typed_vector(CapsulePayload, payloads, "payloads")
end

function _capsule_redactions(redactions)
    redactions === nothing && return CapsuleRedaction[]
    redactions isa CapsuleRedaction && return CapsuleRedaction[redactions]
    return _typed_vector(CapsuleRedaction, redactions, "redactions")
end

function _capsule_runtime_kind(kind::Symbol)
    name = lowercase(last(split(String(kind), "/")))
    return name in CAPSULE_REFUSED_RUNTIME_NAMES
end

function _capsule_secret(value)
    if value isa NamedTuple
        for name in keys(value)
            _looks_like_secret_name(String(name)) && return true
            _capsule_secret(value[name]) && return true
        end
    elseif value isa AbstractDict
        for (key, item) in pairs(value)
            if (key isa Symbol || key isa AbstractString) && _looks_like_secret_name(String(key))
                return true
            end
            _capsule_secret(item) && return true
        end
    elseif value isa PortableDict
        for (key, item) in value.entries
            if (key isa Symbol || key isa AbstractString) && _looks_like_secret_name(String(key))
                return true
            end
            _capsule_secret(item) && return true
        end
    elseif value isa PortableEncoded
        return _capsule_secret(value.data)
    elseif value isa Union{Tuple,AbstractArray}
        for item in value
            _capsule_secret(item) && return true
        end
    elseif value isa AbstractString
        return _looks_like_secret_value(value)
    end
    return false
end

function _capsule_value_secret(value)
    _capsule_secret(value) && return true
    is_portable_value(value) && return false
    projected = try
        canonical_content(value)
    catch
        return false
    end
    projected === value && return false
    return _capsule_secret(projected)
end

function _capsule_try_content_id(value)
    try
        return canonical_content_id(value)
    catch err
        err isa ArgumentError || rethrow()
        return nothing
    end
end

function _filter_capsule_software(graph::ArchiveGraph, registry)
    registry === nothing && return nothing
    registry isa SoftwareEnvironmentRegistry || throw(ArgumentError(
        "software_environments must be SoftwareEnvironmentRegistry or nothing",
    ))
    ids = ArchiveProvenanceSummary(graph).software_environments
    kept = SoftwareEnvironment[]
    for id in ids
        environment = find_software_environment(registry, SoftwareEnvironmentId(id))
        environment === nothing && throw(ArgumentError(
            "software environment record is missing: $id",
        ))
        push!(kept, environment)
    end
    return SoftwareEnvironmentRegistry(kept)
end

function _filter_capsule_contexts(graph::ArchiveGraph, registry)
    registry === nothing && return nothing
    registry isa ExecutionContextRegistry || throw(ArgumentError(
        "execution_contexts must be ExecutionContextRegistry or nothing",
    ))
    ids = ArchiveProvenanceSummary(graph).execution_contexts
    kept = ExecutionContext[]
    for id in ids
        context = find_execution_context(registry, ExecutionContextId(id))
        context === nothing && throw(ArgumentError("execution context record is missing: $id"))
        push!(kept, context)
    end
    return ExecutionContextRegistry(kept)
end

_capsule_id_text(id) = id === nothing ? "" : id.value

function _capsule_find_payload(payloads, object_id::ObjectId, revision_id::RevisionId)
    found = nothing
    for payload in payloads
        payload.object_id == object_id || continue
        payload.revision_id == revision_id || continue
        found === nothing || throw(ArgumentError(
            "duplicate capsule payload for $(object_id.value) @ $(revision_id.value)",
        ))
        found = payload
    end
    return found
end

function _capsule_redacted(redactions, object_id::ObjectId, revision_id::RevisionId)
    for redaction in redactions
        redaction.object_id == object_id || continue
        redaction.revision_id === nothing || redaction.revision_id == revision_id || continue
        return true
    end
    return false
end

function _push_content!(entries, kind, status; kwargs...)
    push!(entries, CapsuleContentEntry(kind, status; kwargs...))
    return entries
end

function _bind_reachable_payload!(
    entries, portable, native, object::ArchiveObject, payloads, redactions, native_policy::Bool,
)
    object_id = object.object_id.value
    revision_id = object.revision_id.value
    content_id = _capsule_id_text(object.content_id)
    common = (; object_id = object_id, revision_id = revision_id, content_id = content_id)
    if _capsule_runtime_kind(object.kind)
        _push_content!(entries, :payload, :omitted; common..., reason = :runtime_not_packaged)
        return nothing
    end
    if _capsule_redacted(redactions, object.object_id, object.revision_id)
        _push_content!(entries, :payload, :redacted; common..., reason = :caller_redacted)
        return nothing
    end
    supplied = _capsule_find_payload(payloads, object.object_id, object.revision_id)
    if supplied === nothing
        _push_content!(entries, :payload, :unavailable; common..., reason = :payload_not_supplied)
        return nothing
    end
    if _capsule_value_secret(supplied.value)
        _push_content!(entries, :payload, :redacted; common..., reason = :credential_like_content)
        return nothing
    end
    if is_portable_value(supplied.value)
        identity = canonical_content_id(supplied.value)
        identity == object.content_id || throw(ArgumentError(
            "capsule payload for $object_id @ $revision_id does not match its ContentId",
        ))
        push!(portable, supplied)
        _push_content!(entries, :payload, :included; common...,
            reason = :portable_state, encoding = "portable")
        return nothing
    end
    if !native_policy
        _push_content!(entries, :payload, :unavailable; common..., reason = :native_payload_refused)
        return nothing
    end
    identity = _capsule_try_content_id(supplied.value)
    if identity === nothing
        _push_content!(entries, :payload, :unavailable; common..., reason = :native_payload_unbound)
        return nothing
    end
    identity == object.content_id || throw(ArgumentError(
        "capsule native payload for $object_id @ $revision_id does not match its ContentId",
    ))
    push!(native, supplied)
    _push_content!(entries, :payload, :included; common...,
        reason = :native_trusted, encoding = "native")
    return nothing
end

function _capsule_software_rows!(entries, graph, software)
    for id in sort!(collect(ArchiveProvenanceSummary(graph).software_environments))
        recorded = software !== nothing &&
            find_software_environment(software, SoftwareEnvironmentId(id)) !== nothing
        _push_content!(entries, :software_environment, recorded ? :included : :unavailable;
            label = id, reason = recorded ? :recorded_provenance : :environment_record_missing)
    end
    return entries
end

function _capsule_context_rows!(entries, graph, contexts)
    for id in sort!(collect(ArchiveProvenanceSummary(graph).execution_contexts))
        recorded = contexts !== nothing &&
            find_execution_context(contexts, ExecutionContextId(id)) !== nothing
        _push_content!(entries, :execution_context, recorded ? :included : :unavailable;
            label = id, reason = recorded ? :recorded_provenance : :execution_context_record_missing)
    end
    return entries
end

function _capsule_document_rows!(entries, documents)
    seen = Set{String}()
    for document in documents
        isvalid(validate(document)) || throw(ArgumentError(
            "capsule document $(document.id.value) is not a valid portable document",
        ))
        document.id.value in seen && throw(ArgumentError(
            "duplicate capsule document $(document.id.value)",
        ))
        push!(seen, document.id.value)
        _push_content!(entries, :document, :included;
            label = document.id.value, reason = :portable_specification)
    end
    isempty(documents) && _push_content!(entries, :document, :unavailable;
        reason = :portable_specification_missing)
    return entries
end

"""
    _bind_capsule_content(graph, plan, schemas; kwargs...) -> CapsuleBoundContent

Classify retained, external, unavailable, redacted, and omitted content for a
compacted capsule graph. Does not write a file and does not mutate `graph`.
"""
function _bind_capsule_content(
    graph::ArchiveGraph,
    plan::CapsulePlan,
    schemas::SchemaRegistry;
    payloads = CapsulePayload[],
    documents = PortableSemanticDocument[],
    redactions = CapsuleRedaction[],
    native_policy::Bool = false,
    software_environments = nothing,
    execution_contexts = nothing,
)
    supplied = _capsule_payload_vector(payloads)
    docs = _capsule_documents(documents)
    drops = _capsule_redactions(redactions)
    software = _filter_capsule_software(graph, software_environments)
    contexts = _filter_capsule_contexts(graph, execution_contexts)
    entries = CapsuleContentEntry[]

    for id in plan.retention.retained_revisions
        reason = id == plan.source_revision ? :retention_root : :ancestor
        _push_content!(entries, :revision, :included;
            revision_id = id.value, label = id.value, reason = reason)
    end
    for id in plan.retention.omitted_revisions
        _push_content!(entries, :revision, :omitted;
            revision_id = id.value, label = id.value, reason = :unreachable)
    end
    for id in plan.retention.retained_runs
        _push_content!(entries, :provenance, :included;
            label = id.value, reason = :retained_run)
    end
    for id in plan.retention.omitted_runs
        _push_content!(entries, :provenance, :omitted;
            label = id.value, reason = :unreachable)
    end

    reachable = Dict{Tuple{String,String},ArchiveObject}()
    for object in ordered_objects(graph)
        reachable[(object.object_id.value, object.revision_id.value)] = object
    end
    for payload in supplied
        haskey(reachable, (payload.object_id.value, payload.revision_id.value)) ||
            throw(ArgumentError(
                "capsule payload $(payload.object_id.value) @ $(payload.revision_id.value) is not in the retained closure",
            ))
    end
    for redaction in drops
        matched = any(object -> begin
            object.object_id == redaction.object_id &&
                (redaction.revision_id === nothing || object.revision_id == redaction.revision_id)
        end, values(reachable))
        matched || throw(ArgumentError(
            "capsule redaction $(redaction.object_id.value) does not match a retained object",
        ))
    end

    portable = CapsulePayload[]
    native = CapsulePayload[]
    for item in plan.retention.classifications
        object_id = item.object_id.value
        revision_id = _capsule_id_text(item.revision_id)
        content_id = _capsule_id_text(item.content_id)
        if item.class === :reachable
            _push_content!(entries, :object, :included;
                object_id = object_id, revision_id = revision_id, content_id = content_id,
                reason = :reachability)
            object = reachable[(object_id, revision_id)]
            _bind_reachable_payload!(entries, portable, native, object, supplied, drops, native_policy)
        elseif item.class === :external
            _push_content!(entries, :external, :external;
                object_id = object_id, content_id = content_id, reason = :external_reference)
        elseif item.class === :unreachable
            _push_content!(entries, :object, :omitted;
                object_id = object_id, revision_id = revision_id, content_id = content_id,
                reason = :unreachable)
        elseif item.class === :purgeable_debug
            _push_content!(entries, :debug, :omitted;
                object_id = object_id, reason = :unpinned_debug)
        elseif item.class in (:purgeable_visualization, :replaceable)
            _push_content!(entries, :object, :omitted;
                object_id = object_id, revision_id = revision_id, content_id = content_id,
                reason = item.class)
        end
    end

    for definition in schemas.entries
        label = string(definition.schema.namespace_id, "/", definition.schema.schema_id,
            "@", definition.schema.version)
        _push_content!(entries, :schema, :included;
            label = label, content_id = canonical_content_id(definition).value,
            reason = :retained_schema)
    end
    for (index, stream) in enumerate(graph.log_streams)
        _push_content!(entries, :log, :unavailable;
            object_id = "log-stream-$(index)-$(stream.run_id.value)",
            label = String(stream.kind),
            content_id = _capsule_id_text(stream.content_id),
            reason = :log_bytes_not_packaged)
    end
    _capsule_software_rows!(entries, graph, software)
    _capsule_context_rows!(entries, graph, contexts)
    _capsule_document_rows!(entries, docs)
    _push_content!(entries, :runtime, :omitted;
        label = "os-runtime-container", reason = :runtime_not_packaged)

    sort!(entries; by = entry -> (
        String(entry.kind), String(entry.status), entry.object_id, entry.revision_id,
        entry.label, String(entry.reason), entry.encoding,
    ))
    sort!(portable; by = payload -> (payload.object_id.value, payload.revision_id.value))
    sort!(native; by = payload -> (payload.object_id.value, payload.revision_id.value))
    readiness = _capsule_achieved_readiness(
        graph, plan.source_revision, entries;
        externals = plan.externals, software = software,
    )
    embedded = any(entry -> entry.kind === :payload && entry.status === :included, entries)
    return CapsuleBoundContent(
        entries, portable, native, docs, readiness, software, contexts, embedded,
    )
end

function _capsule_block(diagnostic::DiagnosticMessage, blocks::String)
    return DiagnosticMessage(
        diagnostic.severity, diagnostic.code, diagnostic.message,
        merge(diagnostic.context, (; blocks = blocks)),
    )
end

function _append_blocking!(dest, diagnostics, blocks::String)
    for diagnostic in diagnostics
        diagnostic.severity === :error || continue
        _push_capsule_diagnostic!(dest, _capsule_block(diagnostic, blocks))
    end
    return dest
end

_capsule_has_error(diagnostics) = any(diagnostic -> diagnostic.severity === :error, diagnostics)

function _capsule_payload_entry(entries, object_id::AbstractString, revision_id::AbstractString)
    for entry in entries
        entry.kind === :payload || continue
        entry.object_id == object_id || continue
        entry.revision_id == revision_id || continue
        return entry
    end
    return nothing
end

function _capsule_payload_gap(entry::Union{Nothing,CapsuleContentEntry}, native_verified::Bool)
    entry === nothing && return :payload_not_supplied
    if entry.status !== :included
        return entry.reason
    end
    entry.encoding == "portable" && return nothing
    entry.encoding == "native" && return native_verified ? nothing : :native_replay_requires_verification
    return :payload_not_supplied
end

function _capsule_payload_gaps!(replay_extra, restart_extra, manifest, entries, native_verified)
    for entry in manifest.entries
        entry.availability === :envelope_only || continue
        revision_id = entry.revision_id === nothing ? "" : entry.revision_id.value
        payload = _capsule_payload_entry(entries, entry.object_id.value, revision_id)
        reason = _capsule_payload_gap(payload, native_verified)
        reason === nothing && continue
        push!(replay_extra, error_diagnostic(
            reason,
            "scientific state for $(entry.object_id.value) @ $revision_id is not available as trusted capsule content";
            object_id = entry.object_id.value,
            revision_id = revision_id,
            reason = reason,
        ))
    end
    run = manifest.run
    run === nothing && return nothing
    run.restart === nothing && return nothing
    for checkpoint in run.restart.checkpoints
        revision_id = checkpoint.revision_id === nothing ? "" : checkpoint.revision_id.value
        payload = _capsule_payload_entry(entries, checkpoint.object_id.value, revision_id)
        if payload === nothing && checkpoint.revision_id === nothing
            for entry in entries
                entry.kind === :payload || continue
                entry.object_id == checkpoint.object_id.value || continue
                payload = entry
                break
            end
        end
        reason = _capsule_payload_gap(payload, native_verified)
        reason === nothing && continue
        push!(restart_extra, error_diagnostic(
            :restart_payload_unavailable,
            "restart checkpoint $(checkpoint.object_id.value) has no trusted payload in the capsule";
            object_id = checkpoint.object_id.value,
            revision_id = revision_id,
            reason = reason,
        ))
    end
    return nothing
end

function _software_dependencies_absent(environment::SoftwareEnvironment)
    environment.julia_version === nothing && return true
    isempty(environment.components) && return true
    for component in environment.components
        component.version === nothing && return true
        component.source_identity === nothing && return true
        component.dependencies === nothing && return true
        component.dirty === nothing && return true
    end
    return false
end

function _capsule_software_gaps!(replay_extra, rerun_extra, manifest, entries, software)
    run = manifest.run
    run === nothing && return nothing
    run.software_environment === nothing && return nothing
    id = run.software_environment.value
    recorded = any(entry -> entry.kind === :software_environment && entry.status === :included &&
        entry.label == id, entries)
    if !recorded || software === nothing ||
            find_software_environment(software, run.software_environment) === nothing
        push!(replay_extra, error_diagnostic(
            :software_environment_record_missing,
            "run $(run.id.value) names software environment $id but the capsule does not include that record";
            run_id = run.id.value,
            software_environment = id,
        ))
        return nothing
    end
    environment = find_software_environment(software, run.software_environment)
    if _software_dependencies_absent(environment)
        push!(rerun_extra, error_diagnostic(
            :rerun_dependencies_absent,
            "software environment $id does not record the dependency versions required to rerun";
            software_environment = id,
        ))
    end
    if any(component -> component.dirty === true, environment.components)
        push!(rerun_extra, error_diagnostic(
            :modified_software_source,
            "software environment $id contains modified source and cannot support a rerun claim";
            software_environment = id,
        ))
    end
    return nothing
end

function _capsule_specification_gap!(rerun_extra, entries)
    any(entry -> entry.kind === :document && entry.status === :included, entries) && return nothing
    push!(rerun_extra, error_diagnostic(
        :portable_specification_missing,
        "capsule has no portable declarative specification to rerun from",
    ))
    return nothing
end

function _capsule_runtime_gap!(replay_extra, entries)
    any(entry -> entry.kind === :runtime && entry.status === :included, entries) || return nothing
    push!(replay_extra, error_diagnostic(
        :runtime_packaged,
        "capsule packaged an OS, runtime, or container image",
    ))
    return nothing
end

function _capsule_achieved_readiness(
    graph::ArchiveGraph,
    revision_id::RevisionId,
    entries::Vector{CapsuleContentEntry};
    externals = ExternalRequirement[],
    software = nothing,
    native_verified::Bool = false,
)
    manifest = inspect(graph, revision_id; externals = externals)
    inspect_report = readiness(manifest, PipelineTarget(:inspect))
    replay_base = readiness(manifest, PipelineTarget(:replay))
    restart_base = readiness(manifest, PipelineTarget(:restart))
    rerun_base = readiness(manifest, PipelineTarget(:rerun))
    replay_extra = DiagnosticMessage[]
    restart_extra = DiagnosticMessage[]
    rerun_extra = DiagnosticMessage[]
    _capsule_payload_gaps!(replay_extra, restart_extra, manifest, entries, native_verified)
    _capsule_software_gaps!(replay_extra, rerun_extra, manifest, entries, software)
    _capsule_specification_gap!(rerun_extra, entries)
    _capsule_runtime_gap!(replay_extra, entries)

    inspectable = isready(inspect_report)
    replayable = inspectable && isready(replay_base) && !_capsule_has_error(replay_extra)
    restartable = inspectable && isready(restart_base) && !_capsule_has_error(restart_extra)
    rerunnable = replayable && isready(rerun_base) && !_capsule_has_error(rerun_extra)
    diagnostics = DiagnosticMessage[]
    inspectable || _append_blocking!(diagnostics, inspect_report.diagnostics, "inspect,replay,restart,rerun")
    isready(replay_base) || _append_blocking!(diagnostics, replay_base.diagnostics, "replay,rerun")
    _append_blocking!(diagnostics, replay_extra, "replay,rerun")
    isready(restart_base) || _append_blocking!(diagnostics, restart_base.diagnostics, "restart")
    _append_blocking!(diagnostics, restart_extra, "restart")
    isready(rerun_base) || _append_blocking!(diagnostics, rerun_base.diagnostics, "rerun")
    _append_blocking!(diagnostics, rerun_extra, "rerun")
    return CapsuleReadiness(inspectable, replayable, restartable, rerunnable, diagnostics)
end

function _capsule_blocks(diagnostic::DiagnosticMessage, target::Symbol)
    blocks = get(diagnostic.context, :blocks, "")
    return occursin("," * string(target) * ",", "," * blocks * ",")
end

function _capsule_target_diagnostics(readiness::CapsuleReadiness, target::Symbol)
    return DiagnosticMessage[
        diagnostic for diagnostic in readiness.diagnostics if _capsule_blocks(diagnostic, target)
    ]
end

function _capsule_level_ready(readiness::CapsuleReadiness, target::Symbol)
    target === :inspect && return readiness.inspectable
    target === :replay && return readiness.replayable
    target === :restart && return readiness.restartable
    target === :rerun && return readiness.rerunnable
    return false
end

function readiness(view::ArchiveCapsuleInspection, target::PipelineTarget)
    _capsule_target(target.name)
    if !isvalid(view)
        return ReadinessReport(
            :capsule, target, false, copy(view.diagnostics),
            (; path = view.path, valid = false),
        )
    end
    ready = _capsule_level_ready(view.achieved, target.name)
    return ReadinessReport(
        :capsule, target, ready, _capsule_target_diagnostics(view.achieved, target.name),
        (;
            path = view.path,
            inspectable = view.achieved.inspectable,
            replayable = view.achieved.replayable,
            restartable = view.achieved.restartable,
            rerunnable = view.achieved.rerunnable,
            runtime_packaged = false,
        ),
    )
end

function readiness(report::CapsuleVerification, target::PipelineTarget)
    _capsule_target(target.name)
    ready = report.valid && _capsule_level_ready(report.readiness, target.name)
    diagnostics = DiagnosticMessage[]
    _append_capsule_diagnostics!(diagnostics, report.diagnostics)
    _append_capsule_diagnostics!(diagnostics, _capsule_target_diagnostics(report.readiness, target.name))
    return ReadinessReport(
        :capsule_verification, target, ready, diagnostics,
        (; path = report.path, valid = report.valid),
    )
end

function _capsule_integrity_object(manifest::RevisionIntegrityManifest, object_id, revision_id)
    for row in manifest.dependencies
        row.kind === :object || continue
        row.object_id === nothing && continue
        row.object_id.value == object_id || continue
        row.revision_id === nothing && continue
        row.revision_id.value == revision_id || continue
        return row
    end
    return nothing
end

function _verify_portable_capsule_payloads(payloads, entries, integrity::RevisionIntegrityManifest)
    seen = Set{Tuple{String,String}}()
    for payload in payloads
        key = (payload.object_id.value, payload.revision_id.value)
        key in seen && throw(ArgumentError("duplicate portable capsule payload $(key[1]) @ $(key[2])"))
        push!(seen, key)
        identity = canonical_content_id(payload.value)
        entry = _capsule_payload_entry(entries, key[1], key[2])
        entry !== nothing && entry.status === :included && entry.encoding == "portable" ||
            throw(ArgumentError("portable capsule payload $(key[1]) @ $(key[2]) is not an included row"))
        entry.content_id == identity.value || throw(ArgumentError(
            "portable capsule payload $(key[1]) @ $(key[2]) failed content-identity verification",
        ))
        row = _capsule_integrity_object(integrity, key[1], key[2])
        row !== nothing && row.content_id == identity || throw(ArgumentError(
            "portable capsule payload $(key[1]) @ $(key[2]) is outside the integrity manifest",
        ))
    end
    for entry in entries
        entry.kind === :payload && entry.status === :included && entry.encoding == "portable" || continue
        (entry.object_id, entry.revision_id) in seen || throw(ArgumentError(
            "included portable payload $(entry.object_id) @ $(entry.revision_id) is missing",
        ))
    end
    return payloads
end

function _verify_capsule_dispositions(graph, manifest::CapsuleManifest, documents, native_verified_keys)
    included_objects = Set{Tuple{String,String}}()
    for object in graph.objects
        key = (object.object_id.value, object.revision_id.value)
        entry = nothing
        for candidate in manifest.content
            candidate.kind === :object && candidate.status === :included || continue
            candidate.object_id == key[1] || continue
            candidate.revision_id == key[2] || continue
            entry = candidate
            break
        end
        entry === nothing && throw(ArgumentError(
            "retained object $(key[1]) @ $(key[2]) is missing from the capsule manifest",
        ))
        push!(included_objects, key)
    end
    for entry in manifest.content
        if entry.kind === :object && entry.status === :included
            (entry.object_id, entry.revision_id) in included_objects || throw(ArgumentError(
                "capsule lists object $(entry.object_id) @ $(entry.revision_id) that is not retained",
            ))
        elseif entry.kind === :object && entry.status === :omitted && !isempty(entry.revision_id)
            find_object(graph, ObjectId(entry.object_id), RevisionId(entry.revision_id)) === nothing ||
                throw(ArgumentError(
                    "omitted object $(entry.object_id) @ $(entry.revision_id) is still in the capsule",
                ))
        elseif entry.kind === :payload && entry.status === :included && entry.encoding == "native"
            (entry.object_id, entry.revision_id, entry.content_id) in native_verified_keys ||
                throw(ArgumentError(
                    "native capsule payload $(entry.object_id) @ $(entry.revision_id) failed byte verification",
                ))
        elseif entry.kind === :document && entry.status === :included
            any(document -> document.id.value == entry.label, documents) || throw(ArgumentError(
                "included document $(entry.label) is missing from the capsule",
            ))
        end
    end
    for document in documents
        isvalid(validate(document)) || throw(ArgumentError(
            "capsule document $(document.id.value) failed portable validation",
        ))
    end
    _capsule_runtime_row(manifest.content) === nothing && throw(ArgumentError(
        "capsule is missing its runtime exclusion record",
    ))
    return nothing
end

function _capsule_payload_storage(payload::CapsulePayload)
    return (
        object_id = payload.object_id.value,
        revision_id = payload.revision_id.value,
        content_id = canonical_content_id(payload.value).value,
        value = _event_payload_jld2_storage(_portable_value_namedtuple(payload.value)),
    )
end

function _restore_capsule_payload(nt)
    value = _value_from_namedtuple(nt.value)
    return CapsulePayload(
        ObjectId(String(nt.object_id)),
        RevisionId(String(nt.revision_id)),
        value,
    )
end

function _capsule_document_storage(document::PortableSemanticDocument)
    return _event_payload_jld2_storage(to_namedtuple(document))
end

function _symbolize_capsule_node(nt)
    nt isa NamedTuple || throw(ArgumentError("portable node must be a NamedTuple"))
    attributes = Any[]
    raw_attributes = haskey(nt, :attributes) ? nt.attributes : ()
    for item in raw_attributes
        push!(attributes, (
            name = Symbol(item.name),
            value = item.value,
        ))
    end
    raw_children = haskey(nt, :children) ? nt.children : ()
    children = Any[_symbolize_capsule_node(child) for child in raw_children]
    raw_name = haskey(nt, :name) ? nt.name : nothing
    name = raw_name === nothing ? nothing : String(raw_name)
    return (
        kind = String(nt.kind),
        name = name,
        attributes = attributes,
        children = children,
    )
end

function _restore_capsule_document(nt)
    schema = nt.schema
    fragments = (_symbolize_capsule_node(fragment) for fragment in nt.fragments)
    restored = merge(nt, (
        id = String(nt.id),
        schema = merge(schema, (namespace_id = Symbol(schema.namespace_id),)),
        fragments = collect(fragments),
    ))
    return from_namedtuple(PortableSemanticDocument, restored)
end

function _capsule_native_storage(payload::CapsulePayload, bytes::Vector{UInt8})
    return (
        object_id = payload.object_id.value,
        revision_id = payload.revision_id.value,
        content_id = canonical_content_id(payload.value).value,
        byte_sha256 = "sha256:" * bytes2hex(SHA.sha256(bytes)),
        bytes = bytes,
    )
end

function _refuse_capsule_native_record(nt)
    bytes = Vector{UInt8}(nt.bytes)
    expected = "sha256:" * bytes2hex(SHA.sha256(bytes))
    expected == String(nt.byte_sha256) || throw(ArgumentError(
        "capsule native payload byte hash mismatch",
    ))
    return (
        object_id = String(nt.object_id),
        revision_id = String(nt.revision_id),
        content_id = String(nt.content_id),
        byte_sha256 = expected,
        bytes = bytes,
    )
end

function _capsule_needs_native(entries)
    return any(entry -> entry.kind === :payload && entry.status === :included &&
        entry.encoding == "native", entries)
end

function _empty_capsule_readiness(diagnostics = DiagnosticMessage[])
    return CapsuleReadiness(false, false, false, false, diagnostics)
end
