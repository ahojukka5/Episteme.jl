module OodiCore

include("introspection.jl")
include("semantic_tree.jl")
include("declarative.jl")

export report, validate, readiness
export AbstractOodiReport, AbstractValidationReport, AbstractReadinessReport
export AbstractDiagnostic, AbstractPipelineTarget
export DiagnosticMessage, ValidationReport, ReadinessReport, ObjectReport
export PipelineTarget, ArtifactRef
export info, warning, error_diagnostic
export isready, to_namedtuple
export SemanticNode, NodeRef, add_child!, attribute, set_attribute!
export ValidationRule, AttributeSchema, NodeSchema
export script_node, validated_node, check_validation_rule

end # module OodiCore
