
# SciML Tools
using OrdinaryDiffEq, ModelingToolkit, DataDrivenDiffEq, SciMLSensitivity, DataDrivenSparse
using Optimization, OptimizationOptimisers, OptimizationOptimJL
#Pkg.add(["Optimization", "OptimizationOptimisers", "OptimizationOptimJL"])
# Standard Libraries
using LinearAlgebra, Statistics

# External Libraries
using ComponentArrays, Lux, Zygote, Plots, StableRNGs
#Pkg.add(["ComponentArrays", "Lux", "Zygote", "Plots", "StableRNGs"])
gr()

# Set a random seed for reproducible behaviour
rng = StableRNG(1111)


function lotka!(du, u, p, t)
    α, β, γ, δ = p
    du[1] = α * u[1] - β * u[2] * u[1]
    du[2] = γ * u[1] * u[2] - δ * u[2]
end

# Define the experimental parameter
tspan = (0.0, 5.0)
long_tspan = (0.0, 15.0)
u0 = 5.0f0 * rand(rng, 2)
p_ = [1.3, 0.9, 0.8, 1.8]
prob = ODEProblem(lotka!, u0, tspan, p_)
solution = solve(prob, Vern7(), abstol = 1e-12, reltol = 1e-12, saveat = 0.25)

true_prob = ODEProblem(lotka!, u0, long_tspan, p_)
true_solution = solve(true_prob, Vern7(), abstol = 1e-12, reltol = 1e-12, saveat = 0.25)


# Add noise in terms of the mean
X = Array(solution)
t = solution.t

x̄ = mean(X, dims = 2)
noise_magnitude = 5e-3
Xₙ = X .+ (noise_magnitude * x̄) .* randn(rng, eltype(X), size(X))

plot(true_solution.t, true_solution[1,:], alpha = 0.75, color = :blue, label = ["True Data" nothing])
#scatter!(t, transpose(Xₙ), color = :red, label = ["Noisy Data" nothing])
scatter!(t, Xₙ[1,:], color = :blue, label = ["Noisy Data" nothing])
plot!(true_solution.t, true_solution[2,:], alpha = 0.75, color = :orange, label = ["True Data" nothing])
scatter!(t, Xₙ[2,:], color = :orange, label = ["Noisy Data" nothing])
rbf(x) = exp.(-(x .^ 2))

# Multilayer FeedForward
const U = Lux.Chain(Lux.Dense(2, 5, rbf), Lux.Dense(5, 5, rbf), Lux.Dense(5, 5, rbf),
              Lux.Dense(5, 2))
# Get the initial parameters and state variables of the model
p, st = Lux.setup(rng, U)
const _st = st

function ude_dynamics!(du, u, p, t, p_true)
    û = U(u, p, _st)[1] # Network prediction
    du[1] = p_true[1] * u[1] + û[1]
    du[2] = -p_true[4] * u[2] + û[2]
end

# Closure with the known parameter
nn_dynamics!(du, u, p, t) = ude_dynamics!(du, u, p, t, p_)
# Define the problem
prob_nn = ODEProblem(nn_dynamics!, Xₙ[:, 1], tspan, p)

function predict(θ, X = Xₙ[:, 1], T = t)
    _prob = remake(prob_nn, u0 = X, tspan = (T[1], T[end]), p = θ)
    Array(solve(_prob, Vern7(), saveat = T,
                abstol = 1e-6, reltol = 1e-6,
                sensealg=QuadratureAdjoint(autojacvec=ReverseDiffVJP(true))))
end

function loss(θ)
    X̂ = predict(θ)
    mean(abs2, Xₙ .- X̂)
end

losses = Float64[]

callback = function (p, l)
    push!(losses, l)
    if length(losses) % 50 == 0
        println("Current loss after $(length(losses)) iterations: $(losses[end])")
    end
    return false
end

adtype = Optimization.AutoZygote()
optf = Optimization.OptimizationFunction((x, p) -> loss(x), adtype)
optprob = Optimization.OptimizationProblem(optf, ComponentVector{Float64}(p))

res1 = Optimization.solve(optprob, ADAM(), callback = callback, maxiters = 7000)
println("Training loss after $(length(losses)) iterations: $(losses[end])")

optprob2 = Optimization.OptimizationProblem(optf, res1.u)
res2 = Optimization.solve(optprob2, Optim.LBFGS(), callback = callback, maxiters = 2000)
println("Final training loss after $(length(losses)) iterations: $(losses[end])")

# Rename the best candidate
p_trained = res2.u

pl_losses = plot(1:5000, losses[1:5000], yaxis = :log10, xaxis = :log10,
                 xlabel = "Iterations", ylabel = "Loss", label = "ADAM", color = :blue)
plot!(5001:length(losses), losses[5001:end], yaxis = :log10, xaxis = :log10,
      xlabel = "Iterations", ylabel = "Loss", label = "BFGS", color = :red)

## Analysis of the trained network
# Plot the data and the approximation
ts = first(solution.t):(mean(diff(solution.t)) / 2):(last(solution.t)+10)
X̂ = predict(p_trained, Xₙ[:, 1], ts)
# Trained on noisy data vs real solution
pl_trajectory = plot(ts, transpose(X̂), xlabel = "t", ylabel = "x(t), y(t)", color = :red,
                     label = ["UDE Approximation" nothing])
scatter!(solution.t, transpose(Xₙ), color = :black, label = ["Measurements" nothing])
plot!(true_solution, alpha = 0.75, color = :black, label = ["True model" nothing])


plot(true_solution.t, true_solution[1,:], alpha = 0.75, color = :blue, label = ["True Data" nothing])
#scatter!(t, transpose(Xₙ), color = :red, label = ["Noisy Data" nothing])
scatter!(t, Xₙ[1,:], color = :blue, label = ["Noisy Data" nothing])
plot!(true_solution.t, true_solution[2,:], alpha = 0.75, color = :orange, label = ["True Data" nothing])
scatter!(t, Xₙ[2,:], color = :orange, label = ["Noisy Data" nothing])



pl_trajectory = plot(ts, X̂[1,:], xlabel = "t", ylabel = "x(t), y(t)", color = :blue,
                     label = ["UDE Approximation rabbits" nothing])
plot!(ts, X̂[2,:], xlabel = "t", ylabel = "x(t), y(t)", color = :orange, label = ["UDE Approximation wolves" nothing])
scatter!(t, Xₙ[1,:], color = :blue, label = ["Noisy rabbit observations" nothing])
scatter!(t, Xₙ[2,:], color = :orange, label = ["Noisy wolf observations" nothing])
plot!(true_solution.t, true_solution[1,:], alpha = 0.75, color = :blue, 
label = ["True rabbit population" nothing], linestyle=:dash)
plot!(true_solution.t, true_solution[2,:], alpha = 0.75, color = :orange, 
label = ["True wolf population" nothing], linestyle=:dash)

Ŷ = [-p_[2] * (X̂[1, :] .* X̂[2, :])'; p_[3] * (X̂[1, :] .* X̂[2, :])']
ideal_problem = DirectDataDrivenProblem(X̂, Ŷ)

λ = exp10.(-3:0.01:3)
opt = ADMM(λ)

options = DataDrivenCommonOptions(maxiters = 10_000,
                                  normalize = DataNormalization(ZScoreTransform),
                                  selector = bic, digits=1,
                                  data_processing = DataProcessing(split=0.9, shuffle=true, batchsize=30, rng=StableRNG(1111)))
@variables u[1:2]
b = polynomial_basis(u, 4)
basis = Basis(b, u);
ideal_res = solve(ideal_problem, basis, opt, options=options)
ideal_eqs = get_basis(ideal_res)
println(ideal_res)


println(get_parameter_map(ideal_eqs))
println(ideal_eqs)
println(get_parameter_map(ideal_eqs))
println()

Ŷ = U(X̂, p_trained, st)[1]
nn_problem = DirectDataDrivenProblem(X̂, Ŷ)


options = DataDrivenCommonOptions(maxiters = 15_000,
                                  normalize = DataNormalization(ZScoreTransform),
                                  selector = bic, digits = 1,
                                  data_processing = DataProcessing(split = 0.9,
                                                                   batchsize = 30,
                                                                   shuffle = true,
                                                                   rng = StableRNG(1111)))

nn_res = solve(nn_problem, basis, opt, options = options)
nn_eqs = get_basis(nn_res)
println(nn_res)
println(get_parameter_map(nn_eqs))
println(nn_eqs)
println()


# Define the recovered, hybrid model
function recovered_dynamics!(du, u, p, t)
    û = nn_eqs(u, p) # Recovered equations
    du[1] = p_[1] * u[1] + û[1]
    du[2] = -p_[4] * u[2] + û[2]
end

estimation_prob = ODEProblem(recovered_dynamics!, u0, tspan, get_parameter_values(nn_eqs))
estimate = solve(estimation_prob, Tsit5(), saveat = solution.t)

# Plot
plot(solution)
plot!(estimate)


function parameter_loss(p)
    Y = reduce(hcat, map(Base.Fix2(nn_eqs, p), eachcol(X̂)))
    sum(abs2, Ŷ .- Y)
end

optf = Optimization.OptimizationFunction((x, p) -> parameter_loss(x), adtype)
optprob = Optimization.OptimizationProblem(optf, get_parameter_values(nn_eqs))
parameter_res = Optimization.solve(optprob, Optim.LBFGS(), maxiters = 1000)