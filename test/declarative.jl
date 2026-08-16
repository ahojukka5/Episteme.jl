OodiCore.check_validation_rule(::Val{:even}, value, parameters) = iseven(value)

@testset "shared declarative schemas" begin
    positive_real = (
        ValidationRule(:finite),
        ValidationRule(:gt; value = 0.0),
    )

    box_schema = NodeSchema(
        Symbol("monge/box"),
        AttributeSchema(:width, :real; allow_ref = true, rules = positive_real),
        AttributeSchema(:depth, :real; allow_ref = true, rules = positive_real),
        AttributeSchema(:height, :real; allow_ref = true, rules = positive_real),
    )

    valid = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = 0.4,
        depth = 0.5,
        height = 2.0,
    )
    result = validate(valid, box_schema)
    @test isvalid(result)
    @test isempty(result.diagnostics)

    symbolic = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = 0.4,
        depth = 0.5,
        height = NodeRef(:derived_height),
    )
    @test isvalid(validate(symbolic, box_schema))

    zero_width = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = 0.0,
        depth = 0.5,
        height = 2.0,
    )
    zero_result = validate(zero_width, box_schema)
    @test !isvalid(zero_result)
    @test any(d -> d.code == :validation_rule_failed, zero_result.diagnostics)

    infinite = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = Inf,
        depth = 0.5,
        height = 2.0,
    )
    inf_result = validate(infinite, box_schema)
    @test !isvalid(inf_result)
    @test any(
        d -> d.code == :validation_rule_failed && d.context.rule == :finite,
        inf_result.diagnostics,
    )

    missing = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = 1.0,
        depth = 1.0,
    )
    @test any(d -> d.code == :missing_attribute, validate(missing, box_schema).diagnostics)

    extra = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = 1.0,
        depth = 1.0,
        height = 1.0,
        color = :red,
    )
    @test any(d -> d.code == :unexpected_attribute, validate(extra, box_schema).diagnostics)

    wrong_type = SemanticNode(
        Symbol("monge/box"),
        :block;
        width = "wide",
        depth = 1.0,
        height = 1.0,
    )
    @test any(d -> d.code == :attribute_type, validate(wrong_type, box_schema).diagnostics)

    built = validated_node(
        box_schema,
        :built;
        width = 1.0,
        depth = 2.0,
        height = 3.0,
    )
    @test built isa SemanticNode
    @test_throws ArgumentError validated_node(
        box_schema,
        :bad;
        width = 0.0,
        depth = 2.0,
        height = 3.0,
    )

    schema_data = to_namedtuple(box_schema)
    @test schema_data.kind == Symbol("monge/box")
    @test schema_data.attributes[1].name == :width
    @test schema_data.attributes[1].allow_ref
    @test schema_data.attributes[1].rules[1].kind == :finite
    @test schema_data.attributes[1].rules[2].parameters.value == 0.0
    @test isempty(schema_data.rules)
    empty_schema = NodeSchema(:empty)
    @test isempty(empty_schema.attributes)
    @test isempty(empty_schema.rules)
    @test isvalid(validate(SemanticNode(:empty), empty_schema))
end

@testset "downstream validation rule extension" begin
    schema = NodeSchema(
        :demo,
        AttributeSchema(:count, :integer; rules = (ValidationRule(:even),)),
    )

    @test isvalid(validate(SemanticNode(:demo; count = 4), schema))
    @test !isvalid(validate(SemanticNode(:demo; count = 3), schema))
end

OodiCore.check_node_validation_rule(::Val{:even_sum}, node, parameters) =
    iseven(attribute(node, :left) + attribute(node, :right))

@testset "node-local cross-field rules" begin
    shots_schema = NodeSchema(
        :shots,
        AttributeSchema(:min_shots, :integer; allow_ref = true, rules = (ValidationRule(:ge; value = 1),)),
        AttributeSchema(:default_shots, :integer; allow_ref = true, rules = (ValidationRule(:ge; value = 1),)),
        AttributeSchema(:max_shots, :integer; allow_ref = true, rules = (ValidationRule(:ge; value = 1),));
        rules = (
            NodeValidationRule(:ordered; fields = (:min_shots, :default_shots, :max_shots)),
        ),
    )

    valid = SemanticNode(:shots; min_shots = 1, default_shots = 32, max_shots = 128)
    @test isvalid(validate(valid, shots_schema))
    @test validated_node(
        shots_schema, :ok; min_shots = 8, default_shots = 32, max_shots = 64
    ) isa SemanticNode

    unordered = SemanticNode(:shots; min_shots = 64, default_shots = 8, max_shots = 32)
    failed = validate(unordered, shots_schema)
    @test !isvalid(failed)
    @test any(d -> d.code == :node_validation_rule_failed, failed.diagnostics)
    @test any(d -> occursin("min_shots <= default_shots <= max_shots", d.message), failed.diagnostics)
    @test_throws ArgumentError validated_node(
        shots_schema; min_shots = 64, default_shots = 8, max_shots = 32)

    missing = SemanticNode(:shots; min_shots = 1, max_shots = 32)
    missing_result = validate(missing, shots_schema)
    @test !isvalid(missing_result)
    @test any(d -> d.code == :missing_attribute, missing_result.diagnostics)
    @test !any(d -> d.code == :node_validation_rule_failed, missing_result.diagnostics)
    @test !any(d -> d.code == :node_validation_rule_error, missing_result.diagnostics)

    wrong_type = SemanticNode(:shots; min_shots = "one", default_shots = 32, max_shots = 64)
    typed = validate(wrong_type, shots_schema)
    @test any(d -> d.code == :attribute_type, typed.diagnostics)
    @test !any(d -> d.code == :node_validation_rule_failed, typed.diagnostics)
    @test !any(d -> d.code == :node_validation_rule_error, typed.diagnostics)

    symbolic = SemanticNode(
        :shots;
        min_shots = 1,
        default_shots = NodeRef(:budget),
        max_shots = 64,
    )
    @test isvalid(validate(symbolic, shots_schema))

    schema_data = to_namedtuple(shots_schema)
    @test length(schema_data.rules) == 1
    @test schema_data.rules[1].kind == :ordered
    @test schema_data.rules[1].parameters.fields == (:min_shots, :default_shots, :max_shots)

    pair_schema = NodeSchema(
        :pair,
        AttributeSchema(:left, :integer),
        AttributeSchema(:right, :integer);
        rules = (NodeValidationRule(:even_sum; fields = (:left, :right)),),
    )
    @test isvalid(validate(SemanticNode(:pair; left = 1, right = 3), pair_schema))
    odd = validate(SemanticNode(:pair; left = 1, right = 2), pair_schema)
    @test !isvalid(odd)
    @test any(d -> d.code == :node_validation_rule_failed && d.context.rule == :even_sum, odd.diagnostics)

    unknown = NodeSchema(
        :pair,
        AttributeSchema(:left, :integer),
        AttributeSchema(:right, :integer);
        rules = (NodeValidationRule(:not_a_rule; fields = (:left, :right)),),
    )
    unknown_result = validate(SemanticNode(:pair; left = 1, right = 2), unknown)
    @test any(d -> d.code == :unknown_node_validation_rule, unknown_result.diagnostics)
end

@testset "shared script node" begin
    script = script_node(
        :catalog_dimensions;
        language = :julia,
        source = "fetch_dimensions(context)",
        inputs = (NodeRef(:catalog_id),),
        outputs = (:width, :height),
        effects = (:network,),
    )

    @test attribute(script, :language) == :julia
    @test attribute(script, :effects) == [:network]
    @test attribute(script, :inputs) == [NodeRef(:catalog_id)]
    @test attribute(script, :outputs) == [:width, :height]
    @test attribute(script, :source) == "fetch_dimensions(context)"

    @test_throws ArgumentError script_node(:empty; source = "   ")
    @test_throws ArgumentError script_node(:bad_input; source = "1", inputs = (:not_a_ref,))
    @test_throws ArgumentError script_node(:bad_output; source = "1", outputs = ("x",))
end
