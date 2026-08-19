# Reproducible JLD2/AH5 persistence spike for issue #47.
# Does not add JLD2 or HDF5 to the Episteme package itself.

using Test
using SparseArrays
using JLD2
using HDF5
using Episteme

include("types.jl")
include("inspect.jl")

using .GeometrySpike
using .DomainSpike

JLD2.rconvert(::Type{ModelStateV2}, nt::NamedTuple) =
    ModelStateV2(nt.sites, nt.particles, Float64(nt.Sz), 0)

const ROOT = @__DIR__
const OUT = joinpath(ROOT, "out")
const EXCERPTS = joinpath(ROOT, "excerpts")
mkpath(OUT)
mkpath(EXCERPTS)

const FINDINGS = Dict{String,Any}()

logstep(msg) = println("==> ", msg)

function _status(; completed::Bool, passed, qualified::AbstractString = "", notes::AbstractString = "")
    return Dict{String,Any}(
        "completed" => completed,
        "passed" => passed,
        "qualified" => qualified,
        "notes" => notes,
    )
end

function _with_stderr(thunk)
    path, io = mktemp()
    try
        result = redirect_stderr(io) do
            thunk()
        end
        flush(io)
        seekstart(io)
        return result, read(io, String)
    finally
        close(io)
        rm(path; force = true)
    end
end

function _write_text(path, text)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, text)
    end
    return path
end

function archive_fixture()
    geom = ArchiveObject(
        ObjectId("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        RevisionId("11111111-1111-4111-8111-111111111111");
        namespace = ArchiveNamespace(:monge; display_name = "Monge.jl"),
        kind = Symbol("monge/box"),
        schema = SchemaRef(:monge, "box", "1.0.0"),
    )
    mesh = ArchiveObject(
        ObjectId("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        RevisionId("22222222-2222-4222-8222-222222222222");
        namespace = ArchiveNamespace(:delone; display_name = "Delone.jl"),
        kind = Symbol("delone/mesh"),
        schema = SchemaRef(:delone, "mesh", "1.0.0"),
        references = [ArchiveReference(
            :geometry,
            geom.object_id;
            revision_id = geom.revision_id,
        )],
        provenance = ProvenanceRefs(;
            software_environment = SoftwareEnvironmentId("env-1"),
        ),
    )
    return ArchiveGraph([geom, mesh]; heads = [
        WorkflowHead(WorkflowHeadId("head-main"), :main, mesh.revision_id),
    ])
end

function semantic_fixture()
    box = Box(0.4, 0.5, 2.0)
    dual = DualLike(1.4, 0.1)
    plate = SemanticNode(
        Symbol("monge/rectangle"),
        :plate;
        width = 10.0,
        material = box,
        dual = dual,
        status = running,
        maybe = nothing,
        tags = (:cad, :demo),
        lookup = Dict(:id => 7, :name => "plate"),
        extras = (units = "m", frame = "box"),
    )
    block = SemanticNode(
        Symbol("monge/extrude"),
        :block;
        profile = NodeRef(:plate),
        distance = 3.0,
    )
    model = SemanticNode(:geometry, :demo)
    push!(model, plate)
    push!(model, block)
    return model, box, dual
end

# ---------------------------------------------------------------------------
# 1. Julia-native round-trip
# ---------------------------------------------------------------------------

function experiment_roundtrip()
    logstep("1. Julia-native round-trip")
    path = joinpath(OUT, "roundtrip.ah5")
    model, box, dual = semantic_fixture()
    graph = archive_fixture()
    sector = ModelState(8, 6, 0)
    mesh = Mesh{Float64}(rand(3, 4), [1 2 3 4; 5 6 7 8])
    counter = Counter(3)
    nt = (a = 1, b = :sym)
    tup = (1, 2.0, "x")
    sparse_m = spdiagm(0 => [1.0, 2.0, 3.0])
    union_val::Union{Nothing,Float64} = 1.5
    shared = box

    a = CycleNode("a", nothing)
    b = CycleNode("b", a)
    a.other = b

    jldopen(path, "w") do f
        f["semantic"] = model
        f["graph"] = graph
        f["schema"] = SchemaRef(:oodi, "field", "1.0.0")
        f["monge_box"] = box
        f["model_state"] = sector
        f["mesh"] = mesh
        f["counter"] = counter
        f["namedtuple"] = nt
        f["tuple"] = tup
        f["dict"] = Dict("k" => 1, "m" => 2)
        f["enum"] = done
        f["nothing"] = nothing
        f["union"] = union_val
        f["shared_a"] = shared
        f["shared_b"] = shared
        f["cycle"] = a
        f["sparse"] = sparse_m
        f["array"] = [1, 2, 3]
        f["ptr"] = Ptr{Cvoid}()
    end

    loaded = jldopen(path, "r") do f
        Dict(name => f[name] for name in keys(f) if name != "_types")
    end

    checks = Dict{String,Bool}()
    checks["semantic_kind"] = loaded["semantic"].kind === :geometry
    checks["custom_box_in_tree"] = attribute(loaded["semantic"].children[1], :material) == box
    checks["dual_in_tree"] = attribute(loaded["semantic"].children[1], :dual) == dual
    checks["noderef"] = attribute(loaded["semantic"].children[2], :profile) == NodeRef(:plate)
    checks["archive_graph"] = to_namedtuple(loaded["graph"]) == to_namedtuple(graph)
    checks["schema_ref"] = loaded["schema"] == SchemaRef(:oodi, "field", "1.0.0")
    checks["monge_box"] = loaded["monge_box"] == box
    checks["model_state"] = loaded["model_state"] == sector
    checks["mesh_parametric"] = loaded["mesh"].connectivity == mesh.connectivity
    checks["mutable_counter"] = loaded["counter"].n == 3
    checks["namedtuple"] = loaded["namedtuple"] == nt
    checks["tuple"] = loaded["tuple"] == tup
    checks["enum"] = loaded["enum"] === done
    checks["nothing"] = loaded["nothing"] === nothing
    checks["union"] = loaded["union"] == 1.5
    checks["array"] = loaded["array"] == [1, 2, 3]
    checks["sparse"] = loaded["sparse"] == sparse_m
    checks["shared_values_equal"] = try
        loaded["shared_a"] == loaded["shared_b"] == box
    catch
        false
    end
    checks["shared_identity"] = try
        loaded["shared_a"] === loaded["shared_b"]
    catch
        false
    end
    checks["cycle_identity"] = try
        c = loaded["cycle"]
        c.other.other === c
    catch
        false
    end
    ptr_ok = try
        loaded["ptr"] isa Ptr
    catch
        false
    end
    checks["ptr_accepted"] = ptr_ok

    FINDINGS["roundtrip_checks"] = checks
    FINDINGS["roundtrip_file"] = path
    FINDINGS["jld2_root_names"] = jldopen(path, "r") do f
        collect(keys(f))
    end
    value_keys = setdiff(keys(checks), Set(["shared_identity", "cycle_identity"]))
    value_ok = all(checks[k] for k in value_keys)
    return _status(;
        completed = true,
        passed = value_ok,
        qualified = value_ok ? "value_roundtrip" : "value_roundtrip_failed",
        notes = "shared_identity=$(checks["shared_identity"]); cycle_identity=$(checks["cycle_identity"])",
    )
end

# ---------------------------------------------------------------------------
# 2. Physical HDF5 representation
# ---------------------------------------------------------------------------

function experiment_inspect()
    logstep("2. Inspect physical HDF5 representation")
    path = joinpath(OUT, "roundtrip.ah5")
    tree = hdf5_tree(path)
    dumpn = h5dump_excerpt(path)
    _write_text(joinpath(EXCERPTS, "roundtrip_hdf5_tree.txt"), tree)
    _write_text(joinpath(EXCERPTS, "roundtrip_h5dump_n.txt"), dumpn)
    names = hdf5_root_names(path)
    FINDINGS["hdf5_root_names"] = names
    FINDINGS["has_types_group"] = "_types" in names
    FINDINGS["jld2_reserved"] = filter(n -> startswith(n, "_"), names)
    FINDINGS["inspectable_with_hdf5jl"] = true
    FINDINGS["h5dump_available"] = _h5dump_bin() !== nothing
    return _status(;
        completed = true,
        passed = !isempty(tree),
        qualified = "hdf5jl_tree",
        notes = _h5dump_bin() === nothing ? "h5dump missing" : "h5dump present but may fail if MPI-linked",
    )
end

# ---------------------------------------------------------------------------
# 3. JLD2 + HDF5.jl interoperability in the same file
# ---------------------------------------------------------------------------

function _record(results, label, thunk)
    try
        results[label] = thunk()
    catch err
        results[label] = false
        results[label * "_error"] = sprint(showerror, err)
    end
    return results[label]
end

function experiment_interop()
    logstep("3. JLD2 + HDF5.jl same-file interoperability")
    results = Dict{String,Any}()

    # 3.1 JLD2 create -> HDF5.jl append -> JLD2 reread
    p1 = joinpath(OUT, "interop_jld2_then_hdf5.ah5")
    isfile(p1) && rm(p1)
    jldopen(p1, "w") do f
        f["episteme/format"] = "AH5"
        f["packages/monge/box"] = Box(1.0, 2.0, 3.0)
        f["objects/geom"] = archive_fixture().objects[1]
    end
    h5open(p1, "r+") do f
        g = haskey(f, "data") ? f["data"] : create_group(f, "data")
        g["field"] = collect(1:16)
        attrs = attributes(g["field"])
        attrs["units"] = "K"
    end
    _record(results, "jld2_then_hdf5_jld2_reads", () -> jldopen(p1, "r") do f
        f["episteme/format"] == "AH5" && f["packages/monge/box"] == Box(1.0, 2.0, 3.0)
    end)
    _record(results, "jld2_then_hdf5_hdf5_reads", () -> h5open(p1, "r") do f
        read(f["data/field"]) == collect(1:16)
    end)
    _record(results, "jld2_then_hdf5_jld2_keys", () -> jldopen(p1, "r") do f
        collect(keys(f))
    end)
    _write_text(joinpath(EXCERPTS, "interop_jld2_then_hdf5_tree.txt"), hdf5_tree(p1))

    # 3.2 HDF5.jl create -> JLD2 append -> HDF5.jl reread
    p2 = joinpath(OUT, "interop_hdf5_then_jld2.ah5")
    isfile(p2) && rm(p2)
    h5open(p2, "w") do f
        create_group(f, "episteme")
        f["episteme/format"] = "AH5"
        create_group(f, "data")
        f["data/mesh_coords"] = rand(3, 8)
    end
    _, write_warn = _with_stderr() do
        _record(results, "hdf5_then_jld2_write", () -> jldopen(p2, "r+") do f
            f["packages/example/sector"] = ModelState(4, 2, 0)
            f["schemas/example/model-state"] = SchemaRef(:example, "model-state", "1.0.0")
            true
        end)
    end
    results["hdf5_then_jld2_write_stderr"] = write_warn
    _, read_warn = _with_stderr() do
        _record(results, "hdf5_then_jld2_jld2_reads", () -> jldopen(p2, "r") do f
            f["packages/example/sector"] == ModelState(4, 2, 0)
        end)
    end
    results["hdf5_then_jld2_read_stderr"] = read_warn
    _record(results, "hdf5_then_jld2_hdf5_reads", () -> h5open(p2, "r") do f
        size(read(f["data/mesh_coords"])) == (3, 8)
    end)
    _record(results, "hdf5_then_jld2_jld2_keys", () -> jldopen(p2, "r") do f
        collect(keys(f))
    end)
    isfile(p2) && _write_text(joinpath(EXCERPTS, "interop_hdf5_then_jld2_tree.txt"), hdf5_tree(p2))

    # 3.2a top-level JLD2 value into an HDF5.jl-created file
    p2a = joinpath(OUT, "interop_hdf5_then_jld2_toplevel.ah5")
    isfile(p2a) && rm(p2a)
    h5open(p2a, "w") do f
        f["seed"] = 1
    end
    _, p2a_warn = _with_stderr() do
        _record(results, "hdf5_then_jld2_toplevel_write", () -> jldopen(p2a, "r+") do f
            f["top"] = 42
            true
        end)
    end
    results["hdf5_then_jld2_toplevel_stderr"] = p2a_warn
    _record(results, "hdf5_then_jld2_toplevel_read", () -> jldopen(p2a, "r") do f
        f["top"] == 42
    end)
    _record(results, "hdf5_then_jld2_toplevel_keys", () -> jldopen(p2a, "r") do f
        collect(keys(f))
    end)

    # 3.2b write into a group HDF5.jl pre-created
    p2b = joinpath(OUT, "interop_hdf5_then_jld2_pregroup.ah5")
    isfile(p2b) && rm(p2b)
    h5open(p2b, "w") do f
        create_group(f, "packages")
        f["packages/seed"] = 0
    end
    _, p2b_warn = _with_stderr() do
        _record(results, "hdf5_then_jld2_pregroup_write", () -> jldopen(p2b, "r+") do f
            f["packages/sector"] = ModelState(4, 2, 0)
            true
        end)
    end
    results["hdf5_then_jld2_pregroup_stderr"] = p2b_warn
    _record(results, "hdf5_then_jld2_pregroup_read", () -> jldopen(p2b, "r") do f
        f["packages/sector"] == ModelState(4, 2, 0)
    end)
    _record(results, "hdf5_then_jld2_pregroup_keys", () -> jldopen(p2b, "r") do f
        collect(keys(f))
    end)

    # 3.3 Repeated alternating serial writes
    p3 = joinpath(OUT, "interop_alternating.ah5")
    isfile(p3) && rm(p3)
    jldopen(p3, "w") do f
        f["rev/0"] = 0
    end
    alt_ok = true
    alt_err = ""
    try
        for i in 1:4
            h5open(p3, "r+") do f
                g = haskey(f, "data") ? f["data"] : create_group(f, "data")
                g["step_$i"] = fill(Float64(i), 8)
            end
            jldopen(p3, "r+") do f
                f["rev/$i"] = i
            end
            jldopen(p3, "r") do f
                alt_ok &= f["rev/$i"] == i
            end
            h5open(p3, "r") do f
                alt_ok &= read(f["data/step_$i"]) == fill(Float64(i), 8)
            end
        end
    catch err
        alt_ok = false
        alt_err = sprint(showerror, err)
    end
    results["alternating_cycles"] = 4
    results["alternating_ok"] = alt_ok
    results["alternating_error"] = alt_err
    isfile(p3) && _write_text(joinpath(EXCERPTS, "interop_alternating_tree.txt"), hdf5_tree(p3))

    # 3.4 Chunked / compressed / extendible via HDF5.jl then JLD2 reread
    p4 = joinpath(OUT, "interop_chunked.ah5")
    isfile(p4) && rm(p4)
    jldopen(p4, "w") do f
        f["objects/index"] = ["field-1"]
    end
    _record(results, "chunked_hdf5_write", () -> h5open(p4, "r+") do f
        dset = create_dataset(
            f,
            "data/events",
            Float64,
            ((0,), (-1,));
            chunk = (8,),
            compress = 3,
        )
        HDF5.set_extent_dims(dset, (16,))
        dset[1:16] = Float64.(1:16)
        true
    end)
    _record(results, "chunked_jld2_index", () -> jldopen(p4, "r") do f
        f["objects/index"] == ["field-1"]
    end)
    _record(results, "chunked_hdf5_data", () -> h5open(p4, "r") do f
        read(f["data/events"]) == Float64.(1:16)
    end)

    # 3.5 Hazard: overwriting a JLD2 path from HDF5.jl
    p5 = joinpath(OUT, "interop_overwrite_hazard.ah5")
    isfile(p5) && rm(p5)
    jldopen(p5, "w") do f
        f["keep"] = Box(1.0, 1.0, 1.0)
        f["victim"] = "jld2-owned"
    end
    overwrite_error = ""
    try
        h5open(p5, "r+") do f
            delete_object(f, "victim")
            f["victim"] = [1, 2, 3]
        end
    catch err
        overwrite_error = sprint(showerror, err)
    end
    after = try
        jldopen(p5, "r") do f
            (f["keep"] == Box(1.0, 1.0, 1.0), haskey(f, "victim"))
        end
    catch err
        (false, sprint(showerror, err))
    end
    results["overwrite_error"] = overwrite_error
    results["overwrite_after"] = after

    FINDINGS["interop"] = results
    jld2_first_ok = results["jld2_then_hdf5_jld2_reads"] === true &&
        results["jld2_then_hdf5_hdf5_reads"] === true &&
        results["alternating_ok"] === true &&
        results["chunked_jld2_index"] === true &&
        results["chunked_hdf5_data"] === true
    hdf5_first_ok = results["hdf5_then_jld2_jld2_reads"] === true &&
        get(results, "hdf5_then_jld2_toplevel_read", false) === true &&
        get(results, "hdf5_then_jld2_pregroup_read", false) === true
    return _status(;
        completed = true,
        passed = jld2_first_ok && hdf5_first_ok,
        qualified = jld2_first_ok && !hdf5_first_ok ? "jld2_created_files_only" :
            (jld2_first_ok ? "both_directions" : "failed"),
        notes = "hdf5-first nested=$(results["hdf5_then_jld2_jld2_reads"]) toplevel=$(get(results, "hdf5_then_jld2_toplevel_read", nothing)) pregroup=$(get(results, "hdf5_then_jld2_pregroup_read", nothing))",
    )
end

# ---------------------------------------------------------------------------
# 4. Heavy-data path
# ---------------------------------------------------------------------------

function experiment_heavy()
    logstep("4. Heavy-data path")
    n = 200_000
    dense = randn(n)
    coords = rand(3, 20_000)
    conn = rand(1:20_000, 4, 10_000)
    sparse_m = sprand(2_000, 2_000, 0.002)
    results = Dict{String,Any}()

    p_jld2 = joinpath(OUT, "heavy_jld2.ah5")
    t = @elapsed jldopen(p_jld2, "w") do f
        f["objects/field"] = archive_fixture().objects[1]
        f["data/dense"] = dense
        f["data/coords"] = coords
        f["data/conn"] = conn
        f["data/sparse"] = sparse_m
    end
    t_read = @elapsed jldopen(p_jld2, "r") do f
        @assert f["data/dense"] == dense
        @assert f["objects/field"].kind === Symbol("monge/box")
    end
    results["jld2_write_s"] = t
    results["jld2_read_s"] = t_read
    results["jld2_bytes"] = filesize(p_jld2)

    p_mix = joinpath(OUT, "heavy_mixed.ah5")
    isfile(p_mix) && rm(p_mix)
    t_meta = @elapsed jldopen(p_mix, "w") do f
        f["objects/field"] = archive_fixture().objects[1]
        f["objects/field_data_ref"] = (
            object_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            dataset = "/data/dense",
        )
    end
    t_h5 = @elapsed h5open(p_mix, "r+") do f
        dset = create_dataset(
            f,
            "data/dense",
            Float64,
            (n,);
            chunk = (16_384,),
            compress = 3,
        )
        dset[:] = dense
        dset = create_dataset(f, "data/coords", Float64, size(coords); chunk = (3, 1024))
        dset[:, :] = coords
        f["data/conn"] = conn
    end
    t_reread = @elapsed begin
        meta = jldopen(p_mix, "r") do f
            f["objects/field_data_ref"]
        end
        values = h5open(p_mix, "r") do f
            read(f[meta.dataset])
        end
        @assert values == dense
    end
    results["mixed_meta_write_s"] = t_meta
    results["mixed_hdf5_write_s"] = t_h5
    results["mixed_reread_s"] = t_reread
    results["mixed_bytes"] = filesize(p_mix)
    results["heavy_not_duplicated"] = results["mixed_bytes"] < results["jld2_bytes"] * 1.5
    FINDINGS["heavy"] = results
    _write_text(joinpath(EXCERPTS, "heavy_mixed_tree.txt"), hdf5_tree(p_mix))
    return _status(;
        completed = true,
        passed = results["heavy_not_duplicated"] === true,
        qualified = "mixed_jld2_metadata_hdf5_arrays",
    )
end

# ---------------------------------------------------------------------------
# 5. Parallel-HDF5 path
# ---------------------------------------------------------------------------

function experiment_parallel()
    logstep("5. Parallel-HDF5 compatibility path")
    parallel = try
        HDF5.has_parallel()
    catch
        false
    end
    FINDINGS["hdf5_has_parallel"] = parallel
    FINDINGS["parallel_status"] = parallel ? "available" :
        "serial HDF5.jl/JLL build; JLD2 has no MPI writer"
    FINDINGS["parallel_followup"] = Dict(
        "module" => "cray-hdf5-parallel/1.14.3.5 or 1.12.2.11",
        "julia" => "MPI.jl then HDF5.jl with HDF5.API.set_libraries! on the parallel libhdf5",
        "protocol" => "rank 0 JLD2 metadata serial open/close; collective HDF5.jl dataset write; rank 0 JLD2 reopen",
        "must_not" => "rank-local JLD2 writers against the same file",
    )
    # Serial analogue of the intended HPC protocol.
    path = joinpath(OUT, "parallel_analogue.ah5")
    isfile(path) && rm(path)
    jldopen(path, "w") do f
        f["episteme/phase"] = "metadata"
        f["objects/problem"] = ModelState(8, 6, 0)
    end
    h5open(path, "r+") do f
        dset = create_dataset(f, "data/vector", Float64, (1024,); chunk = (256,))
        dset[:] = randn(1024)
    end
    ok = jldopen(path, "r") do f
        f["objects/problem"] == ModelState(8, 6, 0)
    end
    FINDINGS["parallel_serial_analogue_ok"] = ok
    return _status(;
        completed = true,
        passed = false,
        qualified = "serial_analogue_only; mpi_collective_write_not_run",
        notes = "HDF5.has_parallel()=$(parallel); analogue_ok=$(ok)",
    )
end

# ---------------------------------------------------------------------------
# 6. Type evolution
# ---------------------------------------------------------------------------

function experiment_evolution()
    logstep("6. Type evolution and migration")
    path = joinpath(OUT, "evolution.ah5")
    old = ModelState(8, 6, 0)
    jldsave(path; sector = old)
    loaded = load(
        path,
        "sector";
        typemap = Dict("Main.DomainSpike.ModelState" => JLD2.Upgrade(ModelStateV2)),
    )
    # Type name as stored may include the parent module path.
    loaded2 = loaded
    if !(loaded isa ModelStateV2)
        # Try the nested module name JLD2 actually wrote.
        stored = jldopen(path, "r") do f
            # fall back: remap whatever path was stored
            load(
                path,
                "sector";
                typemap = function (file, typepath, params)
                    endswith(typepath, "ModelState") &&
                        return JLD2.Upgrade(ModelStateV2)
                    return JLD2.default_typemap(file, typepath, params)
                end,
            )
        end
        loaded2 = stored
    end
    FINDINGS["evolution_loaded_type"] = string(typeof(loaded2))
    FINDINGS["evolution_ok"] = loaded2 isa ModelStateV2 &&
        loaded2.sites == 8 &&
        loaded2.Sz == 0.0
    FINDINGS["evolution_note"] =
        "JLD2 Upgrade reconstructs a NamedTuple of old fields then rconvert. " *
        "That is a Julia representation migration, not an Episteme schema migration."
    return _status(;
        completed = true,
        passed = FINDINGS["evolution_ok"],
        qualified = "julia_type_upgrade_not_episteme_schema",
    )
end

# ---------------------------------------------------------------------------
# 7. Missing-package / forensic read
# ---------------------------------------------------------------------------

function experiment_forensic()
    logstep("7. Missing-type / forensic read")
    path = joinpath(OUT, "forensic.ah5")
    jldsave(path; box = Box(1.0, 2.0, 3.0), sector = ModelState(4, 2, 0))
    tree = hdf5_tree(path)
    _write_text(joinpath(EXCERPTS, "forensic_hdf5_tree.txt"), tree)

    child = joinpath(ROOT, "forensic_load.jl")
    excerpt = joinpath(EXCERPTS, "forensic_clean_process.md")
    cmd = `$(Base.julia_cmd()) --project=$(ROOT) $(child) $(path) $(excerpt)`
    logbuf = IOBuffer()
    proc_ok = false
    try
        run(pipeline(cmd, stdout = logbuf, stderr = logbuf))
        proc_ok = true
    catch err
        println(logbuf, sprint(showerror, err))
    end
    child_output = String(take!(logbuf))
    _write_text(joinpath(EXCERPTS, "forensic_clean_process_log.txt"), child_output)
    report = isfile(excerpt) ? read(excerpt, String) : ""
    FINDINGS["forensic_clean_process_ok"] = proc_ok
    FINDINGS["forensic_clean_process_log"] = child_output
    FINDINGS["forensic_clean_process_report"] = report
    FINDINGS["forensic_note"] =
        "The clean-process reader loads only JLD2 and HDF5. That is the " *
        "three-year-old-archive case: original modules are absent. " *
        "JLD2 reconstruction without the type is forensic, not an Episteme schema."
    return _status(;
        completed = proc_ok,
        passed = proc_ok && occursin("HDF5.jl generic inspect", report),
        qualified = "clean_process_without_types_jl",
        notes = first(split(report, '\n', limit = 8)),
    )
end

# ---------------------------------------------------------------------------
# 8. Portable vs Julia-native
# ---------------------------------------------------------------------------

function experiment_portability_notes()
    logstep("8. Portable vs Julia-native recommendation notes")
    FINDINGS["portability"] = Dict(
        "semantic_node_leaves" => "may remain Julia-native; #12 already allows arbitrary values",
        "archive_ids_schema_refs" => "should stay portable (plain structs already are)",
        "domain_payloads" => "Julia-native by default; portable subset only when interchange/replay without the package is required",
        "issue_34" => "portable declarative document remains a capability, not the default persistence path",
    )
    return _status(; completed = true, passed = nothing, qualified = "notes_only")
end

function write_results_markdown()
    io = IOBuffer()
    println(io, "# Spike run results")
    println(io)
    println(io, "Generated by `run_spike.jl`. See FINDINGS.md for interpretation.")
    println(io)
    for (k, v) in sort(collect(FINDINGS); by = first)
        println(io, "## ", k)
        println(io)
        println(io, "```")
        show(io, MIME("text/plain"), v)
        println(io)
        println(io, "```")
        println(io)
    end
    _write_text(joinpath(EXCERPTS, "run_results.md"), String(take!(io)))
end

function main()
    checks = Dict{String,Any}()
    for (name, fn) in (
        "roundtrip" => experiment_roundtrip,
        "inspect" => experiment_inspect,
        "interop" => experiment_interop,
        "heavy" => experiment_heavy,
        "parallel" => experiment_parallel,
        "evolution" => experiment_evolution,
        "forensic" => experiment_forensic,
        "portability" => experiment_portability_notes,
    )
        try
            checks[name] = fn()
        catch err
            checks[name] = false
            checks[name * "_error"] = sprint(showerror, err)
            @error "experiment failed" name exception = (err, catch_backtrace())
        end
    end
    FINDINGS["experiment_status"] = checks
    write_results_markdown()
    println()
    println("experiment_status = ")
    show(stdout, MIME("text/plain"), checks)
    println()
    println("excerpts in ", EXCERPTS)
    return checks
end

main()
