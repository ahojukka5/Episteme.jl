# Explicit purge, reachability, and compaction

This is the in-memory purge/compaction contract from issue
[#31](https://github.com/ahojukka5/Episteme.jl/issues/31). Ordinary
research writes never delete committed history. Purge is an explicit
maintenance operation: it computes reachability from caller-selected
roots and builds a **new** graph. The source is not mutated.

Physical JLD2/AH5 rewriting is later work and must keep these
reachability semantics.

## Roots and policy

`RetentionRoot` names a workflow head, revision, object version, run, or
log stream. A `:log_stream` root requires `(run_id, log_kind)` and forces
that stream to survive even when `keep_debug_logs=false`. A missing
`(run, kind)` pair is an error. An `:object` root walks that object
version's reference closure and keeps only the revision records needed
for valid parent edges; sibling objects in the same revision are not
kept merely because they share a snapshot.

`RetentionPolicy` is data:

- `keep_ancestor_objects` — also keep every object materialized in
  ancestor revisions, not only the inspect closure
- `keep_uncommitted_runs` — keep failed/uncommitted runs
- `keep_debug_logs` / `keep_forensic_logs` — optional log/event retention

Pinned log streams and pinned events always survive and keep their run.
Ancestor *revision records* of retained revisions are always kept so
parent edges remain valid. Identities are not rewritten.

## Reachability

From each revision or head root, purge walks the same revision-scoped
object/reference closure as `inspect`. Object roots start from that
version only. Reachability then closes retained runs over
`parent_run_id`, retained activity `used` / `generated` references, and
object refs on retained events so compacted provenance cannot dangle.
Objects, runs, events, writes, and logs outside that set are omitted.
Classifications:

| Class | Meaning |
| --- | --- |
| `:reachable` | retained object version |
| `:unreachable` | omitted object version |
| `:duplicated_content` | reported as a count of retained `ContentId`s with several rows |
| `:external` | declared `ExternalRequirement`, not dropped |
| `:purgeable_debug` | debug/ephemeral logs or events on a retained run |

Identical retained `ContentId`s are counted once for byte/content
totals. Several `ArchiveObject` rows may still share that id.

## API

- `plan_purge(graph, roots; policy, externals, content_sizes)` — dry-run
  manifest, including reachability diagnostics
- `compact_archive(...)` — new graph plus `PurgeResult`

`validate(plan)` is false when required dependencies are unresolved, so
the dry-run is not fail-open relative to compaction.

If verification fails (retained revisions would not inspect cleanly),
`result.graph === nothing`. The source archive is still unchanged and
the target is not presented as valid.

`readiness(result, PipelineTarget(:inspect))` is true only for a
verified compacted graph.

## What this is not

- ordinary write-time deletion
- in-place history rewrite
- a universal scientific retention policy
- JLD2/AH5 file copying (logical graph only)
