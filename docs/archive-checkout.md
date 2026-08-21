# Lazy revision inspect and checkout

This is the in-memory scientific-state manifest from issue
[#33](https://github.com/ahojukka5/Episteme.jl/issues/33). It does not
open files or load heavy payloads.

Two related APIs share `RevisionManifest`:

| API | Role |
| --- | --- |
| `inspect(graph, revision)` | in-memory generic record read |
| `checkout(graph, revision)` | snapshot/state primitive; payloads stay unloaded |
| `inspect_archive(path)` | JLD2-backed `.ah5` profile inspect; see [`archive-profile.md`](archive-profile.md) |

File-path payload `checkout` is later work and must return the same
manifest contract. Domain payload packages are not required to inspect
envelope fields.

## Manifest

`inspect` / `checkout` resolve a `RevisionId` (or a `WorkflowHead` /
unique head name / committed `RunId`) to:

- envelope objects materialized in that revision
- the transitive resolved reference closure visible from that revision
  and its ancestors (not sibling or future branches)
- named references, with dangling vs declared-external distinguished
- producing run and plan, if recorded
- parent/child/ancestor/descendant revision ids
- workflow heads currently pointing at the revision (bookmarks, not
  identity)

`select(manifest, object_id)` returns one lazy slot when that id is
unique in the closure. If the same `ObjectId` appears at more than one
revision, pin `select(manifest, object_id, revision_id)` or
`select(manifest, ObjectRef(...))`. It never materializes payload arrays.

Payload availability:

| Status | Meaning |
| --- | --- |
| `:envelope_only` | object metadata is in the graph; bytes are not loaded |
| `:external_required` | declared via `ExternalRequirement`; not archive corruption |
| `:missing` | dangling archive reference; revision is not complete |

## Readiness

`readiness(manifest, target)` uses:

- `:inspect` — no `:missing` slots (declared externals are allowed)
- `:replay` — inspectable, no unresolved externals, producing run
  recorded a software environment
- `:restart` — inspectable, and declared `RestartRequirement` checkpoints
  exist as `:envelope_only` slots in this snapshot
- `:rerun` — inspectable, no unresolved externals, producing run has at
  least one activity

Episteme does not promise domain restart/replay; it reports missing
dependencies. A completed producing run is expected for a committed
revision.

## Branching

`branch_from(revision_id; id, name)` returns a new `WorkflowHead`. It
does not mutate historical objects or revision records. Inserting that
head into a copy of the graph changes bookmarks only.

## What this is not

- payload `checkout` from `.ah5` files or payload codecs
- `branch!` / `rerun!` runtime
- silent fetch of external artifacts
- a claim that a domain solver can restart from envelope metadata alone
