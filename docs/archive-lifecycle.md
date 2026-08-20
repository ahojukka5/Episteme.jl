# Durable run, commit, and restart contract

This is the logical lifecycle contract from issue
[#27](https://github.com/ahojukka5/Episteme.jl/issues/27). It lives in
Episteme as structured records, `validate`, and `readiness`. It does not
implement `execute!` / `commit!` and it does not open files.

Physical `.ah5` encoding, JLD2 append, and later HDF5.jl bulk I/O must
preserve these rules. v1 persistence is JLD2-backed AH5.

The accepted split is:

```text
execute! -> Run / Activity / Event / staging     # durable, no head movement
commit!  -> Revision + selected head update      # explicit publication
```

## Status vocabulary

`RunRecord.status` is one of `RUN_STATUSES`:

| Status | Meaning | May name a `RevisionId`? |
| --- | --- | --- |
| `:queued` | not started | no |
| `:running` | in progress | no |
| `:completed` | execute finished; commit is a separate step | only after `commit!` |
| `:failed` | execute failed; evidence may already be durable | no (default) |
| `:interrupted` | crashed or stopped mid-write | no |
| `:cancelled` | explicitly cancelled | no |
| `:uncertain` | a durable external side effect has unknown outcome | no |

An incomplete run remains inspectable as a run. `validate` reports
`:incomplete_run_has_revision` (or `:uncertain_run_has_revision`) if that
run names a revision. A `RevisionRecord` that names an uncommitted run
fails with `:uncommitted_run_has_revision`. Failed, cancelled, and
interrupted runs keep already-durable events by default and do not mint a
revision.

`readiness(run, PipelineTarget(:commit))` is true only when status is
`:completed` and `revision_id === nothing`. Graph-level
`readiness(graph, PipelineTarget(:commit; run_id = ...))` also requires
the target run's staging to be valid against the graph (reuse source and
content identity) and that no in-flight archive writer is present.

## Staging and promotion

Uncommitted snapshot payloads are **not** `ArchiveGraph.objects`. They
sit on `RunRecord.staged` as `StagedObject` rows:

- `:generated` — produced by this run
- `:reused` — identity copied from an existing committed version;
  `source_revision_id` is required and must resolve. If the source has a
  `ContentId`, the staged row must keep that exact id
  (`:reused_content_missing` / `:reused_content_mismatch` otherwise).

`promote_staged(run, revision_id)` is a pure mapping to `ArchiveObject`
rows, including `ProvenanceRefs` and named `ArchiveReference`s. Later
`commit!` uses that mapping: it creates exactly one new immutable
`RevisionRecord`, inserts the promoted rows, and moves only the selected
`WorkflowHead`. It must not alias a prior envelope row and must not
rewrite committed objects or revisions.

After a run is committed, each staged object must appear under that
revision (`:staged_not_promoted` / `:committed_content_mismatch` if not).
Reused content keeps `ObjectId` / `ContentId` and gets a new envelope
row. Domain packages decide whether two scientific results are reusable;
Episteme does not invent reuse.

Run-attached evidence bytes (shots, logs, solver dumps that must survive
a crash) may later live under a run-scoped JLD2 path. They still have no
`RevisionId` until `commit!`.

## Interrupted writes

`WriteTransaction` is the logical begin/append/commit marker:

| Phase | Meaning |
| --- | --- |
| `:begin` | writer has started |
| `:appending` | run log / staging is being written |
| `:committing` | staged rows are being promoted |
| `:committed` | the write finished; a revision exists |
| `:aborted` | the write was closed without publication |
| `:uncertain` | fail-closed; do not treat as committed |

Transactions live on `ArchiveGraph.writes`, not as file handles.
An in-flight write (`:begin`, `:appending`, `:committing`) must not name
a revision (`:in_flight_write_has_revision`). A `:committed` write
without a revision fails (`:committed_write_missing_revision`). Crash
recovery inspects the run and the write phase; it never presents an
incomplete write as a committed revision.

## Locking (v1 JLD2)

v1 is **single-writer per archive**. An in-flight `:archive` transaction
needs a `writer_token`. A second in-flight archive writer fails
`:multiple_archive_writers`. An in-flight or `:uncertain` archive-scope
transaction, including one with `run_id === nothing`, blocks
`readiness(..., PipelineTarget(:commit))`. Run-scoped transactions record
which run is appending without implying a second archive file writer.

This is compatible with a later parallel bulk-data path: ranks may buffer
source-locally and publish through the same logical phases. Parallel
HDF5 is not required here and must not change identities or commit
semantics.

## Restart

A restart is opt-in. `RestartRequirement` lists exact
`CheckpointRef`s (object / content / optional revision) and optional
execution context. Episteme does not guess a checkpoint when the
requirement is missing (`:restart_not_declared`).

`readiness(graph, PipelineTarget(:restart; run_id = ...))` resolves those
refs against committed objects and run-local staging. Missing identity
is `:missing_restart_checkpoint`. Present object with the wrong
`ContentId` is `:incompatible_restart_content`. A required `ContentId`
against a found object that has no content id is
`:unverified_restart_content` (fail-closed; do not guess). Domain
packages own what the checkpoint bytes mean.

Restartable statuses are `:failed`, `:interrupted`, `:cancelled`, and
`:uncertain`. A committed run is not restarted; that is a later `rerun!`.

## Event sequence

`EventRecord.sequence` is an optional source-local monotonic identity.
`source` names the rank/thread/process that assigned it. Wall-clock
values in `payload` are metadata and are never the causal order.
`ordered_run_events` sorts by source then sequence.
Duplicate `(run, source, sequence)` fails `:duplicate_event_sequence`.

The richer event timeline product remains issue #44.

## Fail-closed external effects

When a durable external side effect (instrument job, remote write, device
acquire) has an unknown outcome, record `status === :uncertain` and/or
write phase `:uncertain`. `readiness` for `:commit` fails with
`:uncertain_side_effect`. Do not invent success, do not mint a revision,
and do not resume as if the effect completed.

## What this is not

- `execute!` / `commit!` / `branch!` / `rerun!` runtime
- JLD2 or HDF5 file I/O, begin/commit markers on disk, or OS file locks
- domain checkpoint contents or solver-iteration revisions
- parallel HDF5 or multi-writer bulk I/O
- the full event/log stream product (#44)
