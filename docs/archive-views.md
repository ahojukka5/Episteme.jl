# Lightweight archive views

An XMF file is a disposable projection of an AH5 archive, not another archive.
`write_xdmf_view` emits XDMF metadata referring to existing numeric datasets.
It never rewrites the archive or creates a second heavy-data file. Deleting and
regenerating a view preserves the archive's bytes, identity, and provenance.
Several views can share the same arrays.

Episteme owns the generic descriptors, validation, and metadata writer. A domain
owns its codec and projection recipe: which arrays represent coordinates,
connectivity, fields, levels, time samples, or subsets. Episteme does not infer a
mesh from arbitrary objects or export nonvisual scientific metadata as fields.

## Explicit projection contract

Each `XdmfDataset` binds an absolute in-file dataset path to an immutable
`ObjectRef`, its recorded object `ContentId`, and the numeric array's own
`canonical_content_id`. The domain declares the relationship between the array
and object. Inspection verifies both identities against the archive history and
array contents; it does not infer scientific membership from a filename.

```julia
using Episteme, JLD2

# The domain codec has already stored these arrays and the object's history.
# Julia coordinates are component-by-node; connectivity is node-by-cell.
# Connectivity and subset indices must already be zero based.
points = XdmfDataset("/data/points", object_ref, object_content;
    content_id=canonical_content_id(coordinates))
cells = XdmfDataset("/data/cells", object_ref, object_content;
    content_id=canonical_content_id(connectivity))
values = XdmfDataset("/data/values", object_ref, object_content;
    content_id=canonical_content_id(nodal_values))

view = XdmfGrid("surface", points, cells; cells=size(connectivity, 2),
    topology_type=:Triangle, geometry_type=:XYZ,
    attributes=(XdmfAttribute("value", values; center=:Node),))
inspection = inspect_xdmf_view("model.ah5", view)
isvalid(inspection) || error(inspection.diagnostics)
write_xdmf_view("surface.xmf", "model.ah5", view)
```

A domain may extend `Episteme.xdmf_projection(x::ItsOwnType)` to return these
descriptors. `inspect_xdmf_view` and `write_xdmf_view` accept such an object and
call its recipe. A missing recipe fails explicitly. Descriptors hold metadata
and identities, not array copies or opaque callbacks. `to_namedtuple(view)` is
the portable recipe representation; its canonical content identity is emitted
with the archive, object, revision, and dataset identities as XDMF `Information`.

The archive must have a compatible in-file AH5 profile and valid authoritative
state history. Missing arrays, conflicting bindings, stale identities, invalid
connectivity, incompatible field shapes, and unsupported physical layouts give
stable `xdmf_*` diagnostic codes. No output is created for an invalid projection.
Output is published only after qualification and never replaces an existing
file. References are relative to the XMF file, allowing archive and views to
move together. Treat the archive as immutable while inspecting or writing.

## Grids, associations, and collections

`XdmfGrid` supports `:XY` and `:XYZ` geometry and unstructured `:Polyvertex`,
`:Polyline` (two nodes), `:Triangle`, `:Quadrilateral`, `:Tetrahedron`,
`:Pyramid`, `:Wedge`, `:Hexahedron`, or `:Mixed` topology. Mixed streams use the
standard zero-based XDMF codes: variable-length polyvertices, polylines, and
polygons, and fixed-arity codes 4–9. Polyhedra and higher-order topologies are
rejected rather than assigned guessed connectivity.

`XdmfAttribute` declares `center=:Node`, `:Cell`, `:Face`, `:Edge`, or `:Grid`;
point-associated fields use `:Node`. Supported kinds are `:Scalar`, `:Vector`,
`:Tensor`, `:Tensor6`, and `:Matrix`. Scalars have one value per entity; other
fields use component-by-entity matrices. Vectors match the geometry dimension,
tensors have nine components, and symmetric tensors have six. Face and edge
attributes require an explicit `entities` count from the domain. Their ordering
and meaning remain the domain's responsibility; reader support can vary.

`XdmfSet` declares a node/cell subset using one zero-based index vector. Face
and edge sets require two vectors: `cells` contains global cell indices and
`indices` contains cell-local entity indices. Inspection checks global and local
bounds. A surface represented as its own mesh is a separate grid with explicit
surface connectivity, not a fabricated volume field.

`XdmfCollection(name, children; kind=:Spatial)` groups mixed blocks or named
hierarchy levels and may be nested. `kind=:Temporal` requires strictly increasing
finite timestamps on every child. A timestamp can belong to a spatial collection
for a multiblock time sample. Different samples or blocks may reference the same
geometry and different field arrays without duplicating either.

## Physical layout and optional dependencies

File inspection and writing activate only after `using JLD2`. The descriptors
remain available with Episteme's stdlib-only dependencies. There is no mandatory
HDF5.jl, XML library, renderer, or Python dependency.

The JLD2 runtime admits only existing, nonempty rank-one/two primitive numeric
datasets readable as HDF arrays: Float32/64 and signed/unsigned integers of
8, 16, 32, or 64 bits. Physical dimensions must match reversed Julia dimensions,
with matching scalar widths. Standard deflate, shuffle, and Fletcher32 filters
are admitted; plugin filters are rejected. Native serialized objects, references,
complex arrays, and higher-rank arrays are rejected. A domain with an unsupported
layout must provide an appropriate numeric codec; the view writer does not
silently materialize a heavy shadow copy. Inspection reads each selected array
once to verify its content and indices; it is not a streaming bulk-I/O API.

These conventions follow the [XDMF model and format](https://www.xdmf.org/index.php/XDMF_Model_and_Format)
and [JLD2's HDF compatibility](https://juliaio.github.io/JLD2.jl/stable/hdf5compat/).
An eventual optional bulk-HDF codec can reuse the descriptors without changing
domain recipes.

## Local qualification

The Julia tests use independently constructed numeric fixtures and check
read-only generation, regeneration, identities, mixed topology, associations,
collections, subsets, and rejected projections. Run in a prepared environment
with Episteme path-developed and JLD2/Test available:

```sh
julia --project=/path/to/private-env test/archive_views.jl /path/to/new-fixtures
```

An optional independent Python check opens the unmodified generated XMF files
with VTK's `vtkXdmfReader` and reads their datasets with h5py:

```sh
python test/archive_views_reader.py /path/to/new-fixtures
```

That check requires h5py and VTK outside the Julia environment. It verifies exact
coordinates, triangle/quad connectivity, node/cell fields, a cell subset, nested
spatial levels, and changing fields at two time samples, and checks archive byte
preservation. Face/edge associations have contract tests but are not claimed to
be supported by that reader qualification. Other readers may support different
subsets of XDMF. View readiness establishes archive/layout validity, not universal
visualizer compatibility.
