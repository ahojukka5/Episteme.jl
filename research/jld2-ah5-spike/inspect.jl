using HDF5

function _h5dump_bin()
    for path in (
        get(ENV, "H5DUMP", ""),
        "/flash/project_462001245/juaho/.julia/artifacts/2b2691d3d3239f1a5b3d2c8322594a482253faae/bin/h5dump",
    )
        isempty(path) && continue
        isfile(path) && return path
    end
    sys = Sys.which("h5dump")
    return sys === nothing ? nothing : sys
end

function h5dump_excerpt(path::AbstractString; max_chars::Int = 8000)
    bin = _h5dump_bin()
    bin === nothing && return "(h5dump not available)"
    try
        out = read(`$bin -n $path`, String)
        return length(out) <= max_chars ? out : out[1:max_chars] * "\n… truncated …\n"
    catch err
        return "(h5dump failed: $(sprint(showerror, err)))"
    end
end

function hdf5_tree(path::AbstractString)
    lines = String[]
    h5open(path, "r") do f
        _walk_h5!(lines, f, "/")
    end
    return join(lines, "\n")
end

function _walk_h5!(lines, parent, prefix)
    for name in keys(parent)
        obj = parent[name]
        path = prefix == "/" ? "/" * name : prefix * "/" * name
        if obj isa HDF5.Group
            push!(lines, "GROUP $path")
            _walk_h5!(lines, obj, path)
        elseif obj isa HDF5.Dataset
            dims = size(obj)
            dtype = string(HDF5.datatype(obj))
            push!(lines, "DATASET $path dims=$(dims) dtype=$(dtype)")
        elseif obj isa HDF5.Datatype
            push!(lines, "DATATYPE $path")
        else
            push!(lines, "$(typeof(obj)) $path")
        end
    end
    return lines
end

function hdf5_root_names(path::AbstractString)
    h5open(path, "r") do f
        return collect(keys(f))
    end
end
