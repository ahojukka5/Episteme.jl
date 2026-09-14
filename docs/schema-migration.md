# Semantic schema migration chains

This is the first implementation slice of issue
[#41](https://github.com/ahojukka5/Episteme.jl/issues/41), tracked by
[#103](https://github.com/ahojukka5/Episteme.jl/issues/103). It plans and
applies **semantic** schema migrations in memory. It does not rewrite an
AH5 file, run JLD2 `Upgrade`, or change physical layout.

## Four axes stay separate

| Axis | Owner | This slice |
| --- | --- | --- |
| Semantic schema id/version | Episteme runner + domain `migrate_payload` | yes |
| Julia representation | JLD2 `Upgrade` / `rconvert` | refused |
| Episteme shared record evolution | later Episteme-owned steps | not yet |
| AH5 physical profile | later archive rewrite | not yet |

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

## Deliberate non-goals

- writing a new `.ah5` archive
- treating successful JLD2 reconstruction as schema compatibility
- in-place rewrite of the only archive copy
- signatures or PKI
