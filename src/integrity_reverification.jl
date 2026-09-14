# ---------------------------------------------------------------------------
# Live re-verification of expected integrity identities (#101 / parent #42)
#
# Persisted AH5 integrity records are evidence of a prior check. This layer
# compares that expected identity set with a freshly built live manifest and
# never treats inspect_archive as a current-byte verification.
# ---------------------------------------------------------------------------

const INTEGRITY_IDENTITY_OUTCOMES = (:preserved, :changed, :missing, :unexpected)

"""
    IntegrityIdentityDelta

One expected-versus-observed dependency identity. `:preserved` requires the
same non-empty `ContentId`. Live verification strength is reported separately
and is never copied from stored evidence.
"""
struct IntegrityIdentityDelta
    kind::Symbol
    outcome::Symbol
    object_id::Union{Nothing,ObjectId}
    revision_id::Union{Nothing,RevisionId}
    schema::Union{Nothing,SchemaRef}
    expected_content_id::Union{Nothing,ContentId}
    observed_content_id::Union{Nothing,ContentId}
    expected_verified_level::Symbol
    observed_verified_level::Symbol
    diagnostics::Vector{DiagnosticMessage}
end

"""
    IntegrityVerificationReport <: AbstractValidationReport

Live comparison of one expected revision integrity manifest against a freshly
computed observed manifest. `requested_level` is the live check; stored
evidence may have claimed a different `expected_level`.
"""
struct IntegrityVerificationReport <: AbstractValidationReport
    revision_id::RevisionId
    requested_level::Symbol
    expected_level::Symbol
    valid::Bool
    identities_preserved::Bool
    expected::RevisionIntegrityManifest
    observed::RevisionIntegrityManifest
    deltas::Vector{IntegrityIdentityDelta}
    diagnostics::Vector{DiagnosticMessage}
end

"""
    ArchiveIntegrityVerification <: AbstractValidationReport

Live re-verification of every persisted revision integrity manifest in one
AH5 archive against the current graph and external artifacts.
"""
struct ArchiveIntegrityVerification <: AbstractValidationReport
    path::String
    valid::Bool
    reports::Vector{IntegrityVerificationReport}
    diagnostics::Vector{DiagnosticMessage}
end

Base.isvalid(report::IntegrityVerificationReport) = report.valid
Base.isvalid(report::ArchiveIntegrityVerification) = report.valid

function _integrity_identity_key(row::IntegrityDependencyRow)
    if row.kind === :schema
        return (row.kind, "", "", _schema_row_key(row)...)
    end
    object_id, revision_id = _row_revision_key(row)
    return (row.kind, object_id, revision_id, "", "", "")
end

function _integrity_identity_sort_key(delta::IntegrityIdentityDelta)
    rank = delta.kind === :object ? 1 : delta.kind === :schema ? 2 : 3
    schema_key = delta.schema === nothing ? ("", "", "") : _integrity_schema_key(delta.schema)
    return (
        rank,
        delta.object_id === nothing ? "" : delta.object_id.value,
        delta.revision_id === nothing ? "" : delta.revision_id.value,
        schema_key...,
        String(delta.outcome),
    )
end

function _content_identity_preserved(expected, observed)
    return expected !== nothing && expected == observed
end

function _identity_delta(expected_row, observed_row, outcome, diagnostics)
    row = expected_row === nothing ? observed_row : expected_row
    return IntegrityIdentityDelta(
        row.kind,
        outcome,
        row.object_id,
        row.revision_id,
        row.schema,
        expected_row === nothing ? nothing : expected_row.content_id,
        observed_row === nothing ? nothing : observed_row.content_id,
        expected_row === nothing ? :none : expected_row.verified_level,
        observed_row === nothing ? :none : observed_row.verified_level,
        diagnostics,
    )
end

function _map_integrity_rows(manifest::RevisionIntegrityManifest)
    mapping = Dict{Any,IntegrityDependencyRow}()
    for row in manifest.dependencies
        key = _integrity_identity_key(row)
        haskey(mapping, key) && throw(ArgumentError(
            "duplicate integrity dependency $(repr(key)) in revision $(manifest.revision_id.value)",
        ))
        mapping[key] = row
    end
    return mapping
end

"""
    verify_integrity(expected, observed) -> IntegrityVerificationReport

Compare two revision integrity manifests for the same revision. `observed`
must be a live `integrity_manifest` result; stored AH5 evidence belongs in
`expected`.
"""
function verify_integrity(
    expected::RevisionIntegrityManifest,
    observed::RevisionIntegrityManifest,
)
    diagnostics = DiagnosticMessage[]
    if expected.revision_id != observed.revision_id
        push!(diagnostics, error_diagnostic(
            :revision_identity_mismatch,
            "expected integrity revision $(expected.revision_id.value) does not match live revision $(observed.revision_id.value)";
            expected_revision_id = expected.revision_id.value,
            observed_revision_id = observed.revision_id.value,
        ))
        return IntegrityVerificationReport(
            expected.revision_id,
            observed.requested_level,
            expected.requested_level,
            false,
            false,
            expected,
            observed,
            IntegrityIdentityDelta[],
            diagnostics,
        )
    end

    expected_rows = _map_integrity_rows(expected)
    observed_rows = _map_integrity_rows(observed)
    deltas = IntegrityIdentityDelta[]
    for key in sort!(collect(union(keys(expected_rows), keys(observed_rows))))
        expected_row = get(expected_rows, key, nothing)
        observed_row = get(observed_rows, key, nothing)
        local_diags = DiagnosticMessage[]
        if expected_row === nothing
            push!(local_diags, error_diagnostic(
                :unexpected_integrity_dependency,
                "live integrity report contains an unexpected :$(observed_row.kind) dependency";
                kind = observed_row.kind,
            ))
            push!(deltas, _identity_delta(nothing, observed_row, :unexpected, local_diags))
        elseif observed_row === nothing
            push!(local_diags, error_diagnostic(
                :content_identity_missing,
                "live integrity report is missing expected :$(expected_row.kind) dependency";
                kind = expected_row.kind,
            ))
            push!(deltas, _identity_delta(expected_row, nothing, :missing, local_diags))
        elseif !_content_identity_preserved(expected_row.content_id, observed_row.content_id)
            push!(local_diags, error_diagnostic(
                :content_identity_changed,
                "logical content identity changed for :$(expected_row.kind) dependency and must be recomputed";
                kind = expected_row.kind,
                expected_content_id = expected_row.content_id === nothing ? nothing :
                    expected_row.content_id.value,
                observed_content_id = observed_row.content_id === nothing ? nothing :
                    observed_row.content_id.value,
            ))
            push!(deltas, _identity_delta(expected_row, observed_row, :changed, local_diags))
        else
            push!(deltas, _identity_delta(expected_row, observed_row, :preserved, local_diags))
        end
        append!(diagnostics, local_diags)
    end
    sort!(deltas; by = _integrity_identity_sort_key)

    identities_preserved = all(delta -> delta.outcome === :preserved, deltas)
    append!(diagnostics, observed.diagnostics)
    valid = identities_preserved && isvalid(observed) &&
        !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return IntegrityVerificationReport(
        expected.revision_id,
        observed.requested_level,
        expected.requested_level,
        valid,
        identities_preserved,
        expected,
        observed,
        deltas,
        diagnostics,
    )
end

"""
    verify_integrity(expected, graph, schemas; kwargs...)

Rebuild a live integrity manifest for `expected.revision_id` and compare it
with the expected identities. The live `level` defaults to the expected
requested verification level.
"""
function verify_integrity(
    expected::RevisionIntegrityManifest,
    graph::ArchiveGraph,
    schemas::SchemaRegistry;
    externals = ExternalRequirement[],
    external_integrity = ExternalIntegrityRecord[],
    level::Symbol = expected.requested_level,
)
    observed = integrity_manifest(
        graph,
        expected.revision_id,
        schemas;
        externals = externals,
        external_integrity = external_integrity,
        level = level,
    )
    return verify_integrity(expected, observed)
end

function _empty_archive_integrity_verification(path, diagnostics)
    valid = !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveIntegrityVerification(
        String(path),
        valid,
        IntegrityVerificationReport[],
        diagnostics,
    )
end

"""
    verify_integrity(view, graph, schemas; kwargs...)

Re-verify persisted AH5 integrity manifests against the current archive graph.
`inspect_archive` evidence is used only as the expected identity set.
"""
function verify_integrity(
    view::ArchiveIntegrityInspection,
    graph::ArchiveGraph,
    schemas::SchemaRegistry;
    kwargs...,
)
    diagnostics = copy(view.diagnostics)
    if !view.identified
        push!(diagnostics, error_diagnostic(
            :archive_unidentified,
            "AH5 archive was not identified; persisted integrity evidence cannot be re-verified";
            path = view.path,
        ))
        return _empty_archive_integrity_verification(view.path, diagnostics)
    end
    if !view.feature_declared || isempty(view.manifests)
        push!(diagnostics, error_diagnostic(
            :integrity_evidence_missing,
            "AH5 archive has no persisted revision integrity manifests to re-verify";
            path = view.path,
        ))
        return _empty_archive_integrity_verification(view.path, diagnostics)
    end
    if !isvalid(view)
        return _empty_archive_integrity_verification(view.path, diagnostics)
    end

    reports = IntegrityVerificationReport[
        verify_integrity(manifest, graph, schemas; kwargs...) for manifest in view.manifests
    ]
    for report in reports
        append!(diagnostics, report.diagnostics)
    end
    valid = all(isvalid, reports) &&
        !any(diagnostic -> diagnostic.severity === :error, diagnostics)
    return ArchiveIntegrityVerification(view.path, valid, reports, diagnostics)
end

"""
    verify_integrity(path, graph, schemas; kwargs...)

Load persisted integrity evidence from `path` and re-verify it against the
current graph. Opening the file is not itself a live verification.
"""
function verify_integrity(
    path::AbstractString,
    graph::ArchiveGraph,
    schemas::SchemaRegistry;
    kwargs...,
)
    view = inspect_archive(path, RevisionIntegrityManifest)
    return verify_integrity(view, graph, schemas; kwargs...)
end

function validate(report::IntegrityVerificationReport)
    return ValidationReport(
        :integrity_verification,
        report.valid,
        report.diagnostics,
        (;
            revision_id = report.revision_id.value,
            requested_level = report.requested_level,
            expected_level = report.expected_level,
            identities_preserved = report.identities_preserved,
            dependencies = length(report.deltas),
        ),
    )
end

function validate(report::ArchiveIntegrityVerification)
    return ValidationReport(
        :archive_integrity_verification,
        report.valid,
        report.diagnostics,
        (; path = report.path, revisions = length(report.reports)),
    )
end

function report(result::IntegrityVerificationReport)
    preserved = count(delta -> delta.outcome === :preserved, result.deltas)
    return ObjectReport(
        :integrity_verification,
        "Revision $(result.revision_id.value) live integrity $(result.valid ? "passed" : "failed"); $preserved/$(length(result.deltas)) identities preserved.",
        to_namedtuple(result),
        result.diagnostics,
        ArtifactRef[],
    )
end

function report(result::ArchiveIntegrityVerification)
    return ObjectReport(
        :archive_integrity_verification,
        "AH5 live integrity $(result.valid ? "passed" : "failed") for $(length(result.reports)) persisted revision manifest(s).",
        to_namedtuple(result),
        result.diagnostics,
        ArtifactRef[],
    )
end

to_namedtuple(delta::IntegrityIdentityDelta) = (
    kind = delta.kind,
    outcome = delta.outcome,
    object_id = delta.object_id === nothing ? nothing : delta.object_id.value,
    revision_id = delta.revision_id === nothing ? nothing : delta.revision_id.value,
    schema = delta.schema === nothing ? nothing : to_namedtuple(delta.schema),
    expected_content_id = delta.expected_content_id === nothing ? nothing :
        delta.expected_content_id.value,
    observed_content_id = delta.observed_content_id === nothing ? nothing :
        delta.observed_content_id.value,
    expected_verified_level = delta.expected_verified_level,
    observed_verified_level = delta.observed_verified_level,
    diagnostics = Tuple(to_namedtuple.(delta.diagnostics)),
)

to_namedtuple(report::IntegrityVerificationReport) = (
    revision_id = report.revision_id.value,
    requested_level = report.requested_level,
    expected_level = report.expected_level,
    valid = report.valid,
    identities_preserved = report.identities_preserved,
    deltas = Tuple(to_namedtuple.(report.deltas)),
    diagnostics = Tuple(to_namedtuple.(report.diagnostics)),
)

to_namedtuple(report::ArchiveIntegrityVerification) = (
    path = report.path,
    valid = report.valid,
    reports = Tuple(to_namedtuple.(report.reports)),
    diagnostics = Tuple(to_namedtuple.(report.diagnostics)),
)
