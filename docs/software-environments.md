# Software environment provenance

`SoftwareEnvironment` records the software facts supplied by a domain package
or application. It never inspects the current machine, installs dependencies,
or infers scientific payload schema compatibility from package versions.
Capture facts at execution time; importing an old result must preserve gaps.

```julia
using Episteme, JLD2

library = SoftwareComponent("library", "NativeLibrary";
    version="2.0.0", source_identity="build:recorded-library-build",
    dirty=false, dependencies=(), features=())
application = SoftwareComponent("application", "Application";
    version="1.0.0", source_identity="git:" * repeat("a", 40),
    repository="https://example.org/application.git", dirty=false,
    dependencies=("library",), features=("MPIExt",))
environment = SoftwareEnvironment((application, library);
    julia_version="1.12.7", julia_build="recorded-runtime-build", features=())
registry = SoftwareEnvironmentRegistry((environment,))

run = RunRecord(RunId("toy-run"); software_environment=environment.id)
graph = ArchiveGraph(ArchiveObject[]; runs=[run])
write_run_archive("toy.ah5", graph; software_environments=registry)

view = inspect_archive("toy.ah5", SoftwareEnvironmentRegistry)
recorded = find_software_environment(view.registry, environment.id)
to_namedtuple(recorded) # Includes the dependency graph and recorded identities.
validate(recorded)     # Reports unknown facts and modified source.
```

The source/build values in this example are placeholders. Callers supply full
actual commit, release-tree or build identities. Released packages can record
a tree identity without a repository checkout. Native libraries and backends
use the same component representation. A Julia package can additionally supply
its `uuid`. Dependency ids must resolve within the recorded graph.

## Identity and sharing

Components, dependency ids and feature flags are normalized independently of
input order. The environment id hashes the normalized record, including runtime
facts. Different commits, dirty states or material loaded features produce
different ids even when the semantic package version is unchanged. The hash is
independent of the archive path and the machine reading it.

Records are immutable; constructing them copies mutable input collections.
`SoftwareEnvironmentRegistry` stores an identical environment once. Many
`RunRecord`s can reference its id. Object revision envelopes and staged objects
reference it through `ProvenanceRefs(software_environment=environment.id)`.
These references describe software provenance, independently of `SchemaRef`.

`nothing` means not recorded. For dependency and feature collections, `()`
means a known empty set. Validation warns about unknown versions, source
identities, dirty states, dependency sets, runtime facts and features. Modified
source also warns that its base identity does not reconstruct the changes.
An id verifies the recorded facts; it does not prove they accurately describe
the software that executed or contain enough information to reproduce a run.

## AH5 storage and inspection

Pass `software_environments=registry` to the base, state, run, event, integrity
or capsule archive writer. Every referenced environment must be present when
a registry is supplied. The optional `:software_environment_records` feature
stores records at `episteme/software_environments`. Custom profile roots must
not overlap that reserved path. Capsule writing preserves the supplied records.

The specialized inspector reads plain JLD2 metadata and reconstructs identities
from their content. Altered records, unsupported record formats and missing
referenced ids produce invalid inspection results. It does not consult installed
domain packages. Portable `to_namedtuple` / `from_namedtuple` restoration applies
the same content identity checks outside AH5.

An old archive without this optional feature remains inspectable. Its software
inspection has `feature_declared=false`, `registry=nothing` and an explicit
unknown-provenance diagnostic. An empty supplied registry is distinct from an
absent registry. No software source trees, runtimes or drivers are embedded.
AH5 file access requires explicit `using JLD2`; record construction and portable
restoration require only Episteme's stdlib dependencies.
