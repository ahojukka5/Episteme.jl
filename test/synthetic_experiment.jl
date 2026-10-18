# A deliberately synthetic scientific experiment used by Episteme's tests.
# It is NOT a scientific model or a claim about measured physical data.
# Keep it independent of Episteme and every domain owner package so that the
# normal package test suite has no private repository dependencies.
module SyntheticCalibration

export calibrate, observations, degenerate_observations

# Mock measurements of a linear response y = 1 + 2x.
observations() = [
    0.0  1.0  2.0  3.0  4.0
    1.0  3.0  5.0  7.0  9.0
]

# No unique linear fit is possible if all measurement coordinates coincide.
degenerate_observations() = [
    2.0  2.0  2.0
    1.0  3.0  5.0
]

"""
    calibrate(readings)

Fit a line with an intercept to synthetic two-row (x, y) measurements.
This fixture is pure Julia and has no dependency on Episteme or Delone.
"""
function calibrate(readings::AbstractMatrix{<:Real})
    size(readings, 1) == 2 ||
        throw(ArgumentError("mock observations must have two rows"))
    npoints = size(readings, 2)
    npoints >= 2 ||
        throw(ArgumentError("mock calibration needs at least two observations"))
    all(isfinite, readings) ||
        throw(ArgumentError("mock observations must be finite"))

    mean_x = sum(readings[1, i] for i in axes(readings, 2)) / npoints
    mean_y = sum(readings[2, i] for i in axes(readings, 2)) / npoints
    variance_x = sum(
        (readings[1, i] - mean_x)^2 for i in axes(readings, 2)
    )
    variance_x > 0 ||
        throw(ArgumentError("mock calibration needs distinct input values"))
    slope = sum(
        (readings[1, i] - mean_x) * (readings[2, i] - mean_y)
        for i in axes(readings, 2)
    ) / variance_x
    intercept = mean_y - slope * mean_x
    max_residual = maximum(
        abs(readings[2, i] - (slope * readings[1, i] + intercept))
        for i in axes(readings, 2)
    )

    # A portable, domain-neutral result that Episteme can hash directly.
    return (; slope = Float64(slope), intercept = Float64(intercept),
        max_residual = Float64(max_residual), npoints)
end

end # module SyntheticCalibration
