# SPDX-FileCopyrightText: Jukka Aho
# SPDX-License-Identifier: MIT

using Episteme, JLD2, Test, SHA

function _xdmf_fixture(directory)
    payload=(coordinates=Float64[0 1 0 1;0 0 1 1;0 0 0 0],
        triangles=Int32[0 1;1 3;2 2],
        quadrilateral=reshape(Int32[0,1,3,2],4,1),
        mixed=Int32[4,0,1,2,5,0,1,3,2],
        values=Float32[2,3,5,7],later_values=Float32[4,6,10,14],cells=Float64[11,13],
        velocity=Float64[1 2 3 4;0 1 0 1;2 2 2 2],
        selected=Int32[1],face_cells=Int32[0],face_indices=Int32[0],
        face_values=Float64[.5],grid_value=Float64[19],bad_indices=Int32[99],
        bad_topology=Int32[0 1;1 4;2 2],bad_mixed=Int32[3,1,0])
    object=ObjectRef(ObjectId("fixture-object");revision_id=RevisionId("fixture-revision"))
    content=canonical_content_id(payload)
    namespace=ArchiveNamespace(:fixture;package_uuid="11111111-1111-4111-8111-111111111111")
    schema=SchemaRef(:fixture,"visual-payload","1.0.0")
    envelope=ArchiveObject(object.object_id,object.revision_id;namespace,
        kind=Symbol("fixture/visual-payload"),schema,content_id=content)
    archive=joinpath(directory,"numeric & data.ah5")
    write_state_archive(archive,ArchiveGraph([envelope];revisions=[RevisionRecord(object.revision_id)]);
        schemas=SchemaRegistry([SchemaDefinition(schema;namespace,
            fields=[SchemaField(name,LogicalType(eltype(value)<:Integer ? :integer : :real);
                rank=ndims(value),shape=size(value)) for (name,value) in pairs(payload)])]),
        archive_id="fixed-view-archive")
    # The fixture domain writes its payload once. View generation only opens r.
    JLD2.jldopen(archive,"r+") do file
        for (name,value) in pairs(payload);file["data/"*string(name)]=value;end
        file["data/complex"]=[1+2im]
        file["data/native"]=(text="nonvisual scientific metadata",)
    end
    refs=map(keys(payload)) do name
        XdmfDataset("/data/"*string(name),object,content;content_id=canonical_content_id(payload[name]))
    end
    refs=NamedTuple{keys(payload)}(refs)
    grid=XdmfGrid("triangle & surface",refs.coordinates,refs.triangles;cells=2,
        attributes=(XdmfAttribute("point values",refs.values),
            XdmfAttribute("cell values",refs.cells;center=:Cell),
            XdmfAttribute("velocity",refs.velocity;kind=:Vector)),
        sets=(XdmfSet("chosen cells",refs.selected),))
    return (;archive,payload,object,content,refs,grid)
end

if abspath(PROGRAM_FILE) == (@__FILE__) && !isempty(ARGS)
    directory=abspath(ARGS[1]);mkpath(directory)
    fixture=_xdmf_fixture(directory)
    (;archive,refs,grid)=fixture
    write_xdmf_view(joinpath(directory,"surface.xmf"),archive,grid)
    mixed=XdmfGrid("mixed",refs.coordinates,refs.mixed;cells=2,topology_type=:Mixed)
    write_xdmf_view(joinpath(directory,"mixed.xmf"),archive,mixed)
    quad=XdmfGrid("quad",refs.coordinates,refs.quadrilateral;cells=1,topology_type=:Quadrilateral)
    write_xdmf_view(joinpath(directory,"levels.xmf"),archive,
        XdmfCollection("levels",(XdmfCollection("coarse",(grid,)),XdmfCollection("fine",(quad,)))))
    timed=[XdmfGrid("step-$t",refs.coordinates,refs.triangles;cells=2,time=t,
        attributes=(XdmfAttribute("point values",t==0 ? refs.values : refs.later_values),)) for t in (0.,1.)]
    write_xdmf_view(joinpath(directory,"series.xmf"),archive,
        XdmfCollection("series",timed;kind=:Temporal))
    println("Reader fixtures written to ",directory)
end

@testset "lightweight archive views" begin
    mktempdir() do directory
        fixture=_xdmf_fixture(directory)
        (;archive,refs,grid,object,content)=fixture
        original=read(archive)
        report=inspect_xdmf_view(archive,grid)
        @test isvalid(report)
        @test isready(readiness(report,PipelineTarget(:xdmf)))
        @test report.archive_id=="fixed-view-archive"
        @test report.datasets[refs.coordinates.path].shape==(4,3)
        @test report.datasets[refs.triangles.path].shape==(2,3)
        @test report.datasets[refs.values.path].precision==4
        output=joinpath(directory,"mesh.xmf")
        @test isvalid(write_xdmf_view(output,archive,grid))
        first_text=read(output,String)
        @test occursin("numeric &amp; data.ah5:/data/coordinates",first_text)
        @test occursin("ObjectId:/data/coordinates",first_text)
        @test occursin(content.value,first_text)
        @test occursin(refs.coordinates.content_id.value,first_text)
        @test occursin("GridType=\"Uniform\"",first_text)
        @test occursin("Center=\"Cell\"",first_text)
        @test !occursin("nonvisual scientific metadata",first_text)
        @test read(archive)==original
        @test inspect_archive(archive).profile.archive_id==report.archive_id
        @test inspect_archive(archive,ArchiveStateHistory).state.objects[1].content_id==content
        @test_throws ArgumentError write_xdmf_view(output,archive,grid)
        @test_throws ArgumentError write_xdmf_view(archive,archive,grid)
        rm(output)
        write_xdmf_view(output,archive,grid)
        @test read(output,String)==first_text
        write_xdmf_view(joinpath(directory,"second.xmf"),archive,grid)
        @test read(joinpath(directory,"second.xmf"),String)==first_text
        @test read(archive)==original
        nested=joinpath(directory,"views");mkpath(nested)
        write_xdmf_view(joinpath(nested,"relative.xmf"),archive,grid)
        @test occursin("../numeric &amp; data.ah5:/data/coordinates",read(joinpath(nested,"relative.xmf"),String))

        quad=XdmfGrid("quad",refs.coordinates,refs.quadrilateral;cells=1,
            topology_type=:Quadrilateral)
        blocks=XdmfCollection("blocks",(grid,quad))
        levels=XdmfCollection("levels",(blocks,XdmfCollection("fine",(grid,))))
        write_xdmf_view(joinpath(directory,"levels.xmf"),archive,levels)
        @test isvalid(inspect_xdmf_view(archive,levels))
        @test count("CollectionType=\"Spatial\"",read(joinpath(directory,"levels.xmf"),String))==3
        t0=XdmfGrid("first",refs.coordinates,refs.triangles;cells=2,time=0.)
        t1=XdmfGrid("second",refs.coordinates,refs.triangles;cells=2,time=1.)
        series=XdmfCollection("series",(t0,t1);kind=:Temporal)
        write_xdmf_view(joinpath(directory,"series.xmf"),archive,series)
        @test occursin("CollectionType=\"Temporal\"",read(joinpath(directory,"series.xmf"),String))
        mixed=XdmfGrid("mixed",refs.coordinates,refs.mixed;cells=2,topology_type=:Mixed)
        write_xdmf_view(joinpath(directory,"mixed.xmf"),archive,mixed)
        @test isvalid(inspect_xdmf_view(archive,mixed))
        associated=XdmfGrid("associations",refs.coordinates,refs.triangles;cells=2,
            attributes=(XdmfAttribute("face",refs.face_values;center=:Face,entities=1),
                XdmfAttribute("edge",refs.face_values;center=:Edge,entities=1),
                XdmfAttribute("grid",refs.grid_value;center=:Grid)),
            sets=(XdmfSet("face selection",refs.face_indices;kind=:Face,cells=refs.face_cells),))
        @test isvalid(inspect_xdmf_view(archive,associated))
        write_xdmf_view(joinpath(directory,"associations.xmf"),archive,associated)
        @test occursin("SetType=\"Face\"",read(joinpath(directory,"associations.xmf"),String))
        @test read(archive)==original

        for (path,code) in (("/data/missing",:xdmf_dataset_missing),
                            ("/data/native",:xdmf_unsupported_dataset_layout),
                            ("/data/complex",:xdmf_unsupported_dataset_layout))
            bad=XdmfDataset(path,object,content;content_id=refs.coordinates.content_id)
            invalid=XdmfGrid("bad",bad,refs.triangles;cells=2)
            inspection=inspect_xdmf_view(archive,invalid)
            @test !isvalid(inspection)
            @test code in getproperty.(inspection.diagnostics,:code)
            @test_throws ArgumentError write_xdmf_view(joinpath(directory,"invalid.xmf"),archive,invalid)
            @test !isfile(joinpath(directory,"invalid.xmf"))
        end
        wrong=XdmfDataset(refs.coordinates.path,object,ContentId("wrong");content_id=refs.coordinates.content_id)
        @test :xdmf_object_identity_mismatch in getproperty.(inspect_xdmf_view(archive,
            XdmfGrid("wrong",wrong,refs.triangles;cells=2)).diagnostics,:code)
        altered=XdmfDataset(refs.coordinates.path,object,content;content_id=ContentId("wrong-array"))
        @test :xdmf_dataset_content_mismatch in getproperty.(inspect_xdmf_view(archive,
            XdmfGrid("altered",altered,refs.triangles;cells=2)).diagnostics,:code)
        badshape=XdmfGrid("bad shape",refs.coordinates,refs.triangles;cells=3)
        @test :xdmf_topology_shape in getproperty.(inspect_xdmf_view(archive,badshape).diagnostics,:code)
        badfield=XdmfGrid("bad field",refs.coordinates,refs.triangles;cells=2,
            attributes=(XdmfAttribute("wrong association",refs.values;center=:Cell),))
        @test :xdmf_attribute_shape in getproperty.(inspect_xdmf_view(archive,badfield).diagnostics,:code)
        for invalid in (
            XdmfGrid("bounds",refs.coordinates,refs.bad_topology;cells=2),
            XdmfGrid("polygon",refs.coordinates,refs.bad_mixed;cells=1,topology_type=:Mixed))
            @test :xdmf_topology_shape in getproperty.(inspect_xdmf_view(archive,invalid).diagnostics,:code)
        end
        for subset in (XdmfSet("cell bounds",refs.bad_indices),
            XdmfSet("face bounds",refs.bad_indices;kind=:Face,cells=refs.face_cells))
            invalid=XdmfGrid("subset",refs.coordinates,refs.triangles;cells=2,sets=(subset,))
            @test :xdmf_subset_indices in getproperty.(inspect_xdmf_view(archive,invalid).diagnostics,:code)
        end
        conflicting=XdmfDataset(refs.coordinates.path,object,content;content_id=ContentId("other"))
        invalid=XdmfGrid("bindings",refs.coordinates,refs.triangles;cells=2,
            attributes=(XdmfAttribute("conflicting",conflicting),))
        @test :xdmf_conflicting_dataset_binding in getproperty.(inspect_xdmf_view(archive,invalid).diagnostics,:code)
        invalid_archive=joinpath(directory,"not-ah5.jld2")
        JLD2.jldsave(invalid_archive;data=fixture.payload.coordinates)
        @test :xdmf_invalid_archive in getproperty.(inspect_xdmf_view(invalid_archive,grid).diagnostics,:code)
        profile_only=joinpath(directory,"profile.ah5")
        write_archive(profile_only)
        @test :xdmf_missing_object_history in getproperty.(inspect_xdmf_view(profile_only,grid).diagnostics,:code)
        @test read(archive)==original
        @test_throws ArgumentError xdmf_projection((metadata="not a mesh",))
        @test_throws ArgumentError XdmfDataset("/data/../values",object,content;content_id=content)
        @test_throws ArgumentError XdmfDataset("/data/values",ObjectRef(object.object_id),content;content_id=content)
        @test_throws ArgumentError XdmfGrid("bad\0name",refs.coordinates,refs.triangles;cells=2)
        @test_throws ArgumentError XdmfAttribute("face",refs.face_values;center=:Face)
        @test_throws ArgumentError XdmfSet("face",refs.face_indices;kind=:Face)
        @test_throws ArgumentError XdmfCollection("time",(t1,t0);kind=:Temporal)
        @test_throws ArgumentError XdmfCollection("time",(grid,);kind=:Temporal)
    end
end
