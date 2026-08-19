# Clean-process forensic reader for issue #47.
# Must not load OodiCore or types.jl. Only JLD2 + HDF5.

using JLD2
using HDF5

length(ARGS) >= 2 || error("usage: forensic_load.jl FILE.md OUT.md")
path, outpath = ARGS[1], ARGS[2]

function _show(x)
    return sprint(show, MIME("text/plain"), x)
end

io = IOBuffer()
println(io, "# Clean-process forensic load")
println(io)
println(io, "Process loaded only JLD2 and HDF5. No `types.jl`, no OodiCore.")
println(io)

println(io, "## Normal `load`")
println(io)
try
    data = load(path)
    println(io, "ok: true")
    println(io)
    println(io, "```")
    println(io, _show(data))
    println(io, "```")
    println(io)
    for (k, v) in data
        println(io, "- `", k, "` typeof = `", typeof(v), "`")
    end
catch err
    println(io, "ok: false")
    println(io)
    println(io, "```")
    println(io, sprint(showerror, err))
    println(io, "```")
end
println(io)

println(io, "## `load(; plain = true)`")
println(io)
try
    data = load(path; plain = true)
    println(io, "ok: true")
    println(io)
    println(io, "```")
    println(io, _show(data))
    println(io, "```")
    println(io)
    for (k, v) in data
        println(io, "- `", k, "` typeof = `", typeof(v), "`")
    end
catch err
    println(io, "ok: false")
    println(io)
    println(io, "```")
    println(io, sprint(showerror, err))
    println(io, "```")
end
println(io)

println(io, "## HDF5.jl generic inspect")
println(io)
try
    h5open(path, "r") do f
        println(io, "root names: ", collect(keys(f)))
        println(io)
        for name in keys(f)
            obj = f[name]
            println(io, "- `", name, "` ", typeof(obj))
            if obj isa HDF5.Dataset
                println(io, "  dims=", size(obj), " dtype=", HDF5.datatype(obj))
            elseif obj isa HDF5.Group
                println(io, "  children=", collect(keys(obj)))
            end
        end
    end
    println(io, "hdf5_ok: true")
catch err
    println(io, "hdf5_ok: false")
    println(io, sprint(showerror, err))
end

mkpath(dirname(outpath))
open(outpath, "w") do f
    write(f, String(take!(io)))
end
