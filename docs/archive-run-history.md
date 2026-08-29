# AH5 run/activity/restart provenance

Issue #83 adds the second authoritative history-record layer on top of #81 state-history persistence. The extension restores the execution provenance needed by the existing replay/restart/rerun readiness logic without yet persisting events, write transactions, or log streams.

## Optional AH5 v1 extension

The feature flag is `:run_history_records` and the fixed root is `episteme/run_history`. The feature is optional: older AH5 archives remain readable, and a state-only archive yields a valid run-history view with no runs.

A run-history archive always includes #81 authoritative state records as well. The writer therefore publishes state first and appends run provenance atomically from the caller's perspective; if the optional append fails, the newly created file is removed.

## Persisted run contract

Each `RunRecord` preserves:

- run, plan, parent-run, and committed-revision identities;
- run status;
- software-environment, execution-context, and agent references;
- ordered activities with operation, idempotency key, reuse state, and exact used/generated `ArchiveReference`s;
- ordered staged envelopes with content identity, namespace/schema identity, origin/source/activity provenance, and references;
- optional restart requirements with execution context, source activity, and exact checkpoint object/content/revision/kind identities.

`ActivityRecord.run_id` is represented by containment in the enclosing run record rather than duplicated as a second physical column. This is lossless for valid logical state because Episteme's run invariant requires every nested activity to belong to its enclosing run. The writer validates that invariant before publication, and the forensic decoder reconstructs the logical `ActivityRecord.run_id` from the enclosing run identity.

## Plain-safe representation

Nested data is flattened into primitive columns with explicit owner indices. JLD2 `plain=true` can therefore inspect and reconstruct run history without loading domain packages or native scientific payload types. Owner indices and column lengths are validated during decoding.

## Cross-layer validation

The run-history validator composes with #81 state history rather than creating a parallel graph model. It checks:

- duplicate run/activity identities and activity containment;
- parent-run links;
- run↔revision and run↔plan consistency;
- run lifecycle/status rules;
- staged reuse/promotion consistency;
- staged namespace/schema identity against the same AH5 metadata published for state objects;
- activity used/generated and staged references against committed state, declared externals, or an unpinned staged object in the **same run**;
- restart source activity and checkpoint availability/content identity;
- object envelope `run_id` references;
- run count against the core AH5 history summary.

Run-local staging matters: an incomplete activity may generate an object that is not committed yet. Such an unpinned reference is valid only when that ObjectId is present in the same run's staging set. A pinned revision reference still requires committed state.

## Forensic reconstruction

```julia
write_run_archive(path, graph; schemas=schemas)
view = inspect_archive(path, ArchiveRunHistory)
graph2 = reconstruct_graph(view)
manifest = inspect(view, revision_id)
```

`reconstruct_graph` returns the ordinary payload-free `ArchiveGraph` containing #81 state and the restored runs. Existing `inspect` and `readiness` functions are then reused unchanged.

For a complete committed run, this slice is sufficient to restore current `:replay`, `:restart`, and `:rerun` readiness decisions when all required state is internal and the producing run recorded the required environment/activity/checkpoint metadata.

## Deliberate boundary

This extension does not persist `EventRecord`, `WriteTransaction`, or `LogStreamRecord`. The reconstructed graph leaves those vectors empty rather than pretending provenance completeness. A subsequent history slice can add them without changing state or run identities.
