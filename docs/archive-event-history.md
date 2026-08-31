# AH5 event, write, and log provenance

Issue #85 completes the generic provenance-history persistence chain above the
state-history and run-history extensions. It is an optional AH5 v1 feature and
does not change the core `ArchiveInspection` contract.

## Layering

An event-history archive contains the earlier layers as well:

```text
AH5 core profile/summaries
  -> authoritative state history
  -> run/activity/restart history
  -> event/write/log metadata
```

The optional feature is `:event_history_records` at the fixed
`episteme/event_history` root. Its indexed children are `events`, `writes`, and
`log_streams`.

`write_event_archive(...)` writes the lower layers first and only publishes the
new extension after all state, run, event, write, and log metadata has passed
fail-closed validation. If the optional append fails, the newly created archive
is removed.

## Event payloads

`EventRecord.payload` is not written as an arbitrary native Julia `NamedTuple`.
The writer first captures it through the same portable-value universe used by
portable declarative documents, then stores the captured value using the
existing tagged plain-safe representation.

This means:

- portable scalar/container semantics are shared with the document layer;
- package-local types require an explicit portable codec;
- live handles, functions, tasks, pointers, provider clients, and other
  unsupported runtime values are refused before publication;
- generic forensic inspection never requires the package that originally
  defined an encoded portable value.

Credential-like payload content is checked recursively before persistence,
including nested named-tuple and dictionary keys. This is intentionally stricter
than treating successful JLD2 serialization as permission to archive a value.

Event `object_refs` remain references to archived scientific object envelopes.
Direct `ExternalRequirement` references are not introduced by this slice; an
external artifact is represented through the archived scientific state that
refers to it.

## Write transactions

`WriteTransaction` records preserve scope, phase, sequence, optional run id, and
writer token. The existing single-writer and run-lifecycle validation is reused
after reconstruction. These are logical durability facts, not physical HDF5
transactions.

## Log streams

`LogStreamRecord` persists only metadata: run/activity identity, kind, source,
retention, optional strong content identity, and optional summary. Raw stdout,
stderr, or trace bytes are not embedded by this layer.

If a log stream carries `content_id`, it must use the current strong
`sha256:<64 lowercase hex>` form. This lets a later capsule or artifact layer
bind raw stream bytes without making this metadata extension a bulk-log store.

## Forensic reconstruction

```julia
view = inspect_archive(path, ArchiveEventHistory)
graph = reconstruct_graph(view)
timeline = event_timeline(view)
```

A valid view reconstructs the ordinary `ArchiveGraph` with objects, revisions,
heads, runs, events, writes, and log-stream records populated. Existing graph
validation, timeline ordering, purge/reachability, and revision readiness logic
therefore remain authoritative; this layer does not create a parallel replay or
provenance model.

Old run-history archives that do not declare the event-history feature remain
valid and return an empty event/write/log view while preserving reconstructed
state and runs.

## Remaining boundary

This completes generic state/execution/event metadata persistence. It still does
not embed scientific payload bytes, raw log bytes, full software-environment or
execution-context manifests, migrations, or signatures. Those remain separate
archive/capsule layers.
