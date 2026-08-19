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
- `excerpts/forensic_clean_process.md` from a second Julia process
  that loads only JLD2/HDF5
- `FINDINGS.md` architecture note and recommendation

`experiment_status` in the run log distinguishes completed vs
passed/qualified. Interop is qualified as `jld2_created_files_only`;
parallel as `serial_analogue_only`.
