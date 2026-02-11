module LiteXM2SDR

using Mmap
using Printf
using Unitful: Frequency, Hz, ustrip, @u_str
using Unitful
using SignalChannels: SignalChannel, TxStats, StreamWarning
using PipeChannels: PipeChannel
using FixedSizeArrays: FixedSizeMatrixDefault

include("LiteXM2SDR_jll/LiteXM2SDR_jll.jl")
using .LiteXM2SDR_jll: m2sdr_rx_stream_shm, m2sdr_tx_stream_shm

include("common.jl")
include("rx_streaming.jl")
include("tx_streaming.jl")
include("signal_channel_bridge.jl")

export read_from_litex_m2sdr,
    write_to_litex_m2sdr,
    sdr_chunks_to_signal_channel,
    cleanup_shared_memory,
    get_shm_stats,
    DEFAULT_SHM_PATH,
    DEFAULT_TX_SHM_PATH,
    AGCMode,
    AGC_MANUAL,
    AGC_FAST_ATTACK,
    AGC_SLOW_ATTACK,
    AGC_HYBRID,
    LitexM2SDRChannel

end # module LiteXM2SDR
