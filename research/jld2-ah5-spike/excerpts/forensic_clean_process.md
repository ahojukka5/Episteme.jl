# Clean-process forensic load

Process loaded only JLD2 and HDF5. No `types.jl`, no Episteme.

## Normal `load`

ok: true

```
Dict{String, Any} with 2 entries:
  "box" => Reconstruct@Box((1.0, 2.0, 3.0))
  "sector" => Reconstruct@ModelState((4, 2, 0))
```

- `box` typeof = `JLD2.ReconstructedStatic{:Box, (:width, :depth, :height), Tuple{Float64, Float64, Float64}}`
- `sector` typeof = `JLD2.ReconstructedStatic{:ModelState, (:sites, :particles, :Sz), Tuple{Int64, Int64, Int64}}`

## `load(; plain = true)`

ok: true

```
Dict{String, Any} with 2 entries:
  "box" => (width = 1.0, depth = 2.0, height = 3.0)
  "sector" => (sites = 4, particles = 2, Sz = 0)
```

- `box` typeof = `@NamedTuple{width::Float64, depth::Float64, height::Float64}`
- `sector` typeof = `@NamedTuple{sites::Int64, particles::Int64, Sz::Int64}`

## HDF5.jl generic inspect

root names: ["_types", "box", "sector"]

- `_types` HDF5.Group
  children=["00000001", "00000002", "00000003"]
- `box` HDF5.Dataset
  dims=() dtype=HDF5.Datatype: /_types/00000002 H5T_COMPOUND {
      H5T_IEEE_F64LE "width" : 0;
      H5T_IEEE_F64LE "depth" : 8;
      H5T_IEEE_F64LE "height" : 16;
   }
- `sector` HDF5.Dataset
  dims=() dtype=HDF5.Datatype: /_types/00000003 H5T_COMPOUND {
      H5T_STD_I64LE "sites" : 0;
      H5T_STD_I64LE "particles" : 8;
      H5T_STD_I64LE "Sz" : 16;
   }
hdf5_ok: true
