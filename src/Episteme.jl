module Episteme

include("introspection.jl")
include("semantic_tree.jl")
include("declarative.jl")
include("archive_envelope.jl")

export report, validate, readiness
export AbstractEpistemeReport, AbstractValidationReport, AbstractReadinessReport
export AbstractDiagnostic, AbstractPipelineTarget
export DiagnosticMessage, ValidationReport, ReadinessReport, ObjectReport
export PipelineTarget, ArtifactRef
export info_diagnostic, warning_diagnostic, error_diagnostic
export isready, to_namedtuple
export SemanticNode, NodeRef, add_child!, attribute, set_attribute!
export ValidationRule, AttributeSchema, NodeSchema, NodeValidationRule
export script_node, validated_node, check_validation_rule, check_node_validation_rule
export AbstractArchiveId, ObjectId, RevisionId, ContentId, RunId, WorkflowHeadId
export SoftwareEnvironmentId, ExecutionContextId
export ArchiveNamespace, SchemaRef, KnownSchema, ProvenanceRefs
export schema_kind, schema_status, resolve_schema, SCHEMA_COMPATIBILITY
export ObjectRef, ArchiveReference
export LogicalType, LogicalArraySpec, LOGICAL_SCALAR_KINDS
export ArchiveObject, WorkflowHead, ArchiveGraph, ArchiveCatalog
export ordered_objects, ordered_references, ordered_heads
export find_object, find_objects, find_revisions

end # module Episteme
