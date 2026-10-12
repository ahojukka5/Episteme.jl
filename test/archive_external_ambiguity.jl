# Independent declaration-order oracles; usable without JLD2 or domain packages.
function _external_ambiguity_fixture(; pinned = false)
    revision = RevisionId("external-ambiguity-r1")
    external_id = ObjectId("external-ambiguity-input")
    namespace = ArchiveNamespace(:fixture)
    schema = SchemaRef(:fixture, "state", "1")
    child = ArchiveObject(
        ObjectId("external-ambiguity-child"), revision;
        namespace, schema, kind = schema_kind(schema),
        content_id = canonical_content_id((; value = 1)),
        references = [ArchiveReference(:input, external_id;
            revision_id = pinned ? revision : nothing)],
    )
    root = ArchiveObject(
        ObjectId("external-ambiguity-root"), revision;
        namespace, schema, kind = schema_kind(schema),
        content_id = canonical_content_id((; value = 2)),
        references = [ArchiveReference(:child, child.object_id; revision_id = revision)],
    )
    graph = ArchiveGraph([root, child]; revisions = [RevisionRecord(revision)])
    schemas = SchemaRegistry([SchemaDefinition(schema; namespace,
        fields = [SchemaField(:value, LogicalType(:integer))])])
    declaration = ExternalRequirement(external_id;
        content_id = canonical_content_id((; input = 1)),
        artifact = ArtifactRef(:file; path = "input.bin", description = "input", unit = "1"))
    return graph, revision, external_id, schemas, declaration
end

@testset "external declaration conflicts refuse every ordering" begin
    for pinned in (false, true)
        graph, revision, id, schemas, first_decl = _external_ambiguity_fixture(; pinned)
        before = to_namedtuple(graph)
        # These cases vary identity, location, and descriptive contract fields
        # independently. The expected result never selects any candidate.
        conflicts = [
            ExternalRequirement(id; artifact = first_decl.artifact),
            ExternalRequirement(id; content_id = canonical_content_id((; input = 2)),
                artifact = first_decl.artifact),
        ]
        for artifact in (
            ArtifactRef(:file; path = "other.bin", description = "input", unit = "1"),
            ArtifactRef(:file; path = "input.bin", uri = "https://example.invalid/input",
                description = "input", unit = "1"),
            ArtifactRef(:binary; path = "input.bin", description = "input", unit = "1"),
            ArtifactRef(:file; path = "input.bin", description = "other", unit = "1"),
            ArtifactRef(:file; path = "input.bin", description = "input", unit = "m"),
        )
            push!(conflicts, ExternalRequirement(id;
                content_id = first_decl.content_id, artifact))
        end
        for conflict in conflicts
            declarations = [first_decl, conflict, first_decl]
            expected_diagnostics = nothing
            for order in ((1, 2, 3), (1, 3, 2), (2, 1, 3),
                          (2, 3, 1), (3, 1, 2), (3, 2, 1))
                reqs = declarations[collect(order)]
                for operation in (inspect, checkout)
                    manifest = operation(graph, revision; externals = reqs)
                    entry = select(manifest, id)
                    @test entry.availability === :missing
                    @test entry.content_id === nothing
                    @test entry.artifact === nothing
                    @test !isvalid(validate(manifest))
                    @test !isready(readiness(manifest, PipelineTarget(:inspect)))
                    @test any(d -> d.code === :ambiguous_external_requirement,
                        manifest.diagnostics)
                    diagnostics = Tuple(to_namedtuple.(manifest.diagnostics))
                    expected_diagnostics === nothing && (expected_diagnostics = diagnostics)
                    @test diagnostics == expected_diagnostics
                end
                integrity = integrity_manifest(graph, revision, schemas; externals = reqs)
                @test !isvalid(integrity)
                @test any(d -> d.code === :ambiguous_external_requirement,
                    integrity.diagnostics)
                capsule = plan_capsule(graph, revision, schemas; externals = reqs)
                @test !isvalid(capsule)
                @test !isready(capsule)
                preflight = Episteme._external_preflight_graph(graph, reqs)
                @test !isvalid(validate(preflight))
            end
        end
        @test to_namedtuple(graph) == before
    end
end

@testset "unique and identical external declarations remain usable" begin
    graph, revision, id, schemas, declaration = _external_ambiguity_fixture()
    duplicate = ExternalRequirement(id;
        content_id = ContentId(declaration.content_id.value),
        artifact = ArtifactRef(:file; path = "input.bin", description = "input", unit = "1"))
    unrelated = ObjectId("unrelated")
    outside = [ExternalRequirement(unrelated; content_id = ContentId("one")),
        ExternalRequirement(unrelated; content_id = ContentId("two"))]
    for declarations in ([declaration], [declaration, duplicate],
                         [duplicate, declaration], [outside; declaration])
        for operation in (inspect, checkout)
            manifest = operation(graph, revision; externals = declarations)
            @test isvalid(validate(manifest))
            @test isready(readiness(manifest, PipelineTarget(:inspect)))
            entry = select(manifest, id)
            @test entry.availability === :external_required
            @test entry.content_id == declaration.content_id
            @test to_namedtuple(entry.artifact) == to_namedtuple(declaration.artifact)
        end
        preflight = Episteme._external_preflight_graph(graph, declarations)
        @test isvalid(validate(preflight))
    end
end

if Base.get_extension(Episteme, :EpistemeJLD2Ext) !== nothing
    @testset "AH5 publication refuses conflicting external declarations" begin
        graph, revision, id, schemas, declaration = _external_ambiguity_fixture()
        conflicting = ExternalRequirement(id; content_id = ContentId("different"))
        mktempdir() do directory
            for declarations in ([declaration, conflicting], [conflicting, declaration])
                path = joinpath(directory, "ambiguous.ah5")
                @test_throws ArgumentError write_archive(path;
                    graph, schemas, externals = declarations)
                @test !ispath(path)
                @test_throws ArgumentError write_state_archive(path, graph;
                    schemas, externals = declarations)
                @test !ispath(path)
            end
        end
    end
end
