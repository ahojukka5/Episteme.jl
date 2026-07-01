module OodiCore

export report, validate, readiness
export AbstractOodiReport, AbstractValidationReport, AbstractReadinessReport
export AbstractDiagnostic, AbstractPipelineTarget
export DiagnosticMessage, ValidationReport, ReadinessReport, ObjectReport
export PipelineTarget, ArtifactRef
export info, warning, error_diagnostic
export isready, to_namedtuple

# ---------------------------------------------------------------------------
# Shared generic functions
#
# These are declared here, and only here, so that CAD, mesh, and numerical
# packages in the Oodi ecosystem can all extend the same generic functions
# instead of defining their own locally-scoped `report`/`validate`/`readiness`
# functions that would silently shadow one another.
#
# Downstream packages should write:
#
#     import OodiCore: report, validate, readiness
#     report(x::MyType) = ...
#
# and never `function report(...) end` on their own.
# ---------------------------------------------------------------------------

"""
    report(x)

Return a structured, human- and machine-readable report describing `x`.

This is a generic function with no default implementation. Packages that
define types meant to be inspected by users or LLM agents should add a
method for their own type, typically returning an [`ObjectReport`](@ref) or
a domain-specific subtype of [`AbstractOodiReport`](@ref).

Read-only: implementations must not mutate `x`.
"""
function report end

"""
    validate(x)

Check whether `x` is internally consistent and return an
[`AbstractValidationReport`](@ref) (typically a [`ValidationReport`](@ref)).

This is a generic function with no default implementation. Packages own the
definition of what "valid" means for their own types.

Read-only: implementations must not mutate `x`.
"""
function validate end

"""
    readiness(x, target)

Check whether `x` is ready to move to the next pipeline stage described by
`target` (an [`AbstractPipelineTarget`](@ref), typically a
[`PipelineTarget`](@ref)), and return an
[`AbstractReadinessReport`](@ref) (typically a [`ReadinessReport`](@ref)).

This is a generic function with no default implementation.

Read-only: implementations must not mutate `x`.
"""
function readiness end

# ---------------------------------------------------------------------------
# Abstract types
# ---------------------------------------------------------------------------

"""
    AbstractOodiReport

Supertype for all report types returned by [`report`](@ref), [`validate`](@ref),
and [`readiness`](@ref) across the Oodi ecosystem.
"""
abstract type AbstractOodiReport end

"""
    AbstractValidationReport <: AbstractOodiReport

Supertype for reports returned by [`validate`](@ref).
"""
abstract type AbstractValidationReport <: AbstractOodiReport end

"""
    AbstractReadinessReport <: AbstractOodiReport

Supertype for reports returned by [`readiness`](@ref).
"""
abstract type AbstractReadinessReport <: AbstractOodiReport end

"""
    AbstractDiagnostic

Supertype for small structured diagnostic messages attached to reports.
"""
abstract type AbstractDiagnostic end

"""
    AbstractPipelineTarget

Supertype for pipeline target descriptors passed to [`readiness`](@ref).
"""
abstract type AbstractPipelineTarget end

# ---------------------------------------------------------------------------
# DiagnosticMessage
# ---------------------------------------------------------------------------

"""
    DiagnosticMessage <: AbstractDiagnostic

A single structured diagnostic message.

# Fields
- `severity::Symbol`: one of `:info`, `:warning`, `:error`.
- `code::Symbol`: a machine-readable code, e.g. `:missing_boundary_tag`.
- `message::String`: a human-readable explanation.
- `context::NamedTuple`: small structured metadata relevant to the message.

Use the [`info`](@ref), [`warning`](@ref), and [`error_diagnostic`](@ref)
convenience constructors instead of calling this constructor directly.
"""
struct DiagnosticMessage <: AbstractDiagnostic
    severity::Symbol
    code::Symbol
    message::String
    context::NamedTuple
end

const _VALID_SEVERITIES = (:info, :warning, :error)

function _diagnostic(severity::Symbol, code::Symbol, message::AbstractString; kwargs...)
    severity in _VALID_SEVERITIES ||
        Base.error("Invalid diagnostic severity :$severity (expected one of $_VALID_SEVERITIES)")
    return DiagnosticMessage(severity, code, String(message), (; kwargs...))
end

"""
    info(code::Symbol, message::AbstractString; kwargs...)

Construct a [`DiagnosticMessage`](@ref) with severity `:info`.
Keyword arguments are collected into the diagnostic's `context`.
"""
info(code::Symbol, message::AbstractString; kwargs...) = _diagnostic(:info, code, message; kwargs...)

"""
    warning(code::Symbol, message::AbstractString; kwargs...)

Construct a [`DiagnosticMessage`](@ref) with severity `:warning`.
Keyword arguments are collected into the diagnostic's `context`.
"""
warning(code::Symbol, message::AbstractString; kwargs...) = _diagnostic(:warning, code, message; kwargs...)

"""
    error_diagnostic(code::Symbol, message::AbstractString; kwargs...)

Construct a [`DiagnosticMessage`](@ref) with severity `:error`.
Keyword arguments are collected into the diagnostic's `context`.

Named `error_diagnostic` (not `error`) to avoid conflicting with
`Base.error`.
"""
error_diagnostic(code::Symbol, message::AbstractString; kwargs...) = _diagnostic(:error, code, message; kwargs...)

# ---------------------------------------------------------------------------
# PipelineTarget
# ---------------------------------------------------------------------------

"""
    PipelineTarget <: AbstractPipelineTarget

A named descriptor for a pipeline stage that an object might be checked for
readiness against, e.g. `PipelineTarget(:meshing)` or
`PipelineTarget(:cg_solve)`.

# Fields
- `name::Symbol`: the name of the target pipeline stage.
- `options::NamedTuple`: arbitrary small options relevant to the target.

`OodiCore` intentionally does not hard-code the set of valid target names;
downstream packages define and document their own.
"""
struct PipelineTarget <: AbstractPipelineTarget
    name::Symbol
    options::NamedTuple
end

PipelineTarget(name::Symbol; kwargs...) = PipelineTarget(name, (; kwargs...))

# ---------------------------------------------------------------------------
# ArtifactRef
# ---------------------------------------------------------------------------

"""
    ArtifactRef

A lightweight reference to an external artifact (a file, image, mesh export,
log, or other side product), without embedding the artifact's data.

# Fields
- `kind::Symbol`: e.g. `:png`, `:vtk`, `:glb`, `:csv`, `:html`, `:log`.
- `path::Union{Nothing,String}`: local filesystem path, if any.
- `uri::Union{Nothing,String}`: remote URI, if any.
- `description::String`: human-readable description.
- `metadata::NamedTuple`: small structured metadata.
"""
struct ArtifactRef
    kind::Symbol
    path::Union{Nothing,String}
    uri::Union{Nothing,String}
    description::String
    metadata::NamedTuple
end

function ArtifactRef(
    kind::Symbol;
    path::Union{Nothing,AbstractString} = nothing,
    uri::Union{Nothing,AbstractString} = nothing,
    description::AbstractString = "",
    kwargs...,
)
    return ArtifactRef(
        kind,
        path === nothing ? nothing : String(path),
        uri === nothing ? nothing : String(uri),
        String(description),
        (; kwargs...),
    )
end

# ---------------------------------------------------------------------------
# ValidationReport
# ---------------------------------------------------------------------------

"""
    ValidationReport <: AbstractValidationReport

The result of [`validate`](@ref) applied to some object.

# Fields
- `subject::Symbol`: a short label identifying the kind of object validated.
- `valid::Bool`: whether the object is internally valid.
- `diagnostics::Vector{DiagnosticMessage}`: diagnostics explaining the result.
- `metadata::NamedTuple`: small structured metadata.
"""
struct ValidationReport <: AbstractValidationReport
    subject::Symbol
    valid::Bool
    diagnostics::Vector{DiagnosticMessage}
    metadata::NamedTuple
end

"""
    isvalid(report::ValidationReport) -> Bool

Return whether `report` describes a valid object.

This method intentionally extends `Base.isvalid` rather than introducing a
new name, since "is this valid" is exactly `Base.isvalid`'s concept. It does
not affect any other `isvalid` methods.
"""
Base.isvalid(report::ValidationReport) = report.valid

# ---------------------------------------------------------------------------
# ReadinessReport
# ---------------------------------------------------------------------------

"""
    ReadinessReport <: AbstractReadinessReport

The result of [`readiness`](@ref) applied to some object and a
[`PipelineTarget`](@ref).

# Fields
- `subject::Symbol`: a short label identifying the kind of object checked.
- `target::PipelineTarget`: the pipeline stage readiness was checked against.
- `ready::Bool`: whether the object is ready for `target`.
- `diagnostics::Vector{DiagnosticMessage}`: diagnostics explaining the result.
- `metadata::NamedTuple`: small structured metadata.
"""
struct ReadinessReport <: AbstractReadinessReport
    subject::Symbol
    target::PipelineTarget
    ready::Bool
    diagnostics::Vector{DiagnosticMessage}
    metadata::NamedTuple
end

"""
    isready(report::ReadinessReport) -> Bool

Return whether `report` describes an object that is ready for its target
pipeline stage.

This method extends `Base.isready`, which already denotes "is this thing
ready to proceed" for e.g. `Channel` and `Task`; the meaning here is
consistent with that convention.
"""
Base.isready(report::ReadinessReport) = report.ready

# ---------------------------------------------------------------------------
# ObjectReport
# ---------------------------------------------------------------------------

"""
    ObjectReport <: AbstractOodiReport

A simple general-purpose report, useful as a default return type for
[`report`](@ref) on simple objects. Domain-specific packages are free to
define their own richer `AbstractOodiReport` subtypes instead.

# Fields
- `subject::Symbol`: a short label identifying the kind of object reported on.
- `summary::String`: a short human-readable summary.
- `metadata::NamedTuple`: small structured metadata.
- `diagnostics::Vector{DiagnosticMessage}`: any relevant diagnostics.
- `artifacts::Vector{ArtifactRef}`: references to related external artifacts.
"""
struct ObjectReport <: AbstractOodiReport
    subject::Symbol
    summary::String
    metadata::NamedTuple
    diagnostics::Vector{DiagnosticMessage}
    artifacts::Vector{ArtifactRef}
end

# ---------------------------------------------------------------------------
# Serialization: to_namedtuple
#
# Convention: field names are kept as Symbols (Julia-native, and JSON
# libraries such as JSON3/JSON.jl serialize Symbol keys as strings
# automatically). Symbol-valued fields (severity, code, subject, kind,
# target name, ...) are likewise kept as Symbols rather than eagerly
# converted to String, since callers on the Julia side generally want them
# back as Symbols; a JSON-encoding step at the boundary is expected to turn
# them into strings.
# ---------------------------------------------------------------------------

"""
    to_namedtuple(x)

Convert an `OodiCore` report/diagnostic/target type into a plain
`NamedTuple`, suitable for further JSON encoding or logging.

Symbols (e.g. `severity`, `code`, `subject`, `kind`) are kept as Symbols
rather than converted to `String`; convert them at the JSON-encoding
boundary if needed.
"""
function to_namedtuple end

to_namedtuple(d::DiagnosticMessage) = (
    severity = d.severity,
    code = d.code,
    message = d.message,
    context = d.context,
)

to_namedtuple(t::PipelineTarget) = (
    name = t.name,
    options = t.options,
)

to_namedtuple(a::ArtifactRef) = (
    kind = a.kind,
    path = a.path,
    uri = a.uri,
    description = a.description,
    metadata = a.metadata,
)

to_namedtuple(r::ValidationReport) = (
    subject = r.subject,
    valid = r.valid,
    diagnostics = to_namedtuple.(r.diagnostics),
    metadata = r.metadata,
)

to_namedtuple(r::ReadinessReport) = (
    subject = r.subject,
    target = to_namedtuple(r.target),
    ready = r.ready,
    diagnostics = to_namedtuple.(r.diagnostics),
    metadata = r.metadata,
)

to_namedtuple(r::ObjectReport) = (
    subject = r.subject,
    summary = r.summary,
    metadata = r.metadata,
    diagnostics = to_namedtuple.(r.diagnostics),
    artifacts = to_namedtuple.(r.artifacts),
)

# ---------------------------------------------------------------------------
# show methods
# ---------------------------------------------------------------------------

function _show_diagnostic(io::IO, d::DiagnosticMessage)
    print(io, "  [", d.severity, ":", d.code, "] ", d.message)
end

function Base.show(io::IO, ::MIME"text/plain", d::DiagnosticMessage)
    print(io, "[", d.severity, ":", d.code, "] ", d.message)
end

function Base.show(io::IO, r::ValidationReport)
    print(io, "ValidationReport(subject=:", r.subject, ", valid=", r.valid, ")")
    for d in r.diagnostics
        println(io)
        _show_diagnostic(io, d)
    end
end

function Base.show(io::IO, r::ReadinessReport)
    print(
        io,
        "ReadinessReport(subject=:",
        r.subject,
        ", target=:",
        r.target.name,
        ", ready=",
        r.ready,
        ")",
    )
    for d in r.diagnostics
        println(io)
        _show_diagnostic(io, d)
    end
end

function Base.show(io::IO, r::ObjectReport)
    print(io, "ObjectReport(subject=:", r.subject, ")")
    if !isempty(r.summary)
        println(io)
        print(io, "  ", r.summary)
    end
    for d in r.diagnostics
        println(io)
        _show_diagnostic(io, d)
    end
end

end # module OodiCore
