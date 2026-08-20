# Durable event timeline and optional log streams

This is the logical event-timeline contract from issue
[#44](https://github.com/ahojukka5/Episteme.jl/issues/44). It lives in
Episteme as structured records, `validate`, and generic inspection. It
does not implement JLD2/HDF5 append layout or a logging service.

The structured revision/object/run/activity graph remains the source of
truth. The event timeline is a denormalized navigation/audit view.
Event text is never authoritative scientific state: if a message
disagrees with structured metadata, the structured fields win.

## EventRecord

`EventRecord` belongs to a run and may optionally name an activity,
revision, objects, producer, and execution context.

| Field | Role |
| --- | --- |
| `sequence` | source-local monotonic identity; causal order |
| `source` | rank/thread/process that assigned the sequence |
| `timestamp` | optional UTC string; metadata only |
| `scope` | namespace/component |
| `severity` | `:debug`, `:info`, `:warn`, `:error` |
| `kind` | event category |
| `message` | short UTF-8 text |
| `object_refs` | optional `ObjectRef`s |
| `retention` | `:ephemeral`, `:debug`, `:forensic`, `:pinned` |
| `payload` | extra structured facts, still not scientific state |

Default retention for structured events is `:forensic`. Wall-clock
timestamps are never the only ordering primitive.
`ordered_run_events` and `event_timeline` sort by run, source, then
sequence.

`event_timeline(graph; run_id=...)` returns rows with time / scope /
severity / kind / message / reference columns and does not load domain
payloads.

Events are not revisions. Uncommitted and failed runs keep already
recorded events with `revision_id === nothing` on the run.

## Batching

`EventBatch` groups many events published in one durable append. A v1
JLD2 writer must persist that batch in one metadata transaction. Inner
solver loops should not open a write per event. Rank-local buffering
and later `EpistemeHDF5Ext` streams must preserve the same
`EventRecord` semantics.

## Optional raw log streams

`LogStreamRecord` archives stdout/stderr/trace by reference
(`ContentId` when bytes exist). It is opt-in, never a substitute for
typed provenance, and default retention `:debug` is purgeable unless
`:pinned` or `:forensic`. Dropping a debug stream must not change
committed objects or revisions.

## Secrets

The generic event/log path is fail-closed. Payload keys whose names look
like secrets, and values that look like bearer tokens, vendor API keys,
or PEM private keys, fail `validate` with `:credential_like_content`.
Full execution-context denylists remain issue #43.

## What this is not

- a high-throughput logging service
- JLD2/HDF5 extendible tables or on-disk append layout
- domain checkpoint contents flattened into log text
- parallel unsynchronized shared-file writes
