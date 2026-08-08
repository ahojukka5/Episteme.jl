# ---------------------------------------------------------------------------
# Shared declarative-model primitives
#
# These facilities are intentionally domain-neutral. Downstream packages own
# their vocabularies and constraints; OodiCore only provides portable local
# schemas, validation rules, and an opaque scripting representation.
# ---------------------------------------------------------------------------

const _SCRIPT_NODE_KIND = Symbol("oodi/script")

"""
    script_node(name; language=:julia, source, inputs=(), outputs=(), effects=())

Create an opaque scripting node that can appear in any Oodi ecosystem semantic
model.

The node stores source code and an explicit execution contract, but OodiCore
never executes the source. A future trusted execution layer must opt in
explicitly and decide which declared effects are allowed.

# Attributes
- `language::Symbol`: implementation language, e.g. `:julia`.
- `source::String`: source code.
- `inputs`: symbolic [`NodeRef`](@ref)s consumed by the script.
- `outputs`: symbolic names produced by the script.
- `effects`: declared non-pure effects such as `:network` or `:filesystem`.
"""
function script_node(
    name::Symbol;
    language::Symbol = :julia,
    source::AbstractString,
    inputs = (),
    outputs = (),
    effects = (),
)
    isempty(strip(source)) && throw(ArgumentError("script source must not be empty"))

    input_refs = NodeRef[]
    for input in inputs
        input isa NodeRef || throw(ArgumentError("script inputs must be NodeRef values"))
        push!(input_refs, input)
    end

    output_names = Symbol[]
    for output in outputs
        output isa Symbol || throw(ArgumentError("script outputs must be Symbol values"))
        push!(output_names, output)
    end

    effect_names = Symbol[]
    for effect in effects
        effect isa Symbol || throw(ArgumentError("script effects must be Symbol values"))
        push!(effect_names, effect)
    end

    return SemanticNode(
        _SCRIPT_NODE_KIND,
        name;
        effects = effect_names,
        inputs = input_refs,
        language = language,
        outputs = output_names,
        source = String(source),
    )
end

"""
    ValidationRule(kind; message="", kwargs...)

A portable, introspectable local validation rule.

`kind` identifies the rule and `parameters` contains its serializable
configuration. Rules intentionally contain no function closures so schemas can
be shown to agents, serialized, and exposed through tool protocols.

OodiCore provides the standard rule kinds `:finite`, `:gt`, `:ge`, `:lt`,
`:le`, `:nonempty`, and `:one_of`. Downstream packages may extend
[`check_validation_rule`](@ref) for additional symbolic rule kinds.
"""
struct ValidationRule
    kind::Symbol
    parameters::NamedTuple
    message::String
end

function ValidationRule(kind::Symbol; message::AbstractString = "", kwargs...)
    return ValidationRule(kind, (; kwargs...), String(message))
end

"""
    AttributeSchema(name, value_kind; required=true, allow_ref=false, rules=())

Describe one local attribute of a semantic node.

`value_kind` is a portable semantic type name rather than a Julia `DataType`.
Built-in kinds are `:any`, `:bool`, `:integer`, `:real`, `:number`, `:string`,
`:symbol`, `:reference`, and `:list`. `allow_ref=true` permits a [`NodeRef`](@ref)
to stand in for the eventual resolved value; value rules are deferred until
that reference has been resolved.
"""
struct AttributeSchema
    name::Symbol
    value_kind::Symbol
    required::Bool
    allow_ref::Bool
    rules::Vector{ValidationRule}
end

function AttributeSchema(
    name::Symbol,
    value_kind::Symbol;
    required::Bool = true,
    allow_ref::Bool = false,
    rules = (),
)
    rule_values = ValidationRule[]
    for rule in rules
        rule isa ValidationRule ||
            throw(ArgumentError("attribute schema rules must be ValidationRule values"))
        push!(rule_values, rule)
    end
    return AttributeSchema(name, value_kind, required, allow_ref, rule_values)
end

"""
    NodeSchema(kind, attributes...; allow_extra=false)

Describe the local structural/value schema of one semantic node kind.

A `NodeSchema` is deliberately narrower than a domain constraint system. It
answers questions such as "is this field present?", "is it a finite positive
real?", or "is this enum value allowed?". Relations between multiple model
objects or quantities belong to downstream constraint vocabularies instead.
"""
struct NodeSchema
    kind::Symbol
    attributes::Vector{AttributeSchema}
    allow_extra::Bool

    function NodeSchema(
        kind::Symbol,
        attributes::Vector{AttributeSchema},
        allow_extra::Bool,
    )
        names = getfield.(attributes, :name)
        length(unique(names)) == length(names) ||
            throw(ArgumentError("NodeSchema attributes must have unique names"))
        return new(kind, copy(attributes), allow_extra)
    end
end

function NodeSchema(kind::Symbol, attributes::AttributeSchema...; allow_extra::Bool = false)
    return NodeSchema(kind, collect(attributes), allow_extra)
end

"""
    check_validation_rule(Val(kind), value, parameters) -> Bool

Evaluate a symbolic validation rule against one concrete value.

Downstream packages can extend this generic for domain-specific rule kinds while
keeping the rule itself serializable and introspectable.
"""
function check_validation_rule end

check_validation_rule(::Val{:finite}, value, parameters) = value isa Number && isfinite(value)
check_validation_rule(::Val{:gt}, value, parameters) = value > parameters.value
check_validation_rule(::Val{:ge}, value, parameters) = value >= parameters.value
check_validation_rule(::Val{:lt}, value, parameters) = value < parameters.value
check_validation_rule(::Val{:le}, value, parameters) = value <= parameters.value
check_validation_rule(::Val{:nonempty}, value, parameters) = !isempty(value)
check_validation_rule(::Val{:one_of}, value, parameters) = value in parameters.values

function _matches_value_kind(value, kind::Symbol)
    kind === :any && return true
    kind === :bool && return value isa Bool
    kind === :integer && return value isa Integer && !(value isa Bool)
    kind === :real && return value isa Real && !(value isa Bool)
    kind === :number && return value isa Number && !(value isa Bool)
    kind === :string && return value isa AbstractString
    kind === :symbol && return value isa Symbol
    kind === :reference && return value isa NodeRef
    kind === :list && return value isa Tuple || value isa AbstractVector
    throw(ArgumentError("unknown portable schema value kind :$kind"))
end

function _default_rule_message(rule::ValidationRule, attribute_name::Symbol)
    kind = rule.kind
    kind === :finite && return "attribute :$attribute_name must be finite"
    kind === :gt && return "attribute :$attribute_name must be > $(rule.parameters.value)"
    kind === :ge && return "attribute :$attribute_name must be >= $(rule.parameters.value)"
    kind === :lt && return "attribute :$attribute_name must be < $(rule.parameters.value)"
    kind === :le && return "attribute :$attribute_name must be <= $(rule.parameters.value)"
    kind === :nonempty && return "attribute :$attribute_name must not be empty"
    kind === :one_of && return "attribute :$attribute_name must be one of $(rule.parameters.values)"
    return "attribute :$attribute_name failed validation rule :$kind"
end

function _check_rule(rule::ValidationRule, value)
    try
        return check_validation_rule(Val(rule.kind), value, rule.parameters)
    catch err
        if err isa MethodError && err.f === check_validation_rule
            throw(ArgumentError("unknown validation rule :$(rule.kind)"))
        end
        rethrow()
    end
end

"""
    validate(node::SemanticNode, schema::NodeSchema) -> ValidationReport

Validate one semantic node against a local, domain-neutral schema.

This checks node kind, required/extra attributes, portable value kinds, and
value-local rules. If an attribute permits symbolic references and currently
contains a `NodeRef`, its concrete type/rules are deferred until resolution.
"""
function validate(node::SemanticNode, schema::NodeSchema)
    diagnostics = DiagnosticMessage[]

    if node.kind != schema.kind
        push!(diagnostics, error_diagnostic(
            :schema_kind_mismatch,
            "expected node kind $(schema.kind), got $(node.kind)";
            expected = schema.kind,
            actual = node.kind,
        ))
    end

    actual_names = Set(first.(node.attributes))
    schema_names = Set(getfield.(schema.attributes, :name))

    for field in schema.attributes
        if !(field.name in actual_names)
            if field.required
                push!(diagnostics, error_diagnostic(
                    :missing_attribute,
                    "missing required attribute :$(field.name)";
                    attribute = field.name,
                ))
            end
            continue
        end

        value = attribute(node, field.name)
        if value isa NodeRef && field.allow_ref
            continue
        end

        local kind_ok::Bool
        try
            kind_ok = _matches_value_kind(value, field.value_kind)
        catch err
            if err isa ArgumentError
                push!(diagnostics, error_diagnostic(
                    :unknown_value_kind,
                    sprint(showerror, err);
                    attribute = field.name,
                    value_kind = field.value_kind,
                ))
                continue
            end
            rethrow()
        end

        if !kind_ok
            push!(diagnostics, error_diagnostic(
                :attribute_type,
                "attribute :$(field.name) must be :$(field.value_kind), got $(typeof(value))";
                attribute = field.name,
                expected = field.value_kind,
                actual = Symbol(string(typeof(value))),
            ))
            continue
        end

        for rule in field.rules
            passed = try
                _check_rule(rule, value)
            catch err
                if err isa ArgumentError
                    push!(diagnostics, error_diagnostic(
                        :unknown_validation_rule,
                        sprint(showerror, err);
                        attribute = field.name,
                        rule = rule.kind,
                    ))
                    false
                else
                    rethrow()
                end
            end
            passed && continue

            message = isempty(rule.message) ? _default_rule_message(rule, field.name) : rule.message
            push!(diagnostics, error_diagnostic(
                :validation_rule_failed,
                message;
                attribute = field.name,
                rule = rule.kind,
                parameters = rule.parameters,
            ))
        end
    end

    if !schema.allow_extra
        for name in sort!(collect(setdiff(actual_names, schema_names)); by = String)
            push!(diagnostics, error_diagnostic(
                :unexpected_attribute,
                "unexpected attribute :$name";
                attribute = name,
            ))
        end
    end

    return ValidationReport(
        schema.kind,
        isempty(diagnostics),
        diagnostics,
        (; schema = schema.kind),
    )
end

"""
    validated_node(schema, [name]; kwargs...) -> SemanticNode

Construct a semantic node and require it to satisfy `schema` immediately.

This is the Pydantic-like fail-fast authoring path for downstream declarative
APIs. Generic tree editing can still mutate a node later, in which case callers
can run `validate(node, schema)` again before resolution or execution.
"""
function validated_node(
    schema::NodeSchema,
    name::Union{Nothing,Symbol} = nothing;
    kwargs...,
)
    node = SemanticNode(schema.kind, name; kwargs...)
    result = validate(node, schema)
    isvalid(result) && return node

    messages = join((diagnostic.message for diagnostic in result.diagnostics), "; ")
    throw(ArgumentError("invalid $(schema.kind) node: $messages"))
end

to_namedtuple(rule::ValidationRule) = (
    kind = rule.kind,
    parameters = rule.parameters,
    message = rule.message,
)

to_namedtuple(field::AttributeSchema) = (
    name = field.name,
    value_kind = field.value_kind,
    required = field.required,
    allow_ref = field.allow_ref,
    rules = to_namedtuple.(field.rules),
)

to_namedtuple(schema::NodeSchema) = (
    kind = schema.kind,
    attributes = to_namedtuple.(schema.attributes),
    allow_extra = schema.allow_extra,
)
