include("solver.jl")
using PyCall
import Adapt

# load mesh metrics
@load "metrics.jld2" NG Nx Ny Nz dξdx dξdy dξdz dηdx dηdy dηdz dζdx dζdy dζdz J x y z

# global variables, do not change name
const dt::Float64 = 1e-7
const Time::Float64 = 5e-5
const Nspecs::Int64 = 8 # number of species
const Ncons::Int64 = 5 # ρ ρu ρv ρw E 
const Nprim::Int64 = 7 # ρ u v w p T c 
const mech = "./NN/air.yaml"

const nthreads::Tuple{Int64, Int64, Int64} = (8, 8, 4)
const nblock::Tuple{Int64, Int64, Int64} = (cld((Nx+2*NG), 8), 
                                            cld((Ny+2*NG), 8),
                                            cld((Nz+2*NG), 4))

struct thermoProperty{IT, RT, VT, MT, TT}
    Nspecs::IT
    Ru::RT
    mw::VT
    coeffs_sep::VT
    coeffs_lo::MT
    coeffs_hi::MT
    visc_poly::MT
    conduct_poly::MT
    binarydiff_poly::TT
end

Adapt.@adapt_structure thermoProperty

U = zeros(Float64, Nx+2*NG, Ny+2*NG, Nz+2*NG, Ncons)
ρi = zeros(Float64, Nx+2*NG, Ny+2*NG, Nz+2*NG, Nspecs)
ϕ = zeros(Float64, Nx+2*NG, Ny+2*NG, Nz+2*NG) # shock sensor

#initialization on CPU
function initialize(U, mech)
    ct = pyimport("cantera")
    gas = ct.Solution(mech)
    T::Float64 = 350
    P::Float64 = 3596
    gas.TPY = T, P, "N2:0.767 O2:0.233"
    ρ::Float64 = gas.density
    c::Float64 = sqrt(1.4 * P / ρ)
    u::Float64 = 10 * c

    U[:, :, :, 1] .= ρ
    U[:, :, :, 2] .= ρ * u
    U[:, :, :, 3] .= 0.0
    U[:, :, :, 4] .= 0.0
    U[:, :, :, 5] .= P/(1.4-1) + 0.5 * ρ * u^2
    for k ∈ 1:Nz+2*NG, j ∈ 1:Ny+2*NG, i ∈ 1:Nx+2*NG
        ρi[i, j, k, :] .= gas.Y .* ρ
    end
end

thermo = initThermo(mech, Nspecs)
initialize(U, mech)

U_d = CuArray(U)
ρi_d = CuArray(ρi)
ϕ_d = CuArray(ϕ)
dξdx_d = CuArray(dξdx)
dξdy_d = CuArray(dξdy)
dξdz_d = CuArray(dξdz)
dηdx_d = CuArray(dηdx)
dηdy_d = CuArray(dηdy)
dηdz_d = CuArray(dηdz)
dζdx_d = CuArray(dζdx)
dζdy_d = CuArray(dζdy)
dζdz_d = CuArray(dζdz)
J_d = CuArray(J)

@time time_step(U_d, ρi_d, dξdx_d, dξdy_d, dξdz_d, dηdx_d, dηdy_d, dηdz_d, dζdx_d, dζdy_d, dζdz_d, J_d, Nx, Ny, Nz, NG, dt, ϕ_d)
copyto!(U, U_d)
copyto!(ρi, ρi_d)
copyto!(ϕ, ϕ_d)

rho = U[:, :, :, 1]
u =   U[:, :, :, 2]./rho
v =   U[:, :, :, 3]./rho
w =   U[:, :, :, 4]./rho
p = @. (U[:, :, :, 5] - 0.5*rho*(u^2+v^2+w^2)) * 0.4
T = @. p/(287.0 * rho)

YO = ρi[:, :, :, 1]./rho
YO2 = ρi[:, :, :, 2]./rho
YN = ρi[:, :, :, 3]./rho
YNO = ρi[:, :, :, 4]./rho
YNO2 = ρi[:, :, :, 5]./rho
YN2O = ρi[:, :, :, 6]./rho
YN2 = ρi[:, :, :, 7]./rho
YAR = ρi[:, :, :, 8]./rho
vtk_grid("result.vts", x, y, z) do vtk
    vtk["rho"] = rho
    vtk["u"] = u
    vtk["v"] = v
    vtk["w"] = w
    vtk["p"] = p
    vtk["T"] = T
    vtk["phi"] = ϕ
    vtk["YO"] = YO
    vtk["YO2"] = YO2
    vtk["YN"] = YN
    vtk["YNO"] = YNO
    vtk["YNO2"] = YNO2
    vtk["YN2O"] = YN2O
    vtk["YN2"] = YN2
    vtk["YAR"] = YAR
end 
