# ---------------------------------------------------------------------------
# Domain-neutral reproduction comparison vocabulary (#107)
# ---------------------------------------------------------------------------

const REPRODUCTION_KINDS = (:exact_content, :numeric, :summary)

"""
    ReproductionComparison

Outcome of comparing a replayed result to an archived accepted result.
Episteme records the kind and identity; domain packages own numeric
equivalence via [`compare_reproduction`](@ref).
"""
struct ReproductionComparison <: AbstractValidationReport
    kind::Symbol
    agreed::Bool
    left::Union{Nothing,ContentId}
    right::Union{Nothing,ContentId}
    diagnostics::Vector{DiagnosticMessage}
    metadata::NamedTuple
end

Base.isvalid(report::ReproductionComparison) = report.agreed

function ReproductionComparison(
    kind::Symbol;
    agreed::Bool,
    left = nothing,
    right = nothing,
    diagnostics = DiagnosticMessage[],
    metadata = (;),
)
    kind in REPRODUCTION_KINDS || throw(ArgumentError(
        "reproduction kind must be one of $REPRODUCTION_KINDS, got :$kind",
    ))
    return ReproductionComparison(
        kind,
        agreed,
        _optional_id(ContentId, left),
        _optional_id(ContentId, right),
        _typed_vector(DiagnosticMessage, diagnostics, "diagnostics"),
        metadata,
    )
end

function report(comparison::ReproductionComparison)
    return ObjectReport(
        :reproduction_comparison,
        "Reproduction :$(comparison.kind) agreed=$(comparison.agreed).",
        (;
            kind = comparison.kind,
            agreed = comparison.agreed,
            left = comparison.left === nothing ? nothing : comparison.left.value,
            right = comparison.right === nothing ? nothing : comparison.right.value,
        ),
        comparison.diagnostics,
        ArtifactRef[],
    )
end

"""
    compare_reproduction(left, right; kind=:exact_content)

Compare two archived or replayed values. Domain packages extend
`compare_reproduction(::Val{kind}, left, right)`.
Exact content identity uses [`ContentId`](@ref) and does not claim
bitwise floating-point identity for HPC payloads.
"""
function compare_reproduction(left, right; kind::Symbol = :exact_content)
    kind in REPRODUCTION_KINDS || throw(ArgumentError(
        "reproduction kind must be one of $REPRODUCTION_KINDS, got :$kind",
    ))
    return compare_reproduction(Val(kind), left, right)
end

function compare_reproduction(::Val{:exact_content}, left::ContentId, right::ContentId)
    agreed = left == right
    diagnostics = DiagnosticMessage[]
    agreed || push!(diagnostics, error_diagnostic(
        :content_mismatch,
        "content $(left.value) does not match $(right.value)";
        left = left.value,
        right = right.value,
    ))
    return ReproductionComparison(
        :exact_content;
        agreed = agreed,
        left = left,
        right = right,
    )
end

function compare_reproduction(::Val{kind}, left, right) where {kind}
    return ReproductionComparison(
        kind === :numeric || kind === :summary ? kind : :exact_content;
        agreed = false,
        diagnostics = [error_diagnostic(
            :missing_comparison_method,
            "no compare_reproduction method for $(typeof(left)) vs $(typeof(right)) kind :$kind";
            kind = kind,
            left_type = string(typeof(left)),
            right_type = string(typeof(right)),
        )],
    )
end
