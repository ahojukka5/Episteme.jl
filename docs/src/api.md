# Public API

`src/Episteme.jl` exports 313 names from the single public module `Episteme`.
There are no nested public modules. The list below is the curated entry
points: each name is an `export` in that file, and the sentence is taken
from the docstring or the method that was read. The other exports are
records, constants, inspection views, and lookups in the same module.

## Introspection

Defined in `src/introspection.jl`.

- `report` — return a structured report describing `x`. There is no default
  method.
- `validate` — check whether `x` is internally consistent and return an
  `AbstractValidationReport`. There is no default method.
- `readiness` — check whether `x` is ready for the pipeline stage in
  `target`. There is no default method.
- `AbstractEpistemeReport` — supertype of reports returned by `report`,
  `validate`, and `readiness`.
- `AbstractValidationReport` — supertype of reports returned by `validate`.
- `AbstractReadinessReport` — supertype of reports returned by `readiness`.
- `AbstractDiagnostic` — supertype of structured diagnostic messages.
- `AbstractPipelineTarget` — supertype of the target passed to `readiness`.
- `DiagnosticMessage` — one diagnostic with severity, code, message, and
  context.
- `info_diagnostic` — construct a `DiagnosticMessage` with severity `:info`.
- `warning_diagnostic` — construct a `DiagnosticMessage` with severity
  `:warning`.
- `error_diagnostic` — construct a `DiagnosticMessage` with severity
  `:error`.
- `PipelineTarget` — a named next-stage descriptor.
- `ArtifactRef` — a reference to an external artifact, without the artifact
  bytes.
- `ValidationReport` — the result of `validate`.
- `ReadinessReport` — the result of `readiness` for one object and one
  `PipelineTarget`.
- `isready` — whether a `ReadinessReport` says the object is ready.
- `ObjectReport` — a general-purpose `report` value.
- `to_namedtuple` — convert a supported Episteme value to a plain
  `NamedTuple`.

## Semantic tree and local schemas

`SemanticNode` and its editors are defined in `src/semantic_tree.jl`.
Schemas and `script_node` are defined in `src/declarative.jl`.

- `SemanticNode` — a domain-neutral node: kind, optional name, attributes,
  and ordered children.
- `NodeRef` — a symbolic reference. Episteme does not resolve it.
- `add_child!` — append a child and return the parent.
- `attribute` — read one attribute. The two-argument form throws `KeyError`
  when the key is absent.
- `set_attribute!` — set or add an attribute, keeping canonical key order.
- `ValidationRule` — a symbolic local rule (`kind` plus parameters), not a
  closure.
- `AttributeSchema` — one attribute: name, portable value kind, and rules.
- `NodeSchema` — the local schema of one node kind.
- `NodeValidationRule` — a symbolic rule over several attributes of one node.
- `check_validation_rule` — evaluate one symbolic value rule. Domain packages
  add methods for new kinds.
- `check_node_validation_rule` — evaluate one symbolic node-local rule.
- `validated_node` — construct a `SemanticNode` and require that it satisfies
  the schema.
- `script_node` — store an opaque script contract. Episteme does not execute
  the source.

## Identities and the envelope

Defined in `src/archive_envelope.jl` unless noted.

- `ObjectId` — stable logical identity of an archived object. Two revisions
  of the same object share one `ObjectId`.
- `RevisionId` — identity of one workflow revision.
- `ContentId` — identity of logical content, independent of file placement.
- `RunId` — identity of a run that may produce several revisions.
- `WorkflowHeadId` — identity of a workflow bookmark. The id stays put when
  the bookmark moves.
- `DocumentId` — identity of an authored semantic document.
- `PlanId` — identity of a resolved executable plan.
- `ArchiveNamespace` — owning package namespace. Identity is `package_uuid`
  when that string is non-empty.
- `episteme_namespace` — the shared Episteme namespace. Defined in
  `src/archive_namespaces.jl`.
- `SchemaRef` — exact payload-schema identity: namespace, schema id, and
  version.
- `schema_kind` — the package-qualified kind, `namespace/schema_id`.
- `ArchiveObject` — one object envelope at one revision.
- `WorkflowHead` — a bookmark pointing at a `RevisionId`.
- `ArchiveGraph` — objects, heads, revisions, runs, events, writes, and
  optional log streams.
- `event_timeline` — generic event rows. No domain payload is loaded.

## Plans, runs, and in-memory publication

`OperationSpec`, `Plan`, `PlanBinding`, and `promote_staged` are defined in
`src/archive_history.jl`. The lifecycle functions are defined in
`src/archive_execution.jl`.

- `OperationSpec` — a domain-owned operation declaration. Episteme does not
  implement the operation.
- `PlanBinding` — an identity-bound assignment of one plan role.
- `Plan` — a resolved recipe. It is not a scheduler.
- `apply_operation` — domain hook. Methods are
  `apply_operation(::Val{kind}, spec, inputs; context...)`.
- `staged_result` — wrap a payload as a staged envelope without committing it.
- `WorkingStore` — session-local payload map. The envelope does not store
  domain bytes.
- `store_payload!` — put a live payload in a `WorkingStore`.
- `fetch_payload` — read that payload. A requested revision does not fall
  back to the bare object id.
- `execute!` — record a run and stage outputs. Never moves a workflow head.
- `commit!` — promote a completed run, mint one revision, and move one head.
- `recover_writes!` — deterministic recovery of in-flight or uncertain write
  transactions. Incomplete commits are not left as published heads.
- `restart!` — start a new run linked to an incomplete run's restart
  requirement.
- `promote_staged` — map a run's staging set to envelope rows. Does not
  mutate the run, move a head, or write a file.

## Lazy revisions, purge, and content identity

- `inspect` — in-memory lazy revision manifest. No file I/O and no payload
  load. Defined in `src/archive_checkout.jl`.
- `checkout` — lazy checkout of a committed snapshot from an in-memory graph.
  Payloads stay unloaded. Defined in `src/archive_checkout.jl`.
- `select` — one lazy slot of a revision manifest. Does not load payload
  bytes. Defined in `src/archive_checkout.jl`.
- `branch_from` — bookmark a historical revision without mutating it.
  Defined in `src/archive_checkout.jl`.
- `plan_purge` — dry-run reachability. Does not mutate the graph or write a
  file. Defined in `src/archive_purge.jl`.
- `compact_archive` — build a new compacted graph. The source graph is not
  mutated. Defined in `src/archive_purge.jl`.
- `canonical_content_id` — strong logical content identity, encoded as
  `sha256:<lowercase hex>`. Defined in `src/content_integrity.jl`.
- `plan_migration` — resolve one shortest semantic migration chain. Defined
  in `src/schema_migration.jl`.
- `migrate_object` — apply that chain to a portable payload. The source
  envelope is not mutated. Defined in `src/schema_migration.jl`.

## Portable documents

Defined in `src/portable_document.jl`.

- `capture_portable` — fail-closed capture of live trees into a
  `PortableSemanticDocument`.
- `validate_portable` — check whether live `SemanticNode` roots are in the
  portable universe.
- `portable_sexpr` — render a portable node or document.

## AH5 files

The signatures below are the stubs in `src/archive_persistence.jl`. Each one
throws until the caller runs `using JLD2`, which loads the methods in
`ext/episteme_jld2_ext.jl`.

- `write_archive` — create a JLD2-backed AH5 file. Existing paths are
  refused. Domain payloads are not written.
- `inspect_archive` — read AH5 profile metadata without loading domain
  payloads.
- `write_state_archive` — write an archive plus payload-free state history.
- `write_run_archive` — write state history and run/activity provenance.
- `write_event_archive` — write state, run, and event/write/log provenance
  metadata.
- `write_derived_archive` — write payload-free derived-artifact records.
- `write_capsule_archive` — materialize a standalone reproduction capsule
  from a valid `CapsulePlan`.
- `verify_capsule` — re-read a capsule and verify portable payload identities
  before returning them.
- `materialize_migration` — when every request has a valid semantic
  migration, write a new archive. The source path is not opened for writing.
