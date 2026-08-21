# Package namespaces and reserved shared namespaces (#38). No HDF5.

const UUID_DELONE = "11111111-1111-4111-8111-111111111111"
const UUID_OODI = "22222222-2222-4222-8222-222222222222"
const UUID_LIEB = "33333333-3333-4333-8333-333333333333"
const UUID_EXT = "44444444-4444-4444-8444-444444444444"

@testset "reserved shared namespaces and archive areas" begin
    @test EPISTEME_NAMESPACE === :episteme
    @test EPISTEME_PACKAGE_UUID == "7c15cd61-9c6a-4671-bc94-9960963998ac"
    @test is_reserved_shared_namespace(:episteme)
    @test !is_reserved_shared_namespace(:delone)
    @test is_reserved_archive_area(:provenance)
    @test is_reserved_archive_area(:schemas)
    @test is_reserved_archive_area(:payloads)
    @test !is_reserved_archive_area(:delone)
    @test !is_reserved_archive_area(EPISTEME_NAMESPACE)
    @test owns_kind(:delone, Symbol("delone/mesh"))
    @test !owns_kind(:delone, Symbol("oodi/field"))
    @test episteme_namespace().id === EPISTEME_NAMESPACE
    @test episteme_namespace().package_uuid == EPISTEME_PACKAGE_UUID
    @test_throws ArgumentError ArchiveNamespace(Symbol(""))
    @test_throws ArgumentError NamespaceClaim(
        episteme_namespace();
        role = :shared,
        status = :alias,
    )
    @test_throws ArgumentError NamespaceClaim(episteme_namespace(); role = :owner)
end

@testset "unrelated domain namespaces coexist without kind collisions" begin
    geometry = _obj(
        :monge, "box", ID_GEOM, REV_1;
        uuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    )
    mesh = _obj(
        :delone, "mesh", ID_MESH, REV_2;
        uuid = UUID_DELONE,
        references = [ArchiveReference(:geometry, ObjectId(ID_GEOM); revision_id = RevisionId(REV_1))],
    )
    field = _obj(:oodi, "field", ID_FIELD, REV_3; uuid = UUID_OODI)
    sector = _obj(:lieb, "sector", ID_SECTOR, REV_3; uuid = UUID_LIEB)
    document = ArchiveObject(
        ObjectId("doc-1"),
        RevisionId(REV_1);
        namespace = episteme_namespace(),
        kind = EPISTEME_DOCUMENT_KIND,
        schema = episteme_document_schema(),
    )
    graph = ArchiveGraph([field, document, geometry, sector, mesh])
    @test isvalid(validate(graph))
    @test isvalid(validate(document))

    listings = list_namespaces(graph)
    @test [listing.namespace.id for listing in listings] ==
        [:delone, :episteme, :lieb, :monge, :oodi]
    delone = listings[1]
    @test delone.namespace.package_uuid == UUID_DELONE
    @test delone.role === :domain
    @test delone.kinds === (Symbol("delone/mesh"),)
    @test delone.schema_ids === ("mesh",)
    @test listings[2].role === :shared
    @test listings[2].kinds === (EPISTEME_DOCUMENT_KIND,)
    @test to_namedtuple(delone).id === :delone

    shuffled = ArchiveGraph(reverse(graph.objects))
    @test isvalid(validate(shuffled))
    @test find_object(shuffled, mesh.object_id, mesh.revision_id).references[1].target.object_id ==
        geometry.object_id
    @test [listing.namespace.id for listing in list_namespaces(shuffled)] ==
        [listing.namespace.id for listing in listings]
end

@testset "display-name rename keeps package UUID identity" begin
    before = ArchiveObject(
        ObjectId(ID_MESH),
        RevisionId(REV_1);
        namespace = ArchiveNamespace(
            :delone;
            package_uuid = UUID_DELONE,
            display_name = "Delone.jl",
        ),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
    )
    after = ArchiveObject(
        ObjectId(ID_FIELD),
        RevisionId(REV_2);
        namespace = ArchiveNamespace(
            :delone;
            package_uuid = UUID_DELONE,
            display_name = "DeloneMesh.jl",
        ),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
    )
    graph = ArchiveGraph([before, after])
    @test isvalid(validate(graph))
    listings = list_namespaces(graph)
    @test length(listings) == 1
    @test listings[1].namespace.package_uuid == UUID_DELONE
    @test listings[1].namespace.id === :delone
    @test listings[1].namespace.display_name == "DeloneMesh.jl"
end

@testset "claiming another package namespace fails with structured diagnostics" begin
    delone = _obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)
    stolen = _obj(:delone, "mesh", ID_GEOM, REV_2; uuid = UUID_OODI)
    conflict = validate(ArchiveGraph([delone, stolen]))
    @test !isvalid(conflict)
    @test any(d -> d.code === :namespace_identity_conflict, conflict.diagnostics)

    split = validate(ArchiveGraph([
        delone,
        _obj(:meshkit, "mesh", ID_GEOM, REV_2; uuid = UUID_DELONE),
    ]))
    @test !isvalid(split)
    @test any(d -> d.code === :namespace_id_split, split.diagnostics)

    reserved_area = _obj(:provenance, "record", ID_POST, REV_1)
    area_report = validate(reserved_area)
    @test !isvalid(area_report)
    @test any(d -> d.code === :reserved_archive_area_claimed, area_report.diagnostics)

    stolen_shared = ArchiveObject(
        ObjectId(ID_MODEL),
        RevisionId(REV_1);
        namespace = ArchiveNamespace(
            :episteme;
            package_uuid = UUID_OODI,
            display_name = "NotEpisteme.jl",
        ),
        kind = EPISTEME_DOCUMENT_KIND,
        schema = episteme_document_schema(),
    )
    shared_report = validate(stolen_shared)
    @test !isvalid(shared_report)
    @test any(d -> d.code === :reserved_namespace_claimed, shared_report.diagnostics)

    reserved_kind = ArchiveObject(
        ObjectId(ID_VOL),
        RevisionId(REV_1);
        namespace = _ns(:oodi; uuid = UUID_OODI),
        kind = EPISTEME_PLAN_KIND,
        schema = episteme_plan_schema(),
    )
    kind_report = validate(reserved_kind)
    codes = Set(d.code for d in kind_report.diagnostics)
    @test :reserved_kind_claimed in codes
    @test :kind_namespace_mismatch in codes
end

@testset "registry aliases, extensions, and inspect listing" begin
    shared = NamespaceClaim(
        episteme_namespace();
        role = :shared,
        aliases = (:oodicore,),
    )
    alias = NamespaceClaim(
        ArchiveNamespace(:oodicore; package_uuid = EPISTEME_PACKAGE_UUID, display_name = "OodiCore.jl");
        role = :shared,
        status = :alias,
        canonical_id = EPISTEME_NAMESPACE,
    )
    delone = NamespaceClaim(
        ArchiveNamespace(:delone; package_uuid = UUID_DELONE, display_name = "Delone.jl");
        role = :domain,
    )
    extension = NamespaceClaim(
        ArchiveNamespace(:delone_xdmf; package_uuid = UUID_EXT, display_name = "DeloneXDMF");
        role = :extension,
    )
    registry = NamespaceRegistry([shared, alias, delone, extension])
    @test isvalid(validate(shared))
    @test isvalid(validate(registry))
    @test isready(readiness(registry, PipelineTarget(:inspect)))
    @test resolve_namespace(registry, :oodicore).namespace.id === EPISTEME_NAMESPACE
    @test find_claim(registry, :oodicore).status === :alias
    @test to_namedtuple(registry).claims[1].namespace.id === :delone

    mesh = _obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_DELONE)
    historical = ArchiveObject(
        ObjectId("doc-old"),
        RevisionId(REV_1);
        namespace = ArchiveNamespace(
            :oodicore;
            package_uuid = EPISTEME_PACKAGE_UUID,
            display_name = "OodiCore.jl",
        ),
        kind = Symbol("oodicore/document"),
        schema = SchemaRef(:oodicore, "document", "1.0.0"),
    )
    current = ArchiveObject(
        ObjectId("doc-1"),
        RevisionId(REV_2);
        namespace = episteme_namespace(),
        kind = EPISTEME_DOCUMENT_KIND,
        schema = episteme_document_schema(),
    )
    ext_obj = _obj(:delone_xdmf, "view", ID_VOL, REV_2; uuid = UUID_EXT)
    graph = ArchiveGraph(
        [mesh, historical, current, ext_obj];
        revisions = [
            RevisionRecord(RevisionId(REV_1)),
            RevisionRecord(RevisionId(REV_2); parents = [RevisionId(REV_1)]),
        ],
    )
    @test !isvalid(validate(graph))
    @test any(d -> d.code === :namespace_id_split, validate(graph).diagnostics)
    @test isvalid(validate(graph, registry))

    listings = list_namespaces(graph, registry)
    ids = [listing.namespace.id for listing in listings]
    @test :delone in ids
    @test :episteme in ids
    @test :oodicore in ids
    @test :delone_xdmf in ids
    oodicore = listings[findfirst(listing -> listing.namespace.id === :oodicore, listings)]
    @test oodicore.status === :alias
    @test oodicore.canonical_id === EPISTEME_NAMESPACE
    xdmf = listings[findfirst(listing -> listing.namespace.id === :delone_xdmf, listings)]
    @test xdmf.role === :extension
    @test xdmf.kinds === (Symbol("delone_xdmf/view"),)

    manifest = inspect(graph, RevisionId(REV_2))
    inspected = list_namespaces(manifest, registry)
    @test any(listing -> listing.namespace.id === :delone_xdmf, inspected)
    @test all(
        listing -> listing.namespace.id !== :missing,
        inspected,
    )

    stolen_ext = NamespaceRegistry([
        delone,
        NamespaceClaim(
            ArchiveNamespace(:delone; package_uuid = UUID_EXT);
            role = :extension,
        ),
    ])
    stolen_report = validate(stolen_ext)
    @test !isvalid(stolen_report)
    @test any(d -> d.code === :duplicate_namespace_claim, stolen_report.diagnostics)

    domain_episteme = validate(NamespaceClaim(episteme_namespace(); role = :domain))
    @test any(d -> d.code === :reserved_namespace_claimed, domain_episteme.diagnostics)

    area_claim = validate(NamespaceClaim(ArchiveNamespace(:schemas); role = :domain))
    @test any(d -> d.code === :reserved_archive_area_claimed, area_claim.diagnostics)

    mismatched_alias = NamespaceRegistry([
        shared,
        NamespaceClaim(
            ArchiveNamespace(:oodicore; package_uuid = UUID_OODI);
            role = :shared,
            status = :alias,
            canonical_id = EPISTEME_NAMESPACE,
        ),
    ])
    @test any(
        d -> d.code === :namespace_alias_uuid_mismatch,
        validate(mismatched_alias).diagnostics,
    )

    object_mismatch = validate(
        ArchiveGraph([_obj(:delone, "mesh", ID_MESH, REV_1; uuid = UUID_OODI)]),
        NamespaceRegistry([delone]),
    )
    @test any(d -> d.code === :namespace_identity_conflict, object_mismatch.diagnostics)

    @test report(registry).subject === :namespace_registry
    @test occursin("claims", report(registry).summary)
    @test !isready(readiness(registry, PipelineTarget(:commit)))
end
