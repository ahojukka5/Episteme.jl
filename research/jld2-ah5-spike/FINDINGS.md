# JLD2 as the Julia-native AH5 persistence layer

Spike for [issue #47](https://github.com/ahojukka5/OodiCore.jl/issues/47).
This is evidence and a recommendation. It does **not** add JLD2 or HDF5
to Episteme. Historical notes below may still say `OodiCore` for the
then-named package.

Run: `julia --project=. run_spike.jl`. Packages: JLD2 0.6.5, HDF5.jl
0.17.3, Episteme path dependency. Generated files live in `out/`
(gitignored). Compact trees live in `excerpts/`.

**Recommendation: adopt with constraints.**

JLD2 is a good Julia-native encoder for Episteme/AH5 object metadata.
It is not a replacement for Episteme schema, provenance, revision
history, or parallel HDF5. It must not be the only writer of a shared
file unless the layout contract below is followed.

## 1. Julia-native round-trip

Round-tripped through JLD2 into an `.ah5` file:

| Value | Result |
| --- | --- |
| `SemanticNode` with `Box`, `DualLike`, enum, `nothing`, `Dict`, `NamedTuple`, `NodeRef` | lossless |
| `SchemaRef`, `ArchiveObject` fields, `WorkflowHead` | lossless |
| `ArchiveGraph` | lossless by `to_namedtuple` (see equality note) |
| Parametric `Mesh{Float64}`, mutable `Counter`, sparse matrix | lossless |
| Tuples, arrays, unions, pointer | lossless / accepted |
| Shared object (`shared_a === shared_b`) | **identity preserved** |
| Two-node cycle (`cycle.other.other === cycle`) | **identity preserved** |

**Equality note.** `ArchiveObject` / `ArchiveGraph` contain `Vector`
fields, so Julia's default `==` is object identity. A JLD2 reload is a
new object with equal fields. Compare with `to_namedtuple` or add an
explicit fieldwise `==` later. This is a Julia struct rule, not a JLD2
corruption.

**Unsafe / never persist:** MPI communicators, IO handles, provider
clients, live GPU arrays, function closures, tasks. JLD2 will store
`Ptr` and reload it as a null pointer (documented JLD2 behaviour). That
is silent data loss. Episteme should reject those types at the codec
boundary, not rely on JLD2.

**`writeas` / `wconvert` / `rconvert`:** not required for the OodiCore
envelope or the two domain stand-ins (`GeometrySpike.Box`,
`DomainSpike.ModelState`). Use them for handles that must not hit disk,
or for a compact array representation of a domain type.

## 2. Physical HDF5 representation

JLD2 writes a standards-compatible HDF5 file. HDF5.jl can list groups,
datasets, committed datatypes, and numeric payloads.

Observed layout for a JLD2-created file:

```text
/_types/          committed compound datatypes + julia_type attributes
/<dataset>        each JLD2 name; structs are HDF5 compounds
```

Nested names such as `episteme/format` become HDF5 groups. Numeric
arrays are ordinary HDF5 datasets (`H5T_IEEE_F64LE`, `H5T_STD_I64LE`).
Custom structs are compounds that reference `/_types/NNNNN`. Reconstructing
the Julia type needs JLD2 (or equivalent `julia_type` metadata). Field
names and numeric values are still visible to a generic HDF5 reader.

`h5dump` from the HDF5_jll artifact on this machine is linked against
`libmpi.so.12` and failed to start. Inspection used HDF5.jl instead.
That still counts as ordinary HDF5 tooling.

**Reserved by JLD2:** `/_types` is mandatory. Do not let AH5 or HDF5.jl
write that group. Prefer an explicit AH5 root such as `/episteme` for
profile metadata rather than competing with JLD2's root conventions.

## 3. Same-file interoperability (the critical experiment)

Protocol: `open → write → close`, then the other library opens. No
concurrent mixed writers.

| Sequence | Result |
| --- | --- |
| JLD2 create → HDF5.jl `r+` append `/data/field` → JLD2 reread | **pass** |
| HDF5.jl create → JLD2 `r+` nested `packages/...` | write callback returns true; reread `KeyError: packages`. Keys remain `["episteme", "data"]` |
| HDF5.jl create → JLD2 `r+` **top-level** `top = 42` | same: write true, reread `KeyError: top`. Keys remain `["seed"]` |
| HDF5.jl pre-create group `packages` → JLD2 `r+` `packages/sector` | write true, reread `KeyError: sector`. Keys remain `["packages"]` |
| JLD2 create → four alternating HDF5.jl / JLD2 serial cycles | **pass** |
| JLD2 create → HDF5.jl chunked/compressed/extendible `/data/events` → JLD2 reread index | **pass** |
| HDF5.jl delete/overwrite of a JLD2 dataset | overwrite succeeded; JLD2 still opened the file. Treat as a hazard, not a feature |

Every HDF5.jl-first open prints JLD2's warning:

```text
Warning: File likely not written by JLD2. Skipping header verification.
```

That is a header/base-address check, not a nested-path quirk. JLD2 `r+`
on a foreign-created file does not persist even a top-level scalar.
**JLD2 must create the AH5 file.** HDF5.jl may then append ordinary
datasets under `/data`.

HDF5.jl must not modify `/_types` or rewrite JLD2 compound objects.

## 4. Heavy-data path

200k `Float64` plus mesh coordinates/connectivity:

| Path | Size | Write | Read |
| --- | --- | --- | --- |
| JLD2 embeds arrays next to metadata | 2.56 MiB | 0.11 s | 0.03 s |
| JLD2 metadata + HDF5.jl chunked/compressed `/data` | 2.37 MiB | 0.08 + 0.14 s | 0.11 s |

The mixed file stores a logical identity plus a dataset path
(`/data/dense`) instead of a Julia pointer. Heavy values are not
duplicated. This is the intended AH5 split: JLD2 for object/schema
records, HDF5.jl for bulk arrays.

## 5. Parallel HDF5

`HDF5.has_parallel()` is true on this JLL build. This spike did **not**
run `mpiexec`, so parallel I/O is **not qualified**. A serial analogue
(JLD2 metadata, then HDF5.jl chunked vector, then JLD2 reread) passed.
`experiment_status.parallel.passed` is `false` with
`qualified = serial_analogue_only; mpi_collective_write_not_run`.

Credible HPC protocol, to qualify on LUMI:

1. Rank 0 only: JLD2 create/close of `/episteme`, `/objects`, `/_types`.
2. All ranks: `h5open(path, "r+", comm, info)` collective dataset write
   under `/data`.
3. Rank 0 only: JLD2 reopen to read metadata.

Do not run rank-local JLD2 writers against one file. Use module
`cray-hdf5-parallel/1.14.3.5` (or 1.12.2.11) and
`HDF5.API.set_libraries!` if the JLL parallel flag is not the Cray
library. That follow-up is #29-class qualification, not a blocker for
the serial AH5 design.

## 6. Type evolution vs Episteme schema migration

Writing `ModelState` and reading it as `ModelStateV2` via

```julia
typemap = Dict("…ModelState" => JLD2.Upgrade(ModelStateV2))
JLD2.rconvert(::Type{ModelStateV2}, nt::NamedTuple) = ...
```

succeeded. JLD2 loads old fields as a `NamedTuple` and calls `rconvert`.

That answers **how a Julia struct is reconstructed**. It does not answer
**whether the scientific object changed meaning**. Episteme schema
id/version, #41 migration ids, and package namespace stay authoritative.
A JLD2 `Upgrade` may implement an Episteme migration, but it must be
registered as one. Do not infer semantic compatibility from JLD2 type
metadata.

## 7. Missing-package / forensic read

The fixture is written in the spike process, then a **second Julia
process** loads it with only JLD2 and HDF5 (`forensic_load.jl`). It does
not include `types.jl` or OodiCore.

| Mode | Result |
| --- | --- |
| `load` | `JLD2.ReconstructedStatic{:Box,…}` / `ReconstructedStatic{:ModelState,…}` with the stored field values |
| `load(; plain = true)` | `@NamedTuple{width,depth,height}` / `{sites,particles,Sz}` |
| HDF5.jl inspect | `/_types`, compound datasets, field names and numeric dtypes visible |

That is the three-year-old-archive case: original modules are absent.
`ReconstructedStatic` / `plain` NamedTuples are forensic Julia
reconstruction, not an Episteme semantic schema.

Episteme diagnostics to layer on top:

| Situation | Suggested code |
| --- | --- |
| Julia type not in the environment | `:type_unavailable` |
| Episteme schema missing from `/schemas` | `:missing_schema` |
| Schema present but marked migration-required | `:migration_required` |
| Schema unsupported | `:unsupported_schema` |

Generic inspect should use HDF5 group/dataset names and portable envelope
fields first. JLD2 `plain` is a fallback for Julia-native payloads, not
the semantic schema.

## 8. Issue #34 revisited

Do **not** require every `SemanticNode` leaf to be in a strict portable
subset merely to persist it. #12 already allows arbitrary Julia values in
the tree.

Support two explicit capabilities:

1. **Julia-native persistent** — JLD2 round-trips the value in an
   environment that has the type (or `plain`/`typemap`). Default for
   domain payloads and rich semantic-tree leaves.
2. **Portable declarative** — issue #34. Required for interchange,
   generic replay, and archives that must remain meaningful without the
   original package.

Always portable (already plain structs): `ObjectId`, `RevisionId`,
`SchemaRef`, `ArchiveReference`, `ProvenanceRefs`, `ArchiveNamespace`.
Those should also be embedded as Episteme schema data so a reader without
JLD2 can still name the object.

## Candidate layout (pressure-tested)

```text
/episteme/     JLD2 (profile, format version)
/schemas/      JLD2 (semantic schemas)
/revisions/    JLD2 (workflow history)
/objects/      JLD2 (logical object index / envelope records)
/events/       JLD2 or HDF5.jl extendible table
/packages/     JLD2 (package-owned Julia-native objects)
/_types/       JLD2 only
/data/         HDF5.jl only (chunked/compressed/parallel arrays)
```

JLD2 creates the file. HDF5.jl only writes under `/data` (and maybe
extendible `/events` if we choose). `/_types` is JLD2-owned.

## Recommendation

**Adopt with constraints.**

Use JLD2 inside Episteme's later AH5 profile (not as a third package) as the Julia-native codec for
envelope records, schemas, and domain objects that do not need a
portable subset. Use HDF5.jl for bulk arrays, compression, extendible
datasets, and later parallel I/O. Keep Episteme schema/provenance/revision
contracts independent of JLD2 type metadata.

Do not migrate the archive architecture until AH5.jl exists and the
file-creation constraint (JLD2 first) is encoded in its writer.

Machine-generated `experiment_status` distinguishes **completed** from
**passed** / **qualified**. Interop is completed but `passed=false`
(`jld2_created_files_only`). Parallel is completed but `passed=false`
(`serial_analogue_only; mpi_collective_write_not_run`).
