# Escape-time Mandelbrot.
function escape_time(c::Complex{Float64}; maxiter::Int = 100)
    z = 0.0 + 0.0im
    for n in 1:maxiter
        z = z^2 + c
        abs2(z) > 4.0 && return n
    end
    return maxiter
end

grid = [escape_time(complex(x, y)) for y in range(-1, 1, length = 5), x in range(-2, 0.5, length = 9)]
println(grid)
