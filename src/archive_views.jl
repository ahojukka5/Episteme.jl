# SPDX-FileCopyrightText: Jukka Aho
# SPDX-License-Identifier: MIT

abstract type AbstractXdmfView end

"""
    XdmfDataset(path, object, object_content; content_id)

A domain-declared binding to an existing primitive numeric dataset. `object`
must identify an immutable revision. `object_content` is its recorded logical
content identity; `content_id` is the canonical identity of this numeric array.
Neither the dataset path nor its visualization role is inferred by Episteme.
"""
struct XdmfDataset
    path::String
    object::ObjectRef
    object_content::ContentId
    content_id::ContentId
    function XdmfDataset(path::AbstractString, object::ObjectRef,
                         object_content::ContentId; content_id::ContentId)
        object.revision_id === nothing && throw(ArgumentError("XDMF requires a pinned object revision"))
        parts = split(String(path),'/')
        startswith(path,"/") && length(parts)>1 && all(p->!isempty(p) && p ∉ (".",".."),parts[2:end]) ||
            throw(ArgumentError("XDMF dataset path must be an absolute canonical HDF path"))
        for value in (path,object.object_id.value,object.revision_id.value,
                      object_content.value,content_id.value)
            _view_text(value)
        end
        new(String(path),object,object_content,content_id)
    end
end

function _view_text(value::AbstractString)
    isvalid(value) && !isempty(value) &&
        all(c->c in ('\t','\n','\r') || 0x20<=Int(c)<=0xd7ff ||
            0xe000<=Int(c)<=0xfffd || 0x10000<=Int(c)<=0x10ffff,value) ||
        throw(ArgumentError("XDMF text must be nonempty valid XML text"))
    String(value)
end

"""An explicit XDMF field association; Face/Edge require domain-declared entity counts."""
struct XdmfAttribute
    name::String
    dataset::XdmfDataset
    center::Symbol
    kind::Symbol
    entities::Union{Nothing,Int}
    function XdmfAttribute(name::String,dataset::XdmfDataset,center::Symbol,
                           kind::Symbol,entities::Union{Nothing,Int})
        center in (:Node,:Cell,:Face,:Edge,:Grid) || throw(ArgumentError("unsupported XDMF association $center"))
        kind in (:Scalar,:Vector,:Tensor,:Tensor6,:Matrix) || throw(ArgumentError("unsupported XDMF attribute kind $kind"))
        entities===nothing || entities>0 || throw(ArgumentError("entity count must be positive"))
        center in (:Face,:Edge) && entities===nothing && throw(ArgumentError("Face/Edge association requires an entity count"))
        new(_view_text(name),dataset,center,kind,entities)
    end
end
function XdmfAttribute(name,dataset::XdmfDataset; center=:Node,kind=:Scalar,entities=nothing)
    entities===nothing || (entities isa Integer && entities>0) || throw(ArgumentError("entity count must be positive"))
    XdmfAttribute(_view_text(name),dataset,center,kind,entities===nothing ? nothing : Int(entities))
end

"""A zero-based subset. Face/Edge use cell indices plus cell-local entity indices."""
struct XdmfSet
    name::String
    kind::Symbol
    indices::XdmfDataset
    cells::Union{Nothing,XdmfDataset}
    function XdmfSet(name::String,kind::Symbol,indices::XdmfDataset,
                     cells::Union{Nothing,XdmfDataset})
        kind in (:Node,:Cell,:Face,:Edge) || throw(ArgumentError("unsupported XDMF set kind $kind"))
        (kind in (:Face,:Edge)) == (cells!==nothing) || throw(ArgumentError("Face/Edge sets require cell indices; Node/Cell sets do not"))
        new(_view_text(name),kind,indices,cells)
    end
end
function XdmfSet(name,indices::XdmfDataset;kind=:Cell,cells=nothing)
    XdmfSet(_view_text(name),kind,indices,cells)
end

const _XDMF_ARITY = Dict(:Triangle=>3,:Quadrilateral=>4,:Tetrahedron=>4,
    :Pyramid=>5,:Wedge=>6,:Hexahedron=>8,:Polyvertex=>1,:Polyline=>2)

"""An explicitly projected unstructured grid over existing archive arrays."""
struct XdmfGrid <: AbstractXdmfView
    name::String
    geometry::XdmfDataset
    topology::XdmfDataset
    geometry_type::Symbol
    topology_type::Symbol
    cells::Int
    attributes::Tuple{Vararg{XdmfAttribute}}
    sets::Tuple{Vararg{XdmfSet}}
    time::Union{Nothing,Float64}
    function XdmfGrid(name::String,geometry::XdmfDataset,topology::XdmfDataset,
                      geometry_type::Symbol,topology_type::Symbol,cells::Int,
                      attributes::Tuple{Vararg{XdmfAttribute}},sets::Tuple{Vararg{XdmfSet}},
                      time::Union{Nothing,Float64})
        geometry_type in (:XY,:XYZ) || throw(ArgumentError("geometry must be XY or XYZ"))
        haskey(_XDMF_ARITY,topology_type) || topology_type===:Mixed || throw(ArgumentError("unsupported topology $topology_type"))
        cells>0 || throw(ArgumentError("cell count must be positive"))
        time===nothing || isfinite(time) || throw(ArgumentError("time must be finite"))
        length(unique(a.name for a in attributes))==length(attributes) || throw(ArgumentError("attribute names must be unique"))
        length(unique(s.name for s in sets))==length(sets) || throw(ArgumentError("set names must be unique"))
        new(_view_text(name),geometry,topology,geometry_type,topology_type,cells,attributes,sets,time)
    end
end
function XdmfGrid(name,geometry::XdmfDataset,topology::XdmfDataset;
                  geometry_type=:XYZ,topology_type=:Triangle,cells::Integer,
                  attributes=(),sets=(),time=nothing)
    time===nothing || (time isa Real && isfinite(time)) || throw(ArgumentError("time must be finite"))
    attrs=Tuple(attributes); subsets=Tuple(sets)
    XdmfGrid(_view_text(name),geometry,topology,geometry_type,topology_type,Int(cells),
        attrs,subsets,time===nothing ? nothing : Float64(time))
end

"""Spatial collections represent mixed blocks and nested levels; Temporal children carry time."""
struct XdmfCollection <: AbstractXdmfView
    name::String
    kind::Symbol
    children::Tuple{Vararg{AbstractXdmfView}}
    time::Union{Nothing,Float64}
    function XdmfCollection(name::String,kind::Symbol,
                            children::Tuple{Vararg{AbstractXdmfView}},
                            time::Union{Nothing,Float64})
        kind in (:Spatial,:Temporal) || throw(ArgumentError("collection must be Spatial or Temporal"))
        isempty(children) && throw(ArgumentError("collection must not be empty"))
        length(unique(c.name for c in children))==length(children) || throw(ArgumentError("child grid names must be unique"))
        time===nothing || isfinite(time) || throw(ArgumentError("time must be finite"))
        if kind===:Temporal
            all(c->c.time!==nothing,children) || throw(ArgumentError("every temporal child requires time"))
            times=[c.time for c in children]
            issorted(times) && length(unique(times))==length(times) || throw(ArgumentError("temporal samples must have strictly increasing times"))
        end
        new(_view_text(name),kind,children,time)
    end
end
function XdmfCollection(name,children;kind=:Spatial,time=nothing)
    children=Tuple(children)
    time===nothing || (time isa Real && isfinite(time)) || throw(ArgumentError("time must be finite"))
    XdmfCollection(_view_text(name),kind,children,time===nothing ? nothing : Float64(time))
end

to_namedtuple(d::XdmfDataset) = (path=d.path,object_id=d.object.object_id.value,
    revision_id=d.object.revision_id.value,object_content_id=d.object_content.value,
    dataset_content_id=d.content_id.value)
to_namedtuple(a::XdmfAttribute) = (name=a.name,dataset=to_namedtuple(a.dataset),
    center=a.center,kind=a.kind,entities=a.entities)
to_namedtuple(s::XdmfSet) = (name=s.name,kind=s.kind,indices=to_namedtuple(s.indices),
    cells=s.cells===nothing ? nothing : to_namedtuple(s.cells))
to_namedtuple(g::XdmfGrid) = (name=g.name,geometry=to_namedtuple(g.geometry),
    topology=to_namedtuple(g.topology),geometry_type=g.geometry_type,
    topology_type=g.topology_type,cells=g.cells,attributes=map(to_namedtuple,g.attributes),
    sets=map(to_namedtuple,g.sets),time=g.time)
to_namedtuple(c::XdmfCollection) = (name=c.name,kind=c.kind,
    children=map(to_namedtuple,c.children),time=c.time)

"""Domain packages extend this generic with their projection recipe; no recipe is inferred."""
xdmf_projection(object) = throw(ArgumentError("missing_xdmf_projection: the owning domain must provide a recipe for $(typeof(object))"))
xdmf_projection(view::AbstractXdmfView) = view

struct XdmfViewInspection <: AbstractValidationReport
    archive::String
    archive_id::Union{Nothing,String}
    datasets::Dict{String,NamedTuple}
    diagnostics::Vector{DiagnosticMessage}
end
Base.isvalid(v::XdmfViewInspection) = isempty(v.diagnostics)
readiness(v::XdmfViewInspection,t::PipelineTarget) = ReadinessReport(
    :xdmf_view,t,isvalid(v),copy(v.diagnostics),(archive_id=v.archive_id,))

_view_datasets(g::XdmfGrid) = [g.geometry,g.topology,[a.dataset for a in g.attributes]...,
    [s.indices for s in g.sets]...,[s.cells for s in g.sets if s.cells!==nothing]...]
_view_datasets(c::XdmfCollection) = reduce(vcat,_view_datasets.(c.children))

"""Read-only archive qualification. Load JLD2 to activate numeric dataset inspection."""
inspect_xdmf_view(path,view::AbstractXdmfView) = throw(_missing_jld2_error("inspect_xdmf_view"))
inspect_xdmf_view(path,object) = inspect_xdmf_view(path,xdmf_projection(object))
"""Write metadata only, referencing qualified archive arrays; never modify the archive."""
write_xdmf_view(path,archive,view::AbstractXdmfView) = throw(_missing_jld2_error("write_xdmf_view"))
write_xdmf_view(path,archive,object) = write_xdmf_view(path,archive,xdmf_projection(object))

_view_escape(s) = replace(string(s),'&'=>"&amp;",'<' =>"&lt;",'>' =>"&gt;",
    '"'=>"&quot;",'\''=>"&apos;",'\n'=>"&#10;",'\r'=>"&#13;",'\t'=>"&#9;")
function _view_info(io,name,value)
    println(io,"<Information Name=\"",_view_escape(name),"\" Value=\"",_view_escape(value),"\"/>")
end
function _view_item(io,d::XdmfDataset,inspection,archive)
    info=inspection.datasets[d.path]
    print(io,"<DataItem Format=\"HDF\" Dimensions=\"",join(info.shape,' '),
        "\" NumberType=\"",info.number_type,"\" Precision=\"",info.precision,"\">")
    println(io,_view_escape(archive),":",_view_escape(d.path),"</DataItem>")
end
function _view_grid(io,g::XdmfGrid,inspection,archive)
    println(io,"<Grid Name=\"",_view_escape(g.name),"\" GridType=\"Uniform\">")
    g.time===nothing || println(io,"<Time Value=\"",g.time,"\"/>")
    println(io,"<Topology TopologyType=\"",g.topology_type,"\" NumberOfElements=\"",g.cells,
        g.topology_type in (:Polyvertex,:Polyline) ? "\" NodesPerElement=\"$(_XDMF_ARITY[g.topology_type])" : "","\">")
    _view_item(io,g.topology,inspection,archive);println(io,"</Topology>")
    println(io,"<Geometry GeometryType=\"",g.geometry_type,"\">")
    _view_item(io,g.geometry,inspection,archive);println(io,"</Geometry>")
    for a in g.attributes
        println(io,"<Attribute Name=\"",_view_escape(a.name),"\" Center=\"",a.center,"\" AttributeType=\"",a.kind,"\">")
        _view_item(io,a.dataset,inspection,archive);println(io,"</Attribute>")
    end
    for s in g.sets
        println(io,"<Set Name=\"",_view_escape(s.name),"\" SetType=\"",s.kind,"\">")
        s.cells===nothing || _view_item(io,s.cells,inspection,archive)
        _view_item(io,s.indices,inspection,archive);println(io,"</Set>")
    end
    for d in unique(_view_datasets(g))
        _view_info(io,"DatasetIdentity:"*d.path,canonical_content_id(to_namedtuple(d)).value)
        _view_info(io,"ObjectId:"*d.path,d.object.object_id.value)
        _view_info(io,"RevisionId:"*d.path,d.object.revision_id.value)
        _view_info(io,"ObjectContentId:"*d.path,d.object_content.value)
        _view_info(io,"DatasetContentId:"*d.path,d.content_id.value)
    end
    println(io,"</Grid>")
end
function _view_grid(io,c::XdmfCollection,inspection,archive)
    println(io,"<Grid Name=\"",_view_escape(c.name),"\" GridType=\"Collection\" CollectionType=\"",c.kind,"\">")
    c.time===nothing || println(io,"<Time Value=\"",c.time,"\"/>")
    for child in c.children; _view_grid(io,child,inspection,archive); end
    println(io,"</Grid>")
end
