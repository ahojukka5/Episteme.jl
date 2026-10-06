# Semantic schema migration chains

Issue [#41](https://github.com/ahojukka5/Episteme.jl/issues/41) keeps
semantic schema migration separate from Julia representation upgrades and
from AH5 physical-layout changes.

[#103](https://github.com/ahojukka5/Episteme.jl/issues/103) plans and
applies a migration in memory. [#140](https://github.com/ahojukka5/Episteme.jl/issues/140)
publishes a valid result as a **new** AH5 archive. Neither slice rewrites
the source file, runs JLD2 `Upgrade`, or changes physical layout.

## Four axes stay separate

| Axis | Owner | This slice |
| --- | --- | --- |
| Semantic schema id/version | Episteme runner + domain `migrate_payload` | yes |
| Julia representation | JLD2 `Upgrade` / `rconvert` | refused |
| Episteme shared record evolution | later Episteme-owned steps | not yet |
| AH5 physical profile | later archive rewrite | not this slice |

Package release version is never a compatibility signal.

## Planning

`SchemaMigrationRegistry` is a directed graph of
`SchemaMigrationStep`s, keyed by exact `SchemaRef` (namespace, schema
id, version). `plan_migration` returns a unique shortest chain:

```julia
plan = plan_migration(source, target, migrations; schemas)
isvalid(plan)
plan.status   # :identity, :direct, :chain, :unsupported, :ambiguous
```

Equal source and target is `:identity` and does not rewrite content.
Missing chains are `:unsupported`. Two shortest routes are
`:ambiguous`. Duplicate source/target edges with different
implementations are refused when the registry is constructed. Invalid
plans must not be applied.

A metadata-only step sets `rewrite_payload=false`. The plan's
`rewrite_payload` flag is true when any step rewrites payload bytes.

## Application

Domain packages extend the hook; Episteme does not know field meaning:

```julia
import Episteme: migrate_payload
migrate_payload(::Val{:toy_field_v1_v2}, payload::NamedTuple, step) =
    (; name = payload.name, samples = payload.values)
```

`migrate_object` validates the portable payload against each embedded
schema, calls the named implementation, and returns a **new** envelope.
The source object is unchanged. The migrated object keeps the source
`ObjectId`, uses a caller-supplied new `RevisionId`, and records old
and new schema identities. Put the new revision in the DAG with
`parents = [source.revision_id]`.

Metadata-only chains reuse `ContentId`. Any payload rewrite mints a
new canonical identity. Episteme never fills missing required target
fields; the domain migrator must produce a complete portable
NamedTuple, or the run fails closed.

If the implementation is not loaded, the result names the required
package/capability and creates no output object.

## New archive

`migrate_archive` applies those same requests to an in-memory graph and
returns a successor graph. It does not mutate the source graph and it
does not create a file. `materialize_migration` reads a source `.ah5`
file and, only when that successor is valid, publishes it with the
existing `write_event_archive` path.

```julia
materialize_migration(
    destination,
    source,
    requests,
    migrations;
    schemas,
    revision_id,
    run_id,
    software_environment,
)
```

The source path is opened read-only. An existing destination is refused.
An unsupported, ambiguous, or unloaded migrator returns before any output
file is created.

The successor keeps the source objects and revision records. Migrated
objects share the source `ObjectId`, use the caller-supplied revision, and
record that revision's parents as the source revisions. A single parent
moves heads that pointed at it. Old and new `SchemaRef`s are embedded.
Each migrated object also gets a `:schema_migration` event whose payload
records implementation ids, schema versions, content ids, software
identity, and diagnostics. Pass `software_environment` to store the
migrator's `SoftwareEnvironment` record; omitting it leaves a warning and
does not invent machine facts.

Metadata-only steps persist the source `ContentId`. A payload rewrite
persists the canonical id from `migrate_object`. Scientific payload bytes
are not part of the AH5 profile, so reuse is that identity, not a second
copy of a dataset.

A source object whose embedded schema is `:migration_required` still
cannot be retained: existing graph validation refuses to publish that
object. The historical fixture is the schema version that was valid to
archive. The migration registry, not a compatibility guess, performs the
step.

## Deliberate non-goals

- treating successful JLD2 reconstruction as schema compatibility
- in-place rewrite of the only archive copy
- a second AH5 writer or a physical-layout migration
- domain scientific transforms inside Episteme
- general archive compaction
- signatures or PKI
