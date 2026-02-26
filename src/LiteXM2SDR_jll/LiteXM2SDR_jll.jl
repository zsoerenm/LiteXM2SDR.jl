"""
    LiteXM2SDR_jll

Local artifact-based replacement for LiteXM2SDR_jll.
Provides `m2sdr_rx_stream_shm`, `m2sdr_tx_stream_shm`, and `m2sdr_stream_shm` executables
with the same interface as the official JLL package.

When the official LiteXM2SDR_jll is available in the registry, users can
switch to it seamlessly - the API is identical.
"""
module LiteXM2SDR_jll

using Artifacts
using Base.BinaryPlatforms: HostPlatform, triplet

export m2sdr_rx_stream_shm, m2sdr_tx_stream_shm, m2sdr_stream_shm

# Path to Artifacts.toml in the package root
const ARTIFACTS_TOML = normpath(joinpath(@__DIR__, "..", "..", "Artifacts.toml"))

# Cached artifact directory
const _artifact_dir = Ref{Union{String,Nothing}}(nothing)

function get_artifact_dir()
    if _artifact_dir[] !== nothing
        return _artifact_dir[]
    end

    if !isfile(ARTIFACTS_TOML)
        error("""
            Artifacts.toml not found at $ARTIFACTS_TOML

            Run the GitHub Actions workflow to build and publish artifacts,
            or download Artifacts.toml from an existing release.
            """)
    end

    meta = artifact_meta("LiteXM2SDR", ARTIFACTS_TOML; platform=HostPlatform())
    if meta === nothing
        error("""
            No LiteXM2SDR artifact for platform: $(triplet(HostPlatform()))

            LiteXM2SDR only supports Linux (x86_64 and aarch64).
            """)
    end

    hash_str = meta["git-tree-sha1"]
    if hash_str == "0000000000000000000000000000000000000000"
        error("""
            Artifacts.toml contains placeholder hashes.

            Run the GitHub Actions workflow to build artifacts:
            .github/workflows/build-litexm2sdr-artifacts.yml
            """)
    end

    hash = Base.SHA1(hash_str)

    if !artifact_exists(hash)
        @info "Downloading LiteXM2SDR artifact..."
        # Pkg is not a direct dependency, so load it at runtime only when needed.
        # invokelatest is required to avoid world age issues from Base.require.
        Pkg_Artifacts = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")).Artifacts
        Base.invokelatest(Pkg_Artifacts.ensure_artifact_installed, "LiteXM2SDR", ARTIFACTS_TOML; platform=HostPlatform())
    end

    _artifact_dir[] = artifact_path(hash)
    return _artifact_dir[]
end

"""
    m2sdr_rx_stream_shm()

Return a `Cmd` for the m2sdr_rx_stream_shm executable.
"""
function m2sdr_rx_stream_shm()
    exe = joinpath(get_artifact_dir(), "bin", "m2sdr_rx_stream_shm")
    isfile(exe) || error("m2sdr_rx_stream_shm not found at $exe")
    return Cmd([exe])
end

"""
    m2sdr_tx_stream_shm()

Return a `Cmd` for the m2sdr_tx_stream_shm executable.
"""
function m2sdr_tx_stream_shm()
    exe = joinpath(get_artifact_dir(), "bin", "m2sdr_tx_stream_shm")
    isfile(exe) || error("m2sdr_tx_stream_shm not found at $exe")
    return Cmd([exe])
end

"""
    m2sdr_stream_shm()

Return a `Cmd` for the m2sdr_stream_shm full-duplex executable.
"""
function m2sdr_stream_shm()
    exe = joinpath(get_artifact_dir(), "bin", "m2sdr_stream_shm")
    isfile(exe) || error("m2sdr_stream_shm not found at $exe")
    return Cmd([exe])
end

end # module
