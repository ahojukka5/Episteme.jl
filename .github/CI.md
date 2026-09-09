# Continuous integration

Pull requests and master pushes run the complete package suite on the latest
stable Julia (`1` channel), using the Julia dependency cache.

Compatibility with the oldest supported Julia, 1.10, is checked alongside
latest Julia every Sunday at 05:37 UTC. Manual dispatch runs the same matrix
for a selected branch, including when a dependency or compatibility change
needs that evidence before merge.
