using LiteXM2SDR
using LiteXM2SDR: LitexM2SDRChannel
using Unitful: @u_str
using Test

const MOCK_RX_SCRIPT = joinpath(@__DIR__, "mock_rx_process.jl")

function make_mock_rx_cmd(; shm_path, channels=1, chunk_size=256, num_slots=16, num_chunks=10)
    return `$(Base.julia_cmd()) --startup-file=no --compile=min $MOCK_RX_SCRIPT
        -shm_path $shm_path -channels $channels -chunk_size $chunk_size
        -num_slots $num_slots -num_chunks $num_chunks`
end

@testset "RX Streaming" begin
    @testset "single channel read" begin
        shm_path = tempname()
        chunk_size = 256
        num_chunks = 10

        mock_cmd = make_mock_rx_cmd(;
            shm_path, channels=1, chunk_size, num_slots=16, num_chunks,
        )

        ch, warnings = read_from_litex_m2sdr(Val(1);
            cmd=mock_cmd,
            shm_path,
            channel_size=32,
            quiet=true,
        )

        chunks = collect(ch)
        @test length(chunks) == num_chunks

        # Each chunk should be (1, chunk_size) — (num_channels, num_samples)
        @test size(chunks[1]) == (1, chunk_size)

        # Verify sequential data pattern
        # The mock writes Complex{Int16}(counter, counter) with counter starting at 1
        expected_counter = Int16(1)
        for chunk in chunks
            for j in 1:chunk_size
                expected = Complex{Int16}(expected_counter, expected_counter)
                @test chunk[1, j] == expected
                expected_counter = Int16(mod(Int(expected_counter), 32000) + 1)
            end
        end

        # Warnings channel should be closed and empty (no overflows in mock)
        @test !isopen(warnings)
    end

    @testset "two channel read" begin
        shm_path = tempname()
        chunk_size = 128
        num_chunks = 5

        mock_cmd = make_mock_rx_cmd(;
            shm_path, channels=2, chunk_size, num_slots=16, num_chunks,
        )

        ch, warnings = read_from_litex_m2sdr(Val(2);
            cmd=mock_cmd,
            shm_path,
            channel_size=16,
            quiet=true,
        )

        chunks = collect(ch)
        @test length(chunks) == num_chunks

        # Each chunk should be (2, chunk_size) — (num_channels, num_samples)
        @test size(chunks[1]) == (2, chunk_size)

        # Verify data is present (sequential pattern across all samples)
        expected_counter = Int16(1)
        for chunk in chunks
            # Mock writes total_samples = chunk_size * num_channels sequentially into the slot
            # The slot layout is: [ch1_s1, ch1_s2, ..., ch2_s1, ch2_s2, ...] or interleaved
            # Actually the mock writes linearly: sample index 1..total_samples
            # And read_from_litex_m2sdr copies via unsafe_copyto! into (N, chunk_size) matrix
            # which stores column-major: chunk[1,1], chunk[2,1], chunk[1,2], chunk[2,2], ...
            for j in 1:chunk_size
                for c in 1:2
                    expected = Complex{Int16}(expected_counter, expected_counter)
                    @test chunk[c, j] == expected
                    expected_counter = Int16(mod(Int(expected_counter), 32000) + 1)
                end
            end
        end
    end

    @testset "writer_done terminates cleanly" begin
        shm_path = tempname()

        mock_cmd = make_mock_rx_cmd(;
            shm_path, channels=1, chunk_size=64, num_slots=8, num_chunks=3,
        )

        ch, warnings = read_from_litex_m2sdr(Val(1);
            cmd=mock_cmd,
            shm_path,
            channel_size=8,
            quiet=true,
        )

        chunks = collect(ch)
        @test length(chunks) == 3

        # Both channels should be closed after iteration completes
        @test !isopen(ch.pipe)
        @test !isopen(warnings)

        # SHM file should be cleaned up
        @test !isfile(shm_path)
    end
end
