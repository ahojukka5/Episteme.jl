# SPDX-FileCopyrightText: Jukka Aho
# SPDX-License-Identifier: MIT

const _VIEW_NUMERIC = (Float32,Float64,Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64)
const _VIEW_MIXED_ARITY = Dict(4=>3,5=>4,6=>4,7=>5,8=>6,9=>8)
const _VIEW_ENTITY_COUNTS = Dict(:Polyvertex=>(0,0),:Polyline=>(0,1),
    :Triangle=>(1,3),:Quadrilateral=>(1,4),:Tetrahedron=>(4,6),
    :Pyramid=>(5,8),:Wedge=>(5,9),:Hexahedron=>(6,12))
const _VIEW_MIXED_TYPES = Dict(4=>:Triangle,5=>:Quadrilateral,
    6=>:Tetrahedron,7=>:Pyramid,8=>:Wedge,9=>:Hexahedron)

function _view_problem!(diagnostics,code,message;kwargs...)
    push!(diagnostics,Episteme.error_diagnostic(code,message;kwargs...))
end

function _qualify_view_dataset(file,ref,objects,diagnostics)
    object=findfirst(o->o.object_id==ref.object.object_id &&
        o.revision_id==ref.object.revision_id,objects)
    if object===nothing || objects[object].content_id!=ref.object_content
        _view_problem!(diagnostics,:xdmf_object_identity_mismatch,
            "Requested object/revision/content identity is not in archive history";path=ref.path)
        return nothing
    end
    key=ref.path[2:end]
    if !haskey(file,key)
        _view_problem!(diagnostics,:xdmf_dataset_missing,"Requested dataset is absent";path=ref.path)
        return nothing
    end
    dataset=JLD2.get_dataset(file,key)
    if !(dataset.datatype isa Union{JLD2.FixedPointDatatype,JLD2.FloatingPointDatatype}) ||
            dataset.dataspace===nothing || dataset.dataspace.dataspace_type!=JLD2.DS_SIMPLE
        _view_problem!(diagnostics,:xdmf_unsupported_dataset_layout,
            "XDMF requires a simple primitive numeric dataset, not serialized objects/references";path=ref.path)
        return nothing
    end
    if any(f->JLD2.Filters.filterid(f) ∉ (1,2,3),dataset.filters)
        _view_problem!(diagnostics,:xdmf_unsupported_dataset_filter,
            "Dataset requires a nonstandard HDF5 filter";path=ref.path)
        return nothing
    end
    values=file[key]
    if !(values isa Array) || eltype(values) ∉ _VIEW_NUMERIC || !(1<=ndims(values)<=2) || isempty(values)
        _view_problem!(diagnostics,:xdmf_unsupported_dataset_layout,
            "XDMF requires a nonempty rank-one/two array of standard numeric scalars";path=ref.path)
        return nothing
    end
    shape=Tuple(Int.(dataset.dataspace.dimensions))
    if shape!=reverse(size(values)) || Int(dataset.datatype.size)!=sizeof(eltype(values))
        _view_problem!(diagnostics,:xdmf_unsupported_dataset_layout,
            "Physical dataset layout differs from the numeric logical array";path=ref.path)
        return nothing
    end
    if Episteme.canonical_content_id(values)!=ref.content_id
        _view_problem!(diagnostics,:xdmf_dataset_content_mismatch,
            "Numeric dataset does not match its declared content identity";path=ref.path)
        return nothing
    end
    number_type=eltype(values)<:AbstractFloat ? "Float" : eltype(values)<:Signed ? "Int" : "UInt"
    return (info=(shape=shape,number_type=number_type,precision=sizeof(eltype(values))),values=values)
end

function _qualify_grid(g::Episteme.XdmfGrid,data,diagnostics)
    all(d->haskey(data,d.path),Episteme._view_datasets(g)) || return
    coordinates=data[g.geometry.path].values
    dimension=g.geometry_type===:XY ? 2 : 3
    if ndims(coordinates)!=2 || size(coordinates,1)!=dimension || !all(isfinite,coordinates)
        _view_problem!(diagnostics,:xdmf_geometry_shape,"Geometry must be a finite component-by-node matrix";grid=g.name)
        return
    end
    nodes=size(coordinates,2)
    topology=data[g.topology.path].values
    integer_indices(a)=eltype(a)<:Integer && all(x->0<=x<nodes,a)
    entity_counts=Tuple{Int,Int}[]
    if g.topology_type===:Mixed
        valid=ndims(topology)==1 && eltype(topology)<:Integer
        index=1; cells=0
        while valid && index<=length(topology)
            code=topology[index]; index+=1
            if code in (1,2,3)
                valid=index<=length(topology)
                valid || break
                arity=Int(topology[index]);index+=1
                valid=arity>=(code==1 ? 1 : code==2 ? 2 : 3)
                push!(entity_counts,code==1 ? (0,0) : code==2 ? (0,arity-1) : (1,arity))
            else
                arity=get(_VIEW_MIXED_ARITY,code,0)
                valid=arity>0
                valid && push!(entity_counts,_VIEW_ENTITY_COUNTS[_VIEW_MIXED_TYPES[code]])
            end
            valid &= arity<=length(topology)-index+1
            valid || break
            valid=integer_indices(view(topology,index:index+arity-1))
            index+=arity;cells+=1
        end
        valid &= cells==g.cells && index==length(topology)+1
    else
        valid=size(topology)==(Episteme._XDMF_ARITY[g.topology_type],g.cells) && integer_indices(topology)
        entity_counts=fill(_VIEW_ENTITY_COUNTS[g.topology_type],g.cells)
    end
    topology_valid=valid
    valid || _view_problem!(diagnostics,:xdmf_topology_shape,
        "Topology must have the declared cell arity/count and valid zero-based node indices";grid=g.name)
    for attribute in g.attributes
        values=data[attribute.dataset.path].values
        count=attribute.center===:Node ? nodes : attribute.center===:Cell ? g.cells :
            attribute.center===:Grid ? 1 : attribute.entities
        components=attribute.kind===:Scalar ? 1 : attribute.kind===:Vector ? dimension :
            attribute.kind===:Tensor ? 9 : attribute.kind===:Tensor6 ? 6 : nothing
        correct=attribute.kind===:Scalar ? size(values)==(count,) || size(values)==(1,count) :
            attribute.kind===:Matrix ? ndims(values)==2 && size(values,2)==count : size(values)==(components,count)
        correct || _view_problem!(diagnostics,:xdmf_attribute_shape,
            "Attribute shape does not match its declared association and kind";grid=g.name,attribute=attribute.name)
    end
    for subset in g.sets
        indices=data[subset.indices.path].values
        limit=subset.kind===:Node ? nodes : subset.kind===:Cell ? g.cells : nothing
        valid=ndims(indices)==1 && eltype(indices)<:Integer && all(x->x>=0 && (limit===nothing || x<limit),indices)
        if subset.cells!==nothing
            cells=data[subset.cells.path].values
            valid &= size(cells)==size(indices) && eltype(cells)<:Integer && all(x->0<=x<g.cells,cells)
            valid &= topology_valid
            if valid
                component=subset.kind===:Face ? 1 : 2
                valid=all(i->indices[i]<entity_counts[Int(cells[i])+1][component],eachindex(indices))
            end
        end
        valid || _view_problem!(diagnostics,:xdmf_subset_indices,
            "Subset indices must have valid global and cell-local entity bounds";grid=g.name,set=subset.name)
    end
end
function _qualify_grid(c::Episteme.XdmfCollection,data,diagnostics)
    for child in c.children; _qualify_grid(child,data,diagnostics); end
end

function Episteme.inspect_xdmf_view(path::AbstractString,view::Episteme.AbstractXdmfView)
    diagnostics=Episteme.DiagnosticMessage[]
    metadata=Dict{String,NamedTuple}()
    archive_id=nothing
    try
        profile=Episteme.inspect_archive(path)
        if !isvalid(Episteme.validate(profile))
            _view_problem!(diagnostics,:xdmf_invalid_archive,"XDMF requires a compatible in-file AH5 profile")
        else
            archive_id=profile.profile.archive_id
            Episteme._view_text(archive_id)
            history=Episteme.inspect_archive(path,Episteme.ArchiveStateHistory)
            if !history.feature_declared || !isvalid(history) || history.state===nothing
                _view_problem!(diagnostics,:xdmf_missing_object_history,
                    "XDMF identity binding requires authoritative archive object/revision history")
            else
                data=Dict{String,NamedTuple}()
                refs=Dict{String,Episteme.XdmfDataset}()
                JLD2.jldopen(path,"r";plain=true) do file
                    for ref in Episteme._view_datasets(view)
                        if haskey(refs,ref.path)
                            Episteme.to_namedtuple(refs[ref.path])==Episteme.to_namedtuple(ref) ||
                                _view_problem!(diagnostics,:xdmf_conflicting_dataset_binding,
                                    "One physical dataset has conflicting identity bindings";path=ref.path)
                            continue
                        end
                        refs[ref.path]=ref
                        qualified=_qualify_view_dataset(file,ref,history.state.objects,diagnostics)
                        qualified===nothing && continue
                        data[ref.path]=qualified
                        metadata[ref.path]=qualified.info
                    end
                end
                _qualify_grid(view,data,diagnostics)
            end
        end
    catch exception
        exception isa InterruptException && rethrow()
        _view_problem!(diagnostics,:xdmf_inspection_failed,sprint(showerror,exception))
    end
    Episteme.XdmfViewInspection(String(path),archive_id,metadata,diagnostics)
end

function Episteme.write_xdmf_view(path::AbstractString,archive::AbstractString,
                                 view::Episteme.AbstractXdmfView)
    (ispath(path) || islink(path)) && throw(ArgumentError("XDMF output already exists: $path"))
    abspath(path)==abspath(archive) && throw(ArgumentError("XDMF output must differ from its archive"))
    relative=relpath(abspath(archive),dirname(abspath(path)))
    Sys.iswindows() && (relative=replace(relative,'\\'=>'/'))
    occursin(':',relative) && throw(ArgumentError("XDMF archive reference cannot contain a colon"))
    Episteme._view_text(relative)
    inspection=Episteme.inspect_xdmf_view(archive,view)
    isvalid(inspection) || throw(ArgumentError("invalid XDMF projection: "*
        join(string.(getproperty.(inspection.diagnostics,:code)),", ")))
    buffer=IOBuffer()
    println(buffer,"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Xdmf Version=\"3.0\"><Domain>")
    Episteme._view_info(buffer,"ArchiveId",inspection.archive_id)
    Episteme._view_info(buffer,"ProjectionContentId",Episteme.canonical_content_id(Episteme.to_namedtuple(view)).value)
    Episteme._view_grid(buffer,view,inspection,relative)
    println(buffer,"</Domain></Xdmf>")
    # Publish only a complete metadata file, without replacing another writer's output.
    mktemp(dirname(abspath(path))) do temporary,io
        write(io,take!(buffer));close(io)
        hardlink(temporary,path)
    end
    return inspection
end
