# -*- encoding: utf-8 -*-
#
# This file is part of GaPSE
# Copyright (C) 2022 Matteo Foglieni
#
# GaPSE is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# GaPSE is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GaPSE. If not, see <http://www.gnu.org/licenses/>.
#

"""
     abstract type AbstractPlan end

The abstract type of all the Plan to be used in the code.
At the moment, they are:
- [`SingleBesselPlan`](@ref)
- [`HankelPlan`](@ref)
"""
abstract type AbstractPlan end

set_num_threads(N::Int) = FFTW.set_num_threads(N)

"""
     _c_window(N::AbstractArray, NCut::Int)

Returns the smoothing window function ``W(x, N_\\mathrm{cut})`` as defined
in Eq. (C.1) of [McEwen et al. (2016)](https://arxiv.org/abs/1603.04826):

```math
W(x) = \\begin{cases}
    \\displaystyle
    \\frac{x - x_{\\mathrm{min}}}{x_{\\mathrm{left}} - x_{\\mathrm{min}}} - \\frac{1}{2\\pi}\\sin\\left( 2\\pi \\frac{x - x_{\\mathrm{min}}}{x_{\\mathrm{left}} - x_{\\mathrm{min}}}\\right) \\; , \\quad\\quad
    x < x_{\\mathrm{left}}\\\\[12pt]
    \\displaystyle
    1 \\; , \\quad\\quad\\quad\\quad\\quad\\quad\\quad\\quad 
    \\quad\\quad\\quad\\quad\\quad\\quad\\quad\\; \\, 
    x_{\\mathrm{left}} \\leq x \\leq x_{\\mathrm{right}}\\\\[8pt]
    \\displaystyle
    \\frac{x_{\\mathrm{max}} - x}{x_{\\mathrm{max}} - x_{\\mathrm{right}}} -
    \\frac{1}{2\\pi}\\sin\\left(
        2\\pi \\frac{x_{\\mathrm{max}} - x}{x_{\\mathrm{max}} - x_{\\mathrm{right}}}
    \\right) \\; , \\quad x > x_{\\mathrm{right}}
\\end{cases}
```
"""
function _c_window(N::AbstractArray, NCut::Int)
     NRight = last(N) - NCut
     NR = filter(x -> x >= NRight, N)
     ThetaRight = (last(N) .- NR) ./ (last(N) - NRight - 1)
     W = ones(length(N))
     W[findall(x -> x >= NRight, N)] = ThetaRight .- 1 ./ (2 * π) .* sin.(2 .* π .*
                                                                          ThetaRight)
     return W
end


"""
     _logextrap(x::Vector, 
          n_extrap_low::Int, n_extrap_high::Int) ::Vector

Given an input LOGARITHMICALLY SPACED vector of values `x`, expands that
vector adding `n_extrap_low` point on the left and `n_extrap_high` on
the right.
Consequently, for an input `x` of `N` values, it returns a vector `X`
with length `N + n_extrap_low + n_extrap_right`.

It is not assumed that the spacing is the same in the two edges of the data.
"""
function _logextrap(x::Vector, n_extrap_low::Int, n_extrap_high::Int)
     d_ln_x_low = real(x[2] / x[1]) > 0 ? log(real(x[2] / x[1])) : log(real(x[3] / x[2]))
     d_ln_x_high = real(reverse(x)[1] / reverse(x)[2]) > 0 ? log(real(reverse(x)[1] / reverse(x)[2])) : log(real(reverse(x)[2] / reverse(x)[3]))
     X = all(imag.(x) .≈ 0.0) ? x : imag.(x)

     x_begin = all(imag.(x) .≈ 0.0) ? x[1] : imag.(x[1])
     x_end = all(imag.(x) .≈ 0.0) ? last(x) : imag.(last(x))
     if n_extrap_low != 0
          X = vcat(x_begin .* exp.(d_ln_x_low .* Array(-n_extrap_low:-1)), X)
     end
     if n_extrap_high != 0
          X = vcat(X, x_end .* exp.(d_ln_x_high .* Array(1:n_extrap_high)))
     end
     return all(imag.(x) .≈ 0.0) ? X : im .* X
end

#=
function _logextrap(x::Vector, n_extrap_low::Int, n_extrap_high::Int; LIM::Float64=5e-4)
     d_ln_x_low = log(x[2] / x[1])
     d_ln_x_high = log(reverse(x)[1] / reverse(x)[2])
     X = x
     if n_extrap_low != 0
          if abs(d_ln_x_low - 1) > LIM
               X = vcat(x[1] .* exp.(d_ln_x_low .* Array(-n_extrap_low:-1)), X)
          else
               X = vcat([x[1] for i in 1:n_extrap_low], X)
          end
     end
     if n_extrap_high != 0
          if abs(d_ln_x_high - 1) > LIM
               X = vcat(X, last(x) .* exp.(d_ln_x_high .* Array(1:n_extrap_high)))
          else
               X = vcat(X, [x[end] for x in 1:n_extrap_high])
          end
     end
     return X
end
=#

"""
     _zeropad(x::Vector, n_pad::Int)::Vector

Concatenates `n_pad` zeros both on the left and on the right of
the input vector `x`.
Consequently, for an input `x` of `N` values, it returns a vector `X`
with length `N + 2 * n_pad`.
"""
function _zeropad(x::Vector, n_pad::Int)
     return vcat(zeros(n_pad), x, zeros(n_pad))
end


##########################################################################################92



"""
     _eval_cm!(plan::AbstractPlan, fx)

Given a `plan::AbstractPlan`, compute the power-law expansion coefficients ``c_m``
of the input data vector `fx`. It is assumed that `fx` contains the y-axis values
corresponding to the x-axis ones `plan.x`, and consequently their length must be
the same.
The computed `cm` vector is stored in `plan.cm`, and nothing is returned.

For a function `f` evaluated the `N` x-axis values `x`, the `c_m` coefficients are
```math
c_m = W_m \\sum_{q=0}^{N-1} \\frac{f(x_q)}{x_q^\\nu} e^{-\\frac{2\\pi}{N}i m q}
```
where ``W_m`` is the smoothing window function computed via `_c_window` and 
``\\nu`` is the bias parameter stored in `plan.ν`

See also: [`_c_window`](@ref), [`AbstractPlan`](@ref)
"""
function _eval_cm!(plan::AbstractPlan, fx)
     plan.cm = plan.plan_rfft * (fx .* plan.x .^ (-plan.ν))
     plan.cm .*= _c_window(plan.m, floor(Int, plan.c_window_width * plan.N / 2))
end


"""
     _eval_ηm!(plan::AbstractPlan)

Given an input `plan::AbstractPlan`, compute all the ``\\eta_m`` coefficients, 
defined as follows:
```math
\\eta_m = \\frac{2 \\pi m}{N \\, \\Delta_{\\ln x}} \\, 
```
where ``N``, ``\\Delta_{\\ln x}`` and the ``m`` vector are respectively
`plan.N`, `plan.d_ln_x` and `plan.m`.

The computed `ηm` vector is stored in `plan.cm`, and nothing is returned.

See also: [`AbstractPlan`](@ref)
"""
function _eval_ηm!(plan::AbstractPlan)
     #TODO: #9 since we know the length of the initial array, we could use this info here to
     #remove the necessity of DLnX
     plan.ηm = 2 .* π ./ (plan.N .* plan.d_ln_x) .* plan.m
end


##########################################################################################92


"""
    evaluate_FFTLog(plan::AbstractPlan, fx)::Union{Vector, Matrix}

Given an input `plan::AbstractPlan`, evaluate the FFT `fy` of the `fx` y-axis data
on the basis of the parameters stored in `plan`.
The result is both stored in `plan.fy` and retuned as output.

See also: [`AbstractPlan`](@ref)
"""
function evaluate_FFTLog(plan::AbstractPlan, fx)
     fy = similar(get_y(plan))
     evaluate_FFTLog!(fy, plan, fx)
     return fy
end



