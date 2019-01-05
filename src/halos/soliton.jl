#==========================================================
Soliton NFW model, see Marsh & Pop 2015, Robles et al. 2019
https://ui.adsabs.harvard.edu/#abs/2015MNRAS.451.2479M
https://ui.adsabs.harvard.edu/#abs/arXiv:1807.06018
==========================================================#

function rho_sol(r, rsol, rhosol)
    @. rhosol * (1.0 + (r / rsol)^2) ^ -8
end

# it's analytic!
function M_sol(r, rsol, rhosol)
    x = r / rsol
    t = atan.(x, 1.0)
    term0 = 27720. * t
    term1 = 17325. * sin.(2 * t)
    term2 = -1155. * sin.(4 * t)
    term3 = -4235. * sin.(6 * t)
    term4 = -2625. * sin.(8 * t)
    term5 = -903. * sin.(10 * t)
    term6 = -175. * sin.(12 * t)
    term7 = -15. * sin.(14 * t)
    factor = 4π * rhosol * rsol^3 / 1720320.
    return @. factor * (term0 + term1 + term2 + term3 + term4 + term5 + term6 + term7)
end

function drhodr_sol(r, rsol, rhosol)
    x = r / rsol
    return @. -16 * rhosol * x * (1.0 + x^2) ^ -9
end
    
"""
Compute the matching radius, repsilon, from the specified NFW and SolNFW parameters.
"""
function matching_radius(rs, rhos, rsol, rhosol; xstart = 2.0, rtol = 1e-9)
    ρ1(r) = rho_NFW(r, rs, rhos)
    dρ1(r) = drhodr_NFW(r, rs, rhos)
    ρ2(r) = rho_sol(r, rsol, rhosol)
    dρ2(r) = drhodr_sol(r, rsol, rhosol)
    f(r) = (1.0 - ρ1(r) / ρ2(r)) ^ 2
    fp(r) = -2.0 * (1.0 - ρ1(r) / ρ2(r)) * (dρ1(r) / ρ2(r) - ρ1(r) * dρ2(r) / ρ2(r)^2)
    return fzero(f, fp, xstart * rsol; rtol = rtol)
end

"""
Soliton NFW model.  For consistency, the NFW density must match the soliton 
density at repsilon.  If that is not the case, the constructor will update
repsilon.

    rs : NFW scale radius in kpc
    rhos : NFW scale density in Msun / kpc3
    rsol : soliton scale radius in kpc
    rhosol : soliton scale density in kpc
    repsilon : transition radius
"""
struct SolNFWModel <: HaloModel
    rs::Float64
    rhos::Float64
    rsol::Float64
    rhosol::Float64
    repsilon::Float64
    # enforce density matching
    SolNFWModel(rs, rhos, rsol, rhosol, repsilon) = begin
        ρnfw = rho_NFW(repsilon, rs, rhos)
        ρsol = rho_sol(repsilon, rsol, rhosol)
        if ((ρnfw - ρsol) / ρsol) ^ 2 < 1e-9
            return new(rs, rhos, rsol, rhosol, repsilon)
        else
            @warn("recalculating matching radius", maxlog=1)
            try
                repsilon = matching_radius(rs, rhos, rsol, rhosol)
            catch err
                @warn("failed to find matching radius for " *
                      "\trs = $rs \n\trhos = $rhos \n\trsol = $rsol \n\trhosol = $rhosol")
                throw(err)
            end
            return new(rs, rhos, rsol, rhosol, repsilon)
        end
    end
end

SolNFWModel() = SolNFWModel(21.1, 5.6e6, 0.53, 3.1e10, 0.48)


density(halo::SolNFWModel, r::T where T <: Real) = begin
    if r < halo.repsilon
        return rho_sol(r, halo.rsol, halo.rhosol)
    end
    return rho_NFW(r, halo.rs, halo.rhos)
end

density(halo::SolNFWModel, r::Array{T, 1} where T <: Real) = begin
    ρ = zero(r)
    idx_sol = r .< halo.repsilon
    idx_nfw = .~ idx_sol
    ρ[idx_sol] = rho_sol(r[idx_sol], halo.rsol, halo.rhosol)
    ρ[idx_nfw] = rho_NFW(r[idx_nfw], halo.rs, halo.rhos)
    return ρ
end

mass(halo::SolNFWModel, r::T where T <: Real) = begin
    if r < halo.repsilon
        return M_sol(r, halo.rsol, halo.rhosol)
    end
    dM_epsilon = (M_sol(halo.repsilon, halo.rsol, halo.rhosol) -
                  M_NFW(halo.repsilon, halo.rs, halo.rhos))
    return M_NFW(r, halo.rs, halo.rhos) + dM_epsilon
end

mass(halo::SolNFWModel, r::Array{T, 1} where T <: Real) = begin
    M = zero(r)
    dM_epsilon = (M_sol(halo.repsilon, halo.rsol, halo.rhosol) -
                  M_NFW(halo.repsilon, halo.rs, halo.rhos))
    idx_sol = r .< halo.repsilon
    idx_nfw = .~ idx_sol
    M[idx_sol] = M_sol(r[idx_sol], halo.rsol, halo.rhosol)
    M[idx_nfw] = M_NFW(r[idx_nfw], halo.rs, halo.rhos) .+ dM_epsilon
    return M
end

scale_radius(halo::SolNFWModel) = halo.rs

"""
Calculate the axion mass from the soliton scale parameters.
See Marsh & Pop 2015, equation 8.  Axion mass has units of 1e-22 eV.
alpha_mp is the alpha fitting parameter from Marsh & Pop 2015
"""
function m22_from_sol(rsol, rhosol;
                      cosmo = default_cosmo, z = 0.0, alpha_mp = 0.23)
    Δ_sol = rhosol / ρcrit(z; cosmo = cosmo)
    m22 = √(Δ_sol ^ -1 * rsol ^ -4 * (cosmo.h / 0.7) ^ 2 * 5e4 * alpha_mp ^ -4)
    return m22
end

"""
Calculate the scale density of the soliton core from m22 and the scale radius.
"""
function rhosol_from_rsol(m22, rsol;
                         cosmo = default_cosmo, z = 0.0, alpha_mp = 0.23)
    Δ_sol = (5e4 / alpha_mp^4) * (cosmo.h / 0.7)^-2 * m22^-2 * rsol^-4
    return Δ_sol * ρcrit(z; cosmo = cosmo)
end

"""
Calculate the scale radius of the soliton core from the halo mass scaling 
relation (see Robles+2019)
"""
function rsol_from_Mvir(m22, Mvir)
    rsol = 3.315 * 1.6 * (Mvir / 1e9)^(-1/3.) * m22^-1
end

function SolNFW_from_virial(Mvir, cvir, m22;
                            rsol = nothing,
                            mdef = "200c",
                            cosmo = default_cosmo,
                            z = 0.0)
    # soliton parameters, calculate rsol from Mvir scaling if not passed in
    if rsol == nothing
        rsol = rsol_from_Mvir(m22, Mvir)
    end
    rhosol = rhosol_from_rsol(m22, rsol, cosmo = cosmo, z = z)
    # NFW parameters
    Rvir = Rvir_from_Mvir(Mvir; mdef = mdef, cosmo = cosmo, z = z)
    rs = Rvir / cvir

    # first guess, rhos from normal NFW profile
    rhos = Mvir / M_NFW(Rvir, rs, 1.0)
    repsilon = matching_radius(rs, rhos, rsol, rhosol)

    return SolNFWModel(rs, rhos, rsol, rhosol, repsilon)
end