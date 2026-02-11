using Test

@testset "LiteXM2SDR" begin
    include("test_rx_streaming.jl")
    include("test_tx_streaming.jl")
end
