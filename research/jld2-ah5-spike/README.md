# JLD2 / AH5 persistence spike

Research fixture for [OodiCore.jl#47](https://github.com/ahojukka5/OodiCore.jl/issues/47).
It does **not** add JLD2 or HDF5 to the OodiCore package.

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.instantiate()'
julia --project=. run_spike.jl
```

Outputs:

- `out/` generated files (gitignored)
- `excerpts/` compact HDF5 trees and the run log
- `FINDINGS.md` architecture note and recommendation
