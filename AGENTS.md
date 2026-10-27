# AGENTS.md — Episteme.jl

> Process rules come from the latest approved
> [OodiHandbook](https://github.com/ahojukka5/OodiHandbook) tag (AUTH-007).
> Start with its `guides/local-development.qmd` and `guides/contributing.qmd`.
> This file adds only this repository's facts (ENG-001, ENG-028).

Commit scopes, hooks and never-commit paths are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## 1. What this package is

`Episteme.jl` is the semantic runtime and persistent scientific backbone for
composable, reproducible, and eventually autonomous research. It is the
renamed `OodiCore.jl`. There is no separate OodiCore repository. Issue
and pull-request numbers from that name are Episteme.jl numbers.

Domain packages own scientific payloads and operation semantics. Episteme owns
the shared semantics, schemas/contracts, identities and history vocabulary,
the orchestration protocol, and JLD2-backed AH5 persistence.

The accepted v1 product is `Episteme.jl = semantics + schemas +
history/provenance + orchestration protocol + JLD2-backed AH5 persistence`.

The JLD2-backed `.ah5` profile (`write_archive` / `inspect_archive`) is in
this package, behind the `episteme_jld2_ext` package extension: the archive API
becomes available when the caller runs `using JLD2`. HDF5.jl remains later
optional extension work for direct/bulk/parallel HDF5 needs.

The current archive contract is
[`docs/archive-ownership.md`](docs/archive-ownership.md) and
[`docs/archive-profile.md`](docs/archive-profile.md). The historical
architecture study and the JLD2/AH5 spike are not stored in this
package.

## 2. What it owns

Episteme owns the common introspection generics `report(x)`, `validate(x)`
and `readiness(x, target)`. They are declared here so domain packages extend the same functions instead of
creating locally scoped lookalikes.

It also owns shared, domain-neutral supporting types and protocols:

- reports and diagnostics (`DiagnosticMessage`, `ValidationReport`, etc.),
- the generic semantic tree (`SemanticNode`, `NodeRef`),
- local declarative node schemas (`NodeSchema`, `AttributeSchema`,
  `ValidationRule`, `NodeValidationRule`),
- opaque scripting contracts (`script_node`),
- scientific-archive identities, references, schema-version vocabulary,
  portable document envelopes (`PortableSemanticDocument` capture),
  provenance/history records, the durable run/commit/restart contract
  (status, staging, write phases, restart refs), and the event timeline /
  optional log-stream records.

Shared infrastructure kinds use the `:episteme` / `episteme/*` namespace.
Domain kinds stay in the namespace of the domain package that owns them.

These facilities must remain domain-neutral. Episteme may understand generic
structural properties such as a finite positive scalar, but it must not know
the scientific meaning of a package-specific model, discretization, solver,
experiment, or analysis object.

## 3. Integrating domain packages

Direct Julia APIs stay first-class; a declarative frontend lowers to the same
domain-owned implementation
([`docs/declarative-contracts.md`](docs/declarative-contracts.md#direct-and-declarative-apis-are-first-class)).
Domain packages import and extend Episteme's generics rather than shadowing
them, or participate through consumer-owned ports without an Episteme
dependency (SWE-013). Worked examples for reports, node schemas, script
contracts and custom validation rules are in
[`docs/notes/domain-integration.md`](docs/notes/domain-integration.md).

## 4. Dependencies

Dependencies must support Episteme's cross-domain role rather than pull domain
science into the shared layer.

Do not add domain-specific simulation, geometry, meshing, solver, accelerator,
visualization, device, or model-serving stacks merely because one consumer uses
them. JLD2 is part of the accepted persistence story, but it is a `[weakdeps]`
package: `[deps]` is stdlib only (`Dates`, `SHA`, `UUIDs`), and every AH5 entry
point that opens a file lives in `ext/episteme_jld2_ext*.jl` with a fail-closed
stub in `src/archive_persistence.jl`. Keep it that way. A downstream package
that only wants the shared semantics must not inherit the archive track's
dependency weight. HDF5.jl and MPI remain optional future extensions for bulk
and parallel archive I/O.

Dependencies must flow one way: domain packages may depend on Episteme;
Episteme must not depend on domain packages.

## 5. Do not add domain logic

Episteme must not contain domain-specific scientific or numerical semantics.
Keep these concerns in the package that owns the domain:

- physical models, equations, constitutive laws, and scientific assumptions,
- geometry, CAD, meshing, and topology algorithms,
- discretization and numerical methods such as FEM, finite-volume, spectral,
  or particle formulations,
- linear, nonlinear, eigensystem, time-integration, and optimization solvers,
- quantum-computing algorithms, device semantics, and experiment logic,
- machine-learning or model-serving algorithms and policies,
- rendering, visualization, and domain-specific export logic,
- integrations whose semantics belong to a particular external scientific
  library or service.

Local schema validation is in scope only when the rule is structurally generic:
required fields, portable value kinds, finiteness, ranges, non-empty values,
enums, node-local cross-field orderings, and similarly local invariants.

Cross-object scientific equations and constraints belong to the domain package
that owns their meaning and to its own evaluator/planner when needed.

## 6. Keep shared types structured, serializable, and readable

Any new shared type should:

- be a plain immutable `struct` with simple fields when practical,
- avoid opaque function closures when a symbolic/introspectable representation
  is possible,
- have a `to_namedtuple` method when appropriate,
- remain useful to humans and agents without inspecting internal Julia state.

Validation rules in particular are data (`kind + parameters`), not closures, so
agents and tool layers can inspect the same rules the runtime enforces.

## 7. Introspection is read-only; mutation uses `!`

`report`, `validate`, and `readiness` must never mutate the object they inspect.
They answer questions; they do not change state. A function that mutates its
argument ends in `!` (`guides/coding-julia.qmd`, `guides/naming.qmd`).

## 8. Out of scope for now

`summary`, `diagnose`, `explain`, `suggest_fixes`, `provenance`, `artifacts`
and `repair!` are outside the current contract, as are `branch!` / `rerun!`,
`.ah5` writes from the in-memory `execute!` family, distributed scheduling,
implicit script execution and sandboxing; the full list is in
[`docs/notes/domain-integration.md`](docs/notes/domain-integration.md#out-of-scope-for-now).
If a task needs one, keep only the cross-domain representation and protocol
in Episteme and the scientific semantics in the owning domain package.

## 9. Tests and manual

- `pkg> test Episteme` runs `test/runtests.jl`: first
  `test/archive_without_jld2.jl`, then the rest with JLD2 loaded.
- `julia --project=docs docs/make.jl` builds the manual (instantiate first).
  It fails unless every `docs/*.md` is in `CHAPTERS`; other notes go in
  `docs/notes/`.
