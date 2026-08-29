# ---------------------------------------------------------------------------
# Pure reproduction-capsule planning (#79 / parent #35)
# ---------------------------------------------------------------------------

const CAPSULE_TARGETS = (:inspect, :replay, :restart, :rerun)

"""
    CapsulePlan <: AbstractValidationReport

Pure, read-only plan for a minimal reproduction/debug capsule rooted at one
historical revision. `valid` describes whether the selected retention and
integrity closures are structurally trustworthy. `ready` is deliberately
separate: it describes whether the planned capsule satisfies the requested
pipeline target.

No file is written and the source `ArchiveGraph` is never mutated.
"""
struct CapsulePlan <: AbstractValidationReport
    source_revision::RevisionId
    target::Symbol
    verification::Symbol
    manifest::RevisionManifest
    integrity::RevisionIntegrityManifest
    retention::PurgePlan
    externals::Vector{ExternalRequirement}
    valid::Bool
    ready::Bool
    readiness_report::ReadinessReport
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(plan::CapsulePlan) = plan.valid
Base.isready(plan::CapsulePlan) = plan.ready

function _capsule_target(target::Symbol)
    target in CAPSULE_TARGETS || throw(ArgumentError(
        "capsule target must be one of $CAPSULE_TARGETS, got :$target",
    ))
    return target
end

function _push_capsule_diagnostic!(diagnostics, diagnostic::DiagnosticMessage)
    for existing in diagnostics
        existing.severity === diagnostic.severity || continue
        existing.code === diagnostic.code || continue
        existing.message == diagnostic.message || continue
        existing.context == diagnostic.context || continue
        return diagnostics
    end
    push!(diagnostics, diagnostic)
    return diagnostics
end

function _append_capsule_diagnostics!(diagnostics, values)
    for diagnostic in values
        _push_capsule_diagnostic!(diagnostics, diagnostic)
    end
    return diagnostics
end

function _capsule_strong_content_id(content_id)
    content_id isa ContentId || return false
    text = content_id.value
    startswith(text, "sha256:") || return false
    hex = text[8:end]
    ncodeunits(hex) == 64 || return false
    return all(c -> ('0' <= c <= '9') || ('a' <= c <= 'f'), hex)
end

function _capsule_external_key(req::ExternalRequirement)
    artifact = req.artifact
    return (
        req.object_id.value,
        req.content_id === nothing ? "" : req.content_id.value,
        String(artifact.kind),
        artifact.path === nothing ? "" : artifact.path,
        artifact.uri === nothing ? "" : artifact.uri,
        artifact.description,
    )
end

function _capsule_externals(manifest::RevisionManifest)
    values = ExternalRequirement[]
    seen = Set{Tuple{String,String,String,String,String,String}}()
    for entry in manifest.entries
        entry.availability === :external_required || continue
        entry.artifact === nothing && continue
        req = ExternalRequirement(
            entry.object_id;
            content_id = entry.content_id,
            artifact = entry.artifact,
        )
        key = _capsule_external_key(req)
        key in seen && continue
        push!(seen, key)
        push!(values, req)
    end
    sort!(values; by = _capsule_external_key)
    return values
end

function _integrity_object_keys(integrity::RevisionIntegrityManifest)
    return Set(
        (
            row.object_id.value,
            row.revision_id.value,
        )
        for row in integrity.dependencies
        if row.kind === :object && row.object_id !== nothing && row.revision_id !== nothing
    )
end

function _integrity_external_keys(integrity::RevisionIntegrityManifest)
    return Set(
        (
            row.object_id.value,
            row.content_id === nothing ? "" : row.content_id.value,
        )
        for row in integrity.dependencies
        if row.kind === :external && row.object_id !== nothing
    )
end

function _append_capsule_retention_integrity_diagnostics!(
    diagnostics,
    retention::PurgePlan,
    integrity::RevisionIntegrityManifest,
)
    object_keys = _integrity_object_keys(integrity)
    external_keys = _integrity_external_keys(integrity)
    for item in retention.classifications
        if item.class === :reachable
            if item.content_id === nothing
                _push_capsule_diagnostic!(diagnostics, error_diagnostic(
                    :capsule_retained_content_identity_missing,
                    "retained object $(item.object_id.value) has no ContentId";
                    object_id = item.object_id.value,
                    revision_id = item.revision_id === nothing ? nothing : item.revision_id.value,
                ))
                continue
            end
            if !_capsule_strong_content_id(item.content_id)
                _push_capsule_diagnostic!(diagnostics, error_diagnostic(
                    :capsule_retained_content_identity_weak,
                    "retained object $(item.object_id.value) lacks a canonical sha256 ContentId";
                    object_id = item.object_id.value,
                    revision_id = item.revision_id === nothing ? nothing : item.revision_id.value,
                    content_id = item.content_id.value,
                ))
            end
            key = (
                item.object_id.value,
                item.revision_id === nothing ? "" : item.revision_id.value,
            )
            key in object_keys || _push_capsule_diagnostic!(diagnostics, error_diagnostic(
                :capsule_retained_object_not_integrity_covered,
                "retained object $(item.object_id.value) is outside the selected revision integrity closure";
                object_id = item.object_id.value,
                revision_id = item.revision_id === nothing ? nothing : item.revision_id.value,
            ))
        elseif item.class === :external
            if item.content_id === nothing || !_capsule_strong_content_id(item.content_id)
                _push_capsule_diagnostic!(diagnostics, error_diagnostic(
                    :capsule_external_content_identity_missing,
                    "external dependency $(item.object_id.value) lacks a strong sha256 ContentId";
                    object_id = item.object_id.value,
                    content_id = item.content_id === nothing ? nothing : item.content_id.value,
                ))
                continue
            end
            key = (item.object_id.value, item.content_id.value)
            key in external_keys || _push_capsule_diagnostic!(diagnostics, error_diagnostic(
                :capsule_external_not_integrity_covered,
                "external dependency $(item.object_id.value) is outside the integrity report";
                object_id = item.object_id.value,
                content_id = item.content_id.value,
            ))
        end
    end
    return diagnostics
end

function _capsule_validation_diagnostics(
    manifest::RevisionManifest,
    integrity::RevisionIntegrityManifest,
    retention::PurgePlan,
)
    diagnostics = DiagnosticMessage[]
    _append_capsule_diagnostics!(diagnostics, validate(manifest).diagnostics)
    _append_capsule_diagnostics!(diagnostics, validate(integrity).diagnostics)
    _append_capsule_diagnostics!(diagnostics, validate(retention).diagnostics)
    _append_capsule_retention_integrity_diagnostics!(diagnostics, retention, integrity)
    return diagnostics
end

function _capsule_target_readiness(
    manifest::RevisionManifest,
    target::Symbol,
    structural_diagnostics,
)
    requested = PipelineTarget(target)
    base = readiness(manifest, requested)
    diagnostics = DiagnosticMessage[]
    _append_capsule_diagnostics!(diagnostics, structural_diagnostics)
    _append_capsule_diagnostics!(diagnostics, base.diagnostics)
    ready = !any(diagnostic -> diagnostic.severity === :error, diagnostics) && isready(base)
    return ReadinessReport(
        :capsule_plan,
        requested,
        ready,
        diagnostics,
        (;
            revision_id = manifest.revision.id.value,
            target = target,
        ),
    )
end

"""
    plan_capsule(graph, revision_id, schemas; target=:inspect, externals=(),
                 external_integrity=(), verification=:metadata,
                 policy=RetentionPolicy()) -> CapsulePlan

Plan a minimal verifiable capsule without writing files. Revision selection,
retention, integrity verification, and readiness each reuse their existing
contracts rather than introducing a parallel graph or verification model.
"""
function plan_capsule(
    graph::ArchiveGraph,
    revision_id::RevisionId,
    schemas::SchemaRegistry;
    target::Symbol = :inspect,
    externals = ExternalRequirement[],
    external_integrity = ExternalIntegrityRecord[],
    verification::Symbol = :metadata,
    policy::RetentionPolicy = RetentionPolicy(),
)
    requested_target = _capsule_target(target)
    _verification_level(verification)
    reqs = _externals_vector(externals)
    records = _external_integrity_records(external_integrity)

    manifest = inspect(graph, revision_id; externals = reqs)
    retention = plan_purge(
        graph,
        [RetentionRoot(revision_id)];
        policy = policy,
        externals = reqs,
    )
    integrity = integrity_manifest(
        manifest,
        schemas;
        external_integrity = records,
        level = verification,
    )
    diagnostics = _capsule_validation_diagnostics(manifest, integrity, retention)
    valid = !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    ready_report = _capsule_target_readiness(manifest, requested_target, diagnostics)
    return CapsulePlan(
        revision_id,
        requested_target,
        verification,
        manifest,
        integrity,
        retention,
        _capsule_externals(manifest),
        valid,
        isready(ready_report),
        ready_report,
        diagnostics,
    )
end

function validate(plan::CapsulePlan)
    return ValidationReport(
        :capsule_plan,
        plan.valid,
        copy(plan.diagnostics),
        (;
            revision_id = plan.source_revision.value,
            target = plan.target,
            verification = plan.verification,
            retained_objects = plan.retention.retained_objects,
            omitted_objects = plan.retention.omitted_objects,
            external_objects = length(plan.externals),
            ready = plan.ready,
        ),
    )
end

function readiness(plan::CapsulePlan, target::PipelineTarget)
    _capsule_target(target.name)
    return _capsule_target_readiness(plan.manifest, target.name, plan.diagnostics)
end

function report(plan::CapsulePlan)
    return ObjectReport(
        :capsule_plan,
        "Capsule plan for revision $(plan.source_revision.value): valid=$(plan.valid), target=:$(plan.target), ready=$(plan.ready).",
        (;
            revision_id = plan.source_revision.value,
            target = plan.target,
            verification = plan.verification,
            retained_objects = plan.retention.retained_objects,
            omitted_objects = plan.retention.omitted_objects,
            retained_revisions = length(plan.retention.retained_revisions),
            retained_runs = length(plan.retention.retained_runs),
            external_objects = length(plan.externals),
            valid = plan.valid,
            ready = plan.ready,
        ),
        copy(plan.diagnostics),
        ArtifactRef[req.artifact for req in plan.externals],
    )
end

function _capsule_classification_namedtuple(item::PurgeClassification)
    return (
        object_id = item.object_id.value,
        revision_id = item.revision_id === nothing ? nothing : item.revision_id.value,
        content_id = item.content_id === nothing ? nothing : item.content_id.value,
        class = item.class,
    )
end

to_namedtuple(plan::CapsulePlan) = (
    source_revision = plan.source_revision.value,
    target = plan.target,
    verification = plan.verification,
    valid = plan.valid,
    ready = plan.ready,
    retained_objects = plan.retention.retained_objects,
    omitted_objects = plan.retention.omitted_objects,
    retained_revisions = Tuple(id.value for id in plan.retention.retained_revisions),
    omitted_revisions = Tuple(id.value for id in plan.retention.omitted_revisions),
    retained_runs = Tuple(id.value for id in plan.retention.retained_runs),
    omitted_runs = Tuple(id.value for id in plan.retention.omitted_runs),
    classifications = Tuple(
        _capsule_classification_namedtuple(item) for item in plan.retention.classifications
    ),
    externals = Tuple(to_namedtuple(req) for req in plan.externals),
    integrity = to_namedtuple(plan.integrity),
    readiness = to_namedtuple(plan.readiness_report),
    diagnostics = Tuple(to_namedtuple.(plan.diagnostics)),
)
