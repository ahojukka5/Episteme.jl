module Episteme

include("introspection.jl")
include("semantic_tree.jl")
include("declarative.jl")
include("archive_envelope.jl")
include("archive_checkout.jl")
include("archive_namespaces.jl")
include("archive_schemas.jl")
include("archive_purge.jl")
include("portable_document.jl")

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
export DocumentId, PlanId, ActivityId, AgentId
export ArchiveNamespace, SchemaRef, KnownSchema, ProvenanceRefs
export schema_kind, schema_status, resolve_schema, SCHEMA_COMPATIBILITY
export EPISTEME_NAMESPACE, EPISTEME_PACKAGE_UUID
export RESERVED_SHARED_NAMESPACES, RESERVED_ARCHIVE_AREAS
export NAMESPACE_ROLES, NAMESPACE_STATUSES
export NamespaceClaim, NamespaceRegistry, NamespaceListing
export episteme_namespace, is_reserved_shared_namespace, is_reserved_archive_area
export owns_kind, find_claim, resolve_namespace, list_namespaces, ordered_claims
export SchemaField, SchemaMigrationRef, SchemaDefinition, SchemaRegistry, SchemaListing
export SCHEMA_CARDINALITIES, known_schemas, list_schemas, ordered_schemas
export ObjectRef, ArchiveReference
export LogicalType, LogicalArraySpec, LOGICAL_SCALAR_KINDS
export ArchiveObject, WorkflowHead, ArchiveGraph, ArchiveCatalog
export OperationSpec, Plan, RevisionRecord, RunRecord, ActivityRecord, EventRecord
export StagedObject, CheckpointRef, RestartRequirement, WriteTransaction
export EventBatch, LogStreamRecord
export EPISTEME_DOCUMENT_KIND, EPISTEME_PLAN_KIND
export episteme_document_schema, episteme_plan_schema
export RUN_STATUSES, WRITE_PHASES, STAGED_ORIGINS, WRITE_SCOPES
export EVENT_SEVERITIES, EVENT_RETENTION, LOG_STREAM_KINDS
export ordered_objects, ordered_references, ordered_heads
export ordered_revisions, ordered_runs, ordered_events, ordered_writes
export ordered_run_events, ordered_log_streams, event_timeline
export find_object, find_objects, find_revisions, find_revision, find_run, find_write
export find_head
export promote_staged
export revision_parents, revision_children, revision_ancestors, revision_descendants
export ExternalRequirement, ManifestEntry, RevisionManifest
export inspect, checkout, select, branch_from
export RetentionPolicy, RetentionRoot, PurgeClassification, PurgePlan, PurgeResult
export plan_purge, compact_archive
export PortableEncoded, PortableNode, PortableSemanticDocument
export portable_encode, portable_decode, is_portable_value
export validate_portable, capture_portable, restore_semantic
export from_namedtuple, portable_sexpr

end # module Episteme
