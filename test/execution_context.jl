@testset "execution facts are explicit and immutable" begin
    unknown = ExecutionContext()
    @test unknown.facts.hardware === nothing
    @test unknown.facts.rng === nothing
    @test isvalid(validate(unknown))
    @test !isempty(report(unknown).diagnostics)
    @test unknown.id != ExecutionContext(; devices=(), features=()).id
    devices = [(id="gpu-0", architecture="gfx90a", memory_bytes=64 * 1024^3),
        (id="gpu-1", architecture="gfx90a", memory_bytes=64 * 1024^3)]
    ranks = [(rank=0, device_ids=["gpu-0"], thread_count=1),
        (rank=1, device_ids=["gpu-1"], thread_count=1)]
    context = ExecutionContext(; devices, ranks, hardware=(cpu_architecture="x86_64",),
        numerics=(precision="Float64", deterministic=false, fast_math=false),
        parallelism=(rank_count=2,), features=["staged-halo"],
        plan_id=PlanId("plan"), revision_id=RevisionId("revision"),
        captured_at="2026-09-10T00:00:00Z", event_sequence=3)
    equivalent = ExecutionContext(; devices=reverse(devices), ranks=reverse(ranks),
        hardware=(cpu_architecture="x86_64",),
        numerics=(fast_math=false, deterministic=false, precision="Float64"),
        parallelism=(rank_count=2,), features=("staged-halo",),
        plan_id=PlanId("plan"), revision_id=RevisionId("revision"),
        captured_at="2026-09-10T00:00:00Z", event_sequence=3)
    @test context.id == equivalent.id
    @test report(context).metadata.cpu_architecture == "x86_64"
    @test report(context).metadata.device_count == 2
    @test report(context).metadata.precision == "Float64"
    @test report(unknown).metadata.rank_count === nothing
    empty!(devices)
    empty!(ranks[1].device_ids)
    @test length(context.facts.devices) == 2
    @test context.facts.ranks[1].device_ids == ("gpu-0",)
    @test to_namedtuple(from_namedtuple(ExecutionContext, to_namedtuple(context))) == to_namedtuple(context)
    @test ExecutionContext(numerics=(precision="Float64",)).id !=
        ExecutionContext(numerics=(precision="Float32",)).id
    @test ExecutionContext(hardware=(cpu_architecture="x86_64",)).id !=
        ExecutionContext(hardware=(cpu_architecture="aarch64",)).id
    registry = ExecutionContextRegistry((context, unknown, context))
    @test length(registry.contexts) == 2
    @test find_execution_context(registry, context.id) === context
    @test find_execution_context(registry, ExecutionContextId("missing")) === nothing
    @test to_namedtuple(from_namedtuple(ExecutionContextRegistry, to_namedtuple(registry))) == to_namedtuple(registry)
    @test isvalid(validate(registry))
    @test_throws ArgumentError from_namedtuple(ExecutionContext,
        merge(to_namedtuple(context), (; event_sequence=4)))
    @test_throws ArgumentError from_namedtuple(ExecutionContext,
        merge(to_namedtuple(context), (; environment="unrecognized")))
end

@testset "execution facts reject unsupported and unsafe inputs" begin
    for value in ("ghp_" * repeat("A", 36), "token=" * repeat("a", 20),
        "/home/someone/device", "C:\\Users\\someone\\device", "machine\nname")
        @test_throws ArgumentError ExecutionContext(hardware=(cpu_model=value,))
    end
    @test_throws ArgumentError ExecutionContext(hardware=(hostname="machine",))
    @test_throws ArgumentError ExecutionContext(hardware=Dict("cpu_model" => "CPU"))
    @test_throws ArgumentError ExecutionContext(numerics=(precision=IOBuffer(),))
    @test_throws ArgumentError ExecutionContext(numerics=(fast_math=1,))
    @test_throws ArgumentError ExecutionContext(parallelism=(rank_count=0,))
    @test_throws ArgumentError ExecutionContext(parallelism=(rank_count=true,))
    @test_throws ArgumentError ExecutionContext(devices=((id="same",), (id="same",)))
    @test_throws ArgumentError ExecutionContext(ranks=((rank=-1,),))
    @test_throws ArgumentError ExecutionContext(parallelism=(rank_count=1,), ranks=((rank=1,),))
    @test_throws ArgumentError ExecutionContext(ranks=((rank=0, device_ids=("gpu",)),))
    @test_throws ArgumentError ExecutionContext(devices=(), ranks=((rank=0, device_ids=("gpu",)),))
    @test_throws ArgumentError ExecutionContext(captured_at="2026-09-10T00:00:00+03:00")
    @test_throws ArgumentError ExecutionContext(captured_at="not-a-dateZ")
    @test_throws ArgumentError ExecutionContext(captured_at="2026Z")
    @test_throws ArgumentError ExecutionContext(captured_at="2026-09-10Z")
    @test ExecutionContext(captured_at="2026-09-10T00:00:00.123Z").facts.captured_at ==
        "2026-09-10T00:00:00.123Z"
end

@testset "RNG replay records declare their prerequisites" begin
    # A domain-owned toy algorithm: UInt64 modular LCG, with its seed schema
    # explicitly fixed by the toy algorithm version. No live RNG is archived.
    function toy_draws(seed, count)
        state = UInt64(seed)
        return [begin
            state = UInt64(6364136223846793005) * state + UInt64(1)
            state
        end for _ in 1:count]
    end
    context = ExecutionContext(rng=(algorithm="toy-lcg64", version="1", seed=42, replay="seed"))
    restored = from_namedtuple(ExecutionContext, to_namedtuple(context))
    @test restored.facts.rng.algorithm == "toy-lcg64"
    @test toy_draws(parse(UInt64, restored.facts.rng.seed), 10) == toy_draws(42, 10)
    @test context.id != ExecutionContext(rng=(algorithm="toy-lcg64", version="1", seed=43, replay="seed")).id
    state = ContentId("sha256:" * repeat("a", 64))
    continued = ExecutionContext(rng=(algorithm="toy-lcg64", version="1", state_content=state, replay="state"))
    @test from_namedtuple(ExecutionContext, to_namedtuple(continued)).facts.rng.state_content == state.value
    for rng in ((replay="seed",), (algorithm="toy", version="1", replay="seed"),
        (algorithm="toy", version="1", seed=-1), (algorithm="toy", version="1", replay="state"),
        (replay="automatic",), (state_content=IOBuffer(),))
        @test_throws ArgumentError ExecutionContext(; rng)
    end
end
