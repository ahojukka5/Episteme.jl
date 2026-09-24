# Semantic models: named reference graphs, validated structurally. The kinds
# below are test vocabulary; Episteme gives them no meaning.

const _SM_MESH = Symbol("test/mesh")
const _SM_SPACE = Symbol("test/space")
const _SM_FACETS = Symbol("test/facets")
const _SM_CONDITION = Symbol("test/condition")

const _SM_SCHEMAS = Dict(
    _SM_MESH => NodeSchema(
        _SM_MESH,
        AttributeSchema(:element, :symbol; rules = (ValidationRule(:one_of; values = (:Quad4,)),)),
        AttributeSchema(:nx, :integer; required = false, rules = (ValidationRule(:gt; value = 0),)),
    ),
    _SM_SPACE => NodeSchema(
        _SM_SPACE,
        AttributeSchema(:mesh, :reference; allow_ref = true),
        AttributeSchema(:field, :symbol),
    ),
    _SM_FACETS => NodeSchema(_SM_FACETS, AttributeSchema(:mesh, :reference; allow_ref = true)),
    _SM_CONDITION => NodeSchema(
        _SM_CONDITION,
        AttributeSchema(:space, :reference; allow_ref = true),
        AttributeSchema(:boundary, :reference; allow_ref = true),
        AttributeSchema(:value, :any; required = false),
    ),
)

const _SM_REFERENCES = Dict(
    _SM_SPACE => (mesh = _SM_MESH,),
    _SM_FACETS => (mesh = _SM_MESH,),
    _SM_CONDITION => (space = _SM_SPACE, boundary = (_SM_FACETS, _SM_MESH)),
)

_sm_validate(model) = validate(model; schemas = _SM_SCHEMAS, references = _SM_REFERENCES)
_sm_codes(report) = [diagnostic.code for diagnostic in report.diagnostics]

function _sm_model()
    return SemanticModel(
        SemanticNode(_SM_MESH, :mesh; element = :Quad4, nx = 2),
        SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:mesh), field = :u),
        SemanticNode(_SM_FACETS, :boundary; mesh = NodeRef(:mesh)),
        SemanticNode(_SM_CONDITION, :condition;
            space = NodeRef(:space), boundary = NodeRef(:boundary), value = 0.0),
    )
end

@testset "semantic model" begin
    @testset "construction and lookup" begin
        model = _sm_model()
        @test model.root.kind === EPISTEME_MODEL_KIND
        @test model.root.name === :model
        @test length(model) == 4
        @test model_nodes(model)[1] === model[:mesh]
        @test model["space"] === model[:space]
        @test haskey(model, :boundary)
        @test !haskey(model, :missing)
        @test_throws KeyError model[:missing]
        @test occursin("SemanticModel(root=:model", sprint(show, model))

        named = SemanticModel(SemanticNode[]; name = :fragment, kind = Symbol("test/model"))
        @test named.root.kind === Symbol("test/model")
        @test length(named) == 0
        @test length(SemanticModel()) == 0

        tuple = to_namedtuple(model)
        @test tuple.kind === EPISTEME_MODEL_KIND
        @test tuple.children[1].kind === _SM_MESH
    end

    @testset "node_refs finds refs inside containers" begin
        node = SemanticNode(Symbol("test/list"), :list;
            direct = NodeRef(:a),
            nested = (NodeRef(:b), [NodeRef(:c)]),
            named = (left = NodeRef(:d), value = 1.0),
            plain = 3,
        )
        @test Set(ref.target for ref in node_refs(node)) == Set([:a, :b, :c, :d])
        @test isempty(node_refs(SemanticNode(_SM_MESH, :mesh; element = :Quad4)))
    end

    @testset "valid model and deterministic dependency order" begin
        model = _sm_model()
        report = _sm_validate(model)
        @test isvalid(report)
        @test isempty(report.diagnostics)
        @test report.subject === :semantic_model
        @test report.metadata.nodes == 4
        @test dependency_order(model) == [:mesh, :boundary, :space, :condition]

        reversed = SemanticModel(reverse(model_nodes(_sm_model())))
        @test dependency_order(reversed) == dependency_order(model)
    end

    @testset "unresolved references" begin
        model = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:missing), field = :u),
        )
        report = validate(model)
        @test !isvalid(report)
        @test :unresolved_reference in _sm_codes(report)
        unresolved = only(filter(d -> d.code === :unresolved_reference, report.diagnostics))
        @test unresolved.context.attribute === :mesh
        @test unresolved.context.reference === :missing
        @test_throws ArgumentError dependency_order(model)
    end

    @testset "cycles" begin
        model = SemanticModel(
            SemanticNode(_SM_FACETS, :a; mesh = NodeRef(:b)),
            SemanticNode(_SM_FACETS, :b; mesh = NodeRef(:a)),
        )
        report = validate(model)
        @test !isvalid(report)
        cycle = only(filter(d -> d.code === :dependency_cycle, report.diagnostics))
        @test cycle.context.cycle == (:a, :b, :a)
        @test_throws ArgumentError dependency_order(model)
    end

    @testset "names" begin
        unnamed = SemanticModel(SemanticNode(_SM_MESH; element = :Quad4))
        @test :unnamed_node in _sm_codes(validate(unnamed))

        duplicate = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
        )
        @test :duplicate_node_name in _sm_codes(validate(duplicate))
        @test_throws ArgumentError dependency_order(duplicate)

        root_clash = SemanticModel(SemanticNode(_SM_MESH, :model; element = :Quad4))
        @test :duplicate_root_name in _sm_codes(validate(root_clash))
    end

    @testset "schemas" begin
        bad_value = SemanticModel(SemanticNode(_SM_MESH, :mesh; element = :Tri3))
        @test :validation_rule_failed in _sm_codes(_sm_validate(bad_value))
        @test isvalid(validate(bad_value))

        unknown = SemanticModel(SemanticNode(Symbol("test/not_a_kind"), :bad))
        @test :unknown_kind in _sm_codes(_sm_validate(unknown))
        @test isvalid(validate(unknown))

        missing_field = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:mesh)),
        )
        @test :missing_attribute in _sm_codes(_sm_validate(missing_field))
    end

    @testset "reference kinds are data" begin
        wrong = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:mesh), field = :u),
            SemanticNode(_SM_FACETS, :boundary; mesh = NodeRef(:space)),
        )
        report = _sm_validate(wrong)
        @test !isvalid(report)
        incompatible = only(filter(d -> d.code === :incompatible_reference, report.diagnostics))
        @test incompatible.context.attribute === :mesh
        @test incompatible.context.expected === _SM_MESH
        @test incompatible.context.actual === _SM_SPACE
        @test isvalid(validate(wrong; schemas = _SM_SCHEMAS))

        either = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:mesh), field = :u),
            SemanticNode(_SM_CONDITION, :condition; space = NodeRef(:space), boundary = NodeRef(:mesh)),
        )
        @test isvalid(_sm_validate(either))
        wrong_either = SemanticModel(
            SemanticNode(_SM_MESH, :mesh; element = :Quad4),
            SemanticNode(_SM_SPACE, :space; mesh = NodeRef(:mesh), field = :u),
            SemanticNode(_SM_CONDITION, :condition; space = NodeRef(:space), boundary = NodeRef(:space)),
        )
        incompatible = only(filter(d -> d.code === :incompatible_reference, _sm_validate(wrong_either).diagnostics))
        @test incompatible.context.expected == (_SM_FACETS, _SM_MESH)
    end

    @testset "report" begin
        summary = report(_sm_model())
        @test summary.subject === :semantic_model
        @test any(d -> d.code === :structurally_valid, summary.diagnostics)
        @test !isempty(summary.summary)
    end
end
