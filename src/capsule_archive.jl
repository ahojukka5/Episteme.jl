# Capsule materialization preflight. Keep this part independent of file I/O;
# the JLD2 extension must complete it before creating a destination.
function _compact_capsule_source(
    source::ArchiveGraph,
    plan::CapsulePlan,
    schemas::SchemaRegistry;
    externals = ExternalRequirement[],
)
    isvalid(plan) || throw(ArgumentError("cannot materialize an invalid capsule plan"))
    _capsule_target(plan.target)
    _verification_level(plan.verification)
    plan.integrity.revision_id == plan.source_revision || throw(ArgumentError(
        "capsule integrity revision does not match the selected source revision",
    ))
    plan.integrity.requested_level === plan.verification || throw(ArgumentError(
        "capsule integrity verification level does not match the plan",
    ))
    reqs = _externals_vector(externals)
    selected = inspect(source, plan.source_revision; externals = reqs)
    isequal(to_namedtuple(selected), to_namedtuple(plan.manifest)) || throw(ArgumentError(
        "capsule plan no longer matches the selected source revision; plan it again",
    ))
    isequal(
        Tuple(to_namedtuple.(_capsule_externals(selected))),
        Tuple(to_namedtuple.(plan.externals)),
    ) || throw(ArgumentError("capsule external requirements do not match the source"))

    # Neither the plan's cached valid flag nor its mutable retained-id vectors
    # establish what a fresh compaction would preserve.
    result = compact_archive(
        source,
        [RetentionRoot(plan.source_revision)];
        policy = plan.retention.policy,
        externals = reqs,
    )
    result.graph === nothing && throw(ArgumentError(
        "capsule source does not produce a valid compacted archive",
    ))
    isequal(to_namedtuple(result.plan), to_namedtuple(plan.retention)) &&
        result.plan.retained_runs == plan.retention.retained_runs &&
        result.plan.omitted_runs == plan.retention.omitted_runs || throw(ArgumentError(
            "capsule retention plan no longer matches the source; plan it again",
        ))

    manifests = [plan.integrity]
    _refuse_unstorable_integrity(manifests)
    _refuse_integrity_archive_mismatch(manifests, source, schemas, reqs)
    diagnostics = _capsule_validation_diagnostics(selected, plan.integrity, result.plan)
    any(d -> d.severity === :error, diagnostics) && throw(ArgumentError(
        "capsule source fails retention or integrity validation",
    ))
    # Rebinding to the compacted graph also proves that its selected closure
    # still agrees with the integrity layer that will be persisted.
    _refuse_integrity_archive_mismatch(manifests, result.graph, schemas, reqs)
    return result
end
