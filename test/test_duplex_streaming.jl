using LiteXM2SDR
using LiteXM2SDR: LitexM2SDRChannel
using SignalChannels: SignalChannel, TxStats, StreamWarning
using FixedSizeArrays: FixedSizeMatrixDefault
using Unitful: @u_str
using Test

const MOCK_DUPLEX_SCRIPT = joinpath(@__DIR__, "mock_duplex_process.jl")

function make_mock_duplex_cmd(;
    rx_shm_path,
    tx_shm_path,
    channels = 1,
    chunk_size = 256,
    num_slots = 16,
    num_chunks = 10,
    output_path = nothing,
)
    args = `-rx_shm_path $rx_shm_path -tx_shm_path $tx_shm_path
        -channels $channels -chunk_size $chunk_size
        -num_slots $num_slots -num_chunks $num_chunks -w`
    if output_path !== nothing
        args = `$args -output_path $output_path`
    end
    return `$(Base.julia_cmd()) --startup-file=no --compile=min $MOCK_DUPLEX_SCRIPT $args`
end

@testset "Duplex Streaming" begin
    @testset "single channel full duplex" begin
        rx_shm_path = tempname()
        tx_shm_path = tempname()
        output_path = tempname()
        chunk_size = 256
        num_chunks = 10

        mock_cmd = make_mock_duplex_cmd(;
            rx_shm_path,
            tx_shm_path,
            channels = 1,
            chunk_size,
            num_slots = 16,
            num_chunks,
            output_path,
        )

        # Create TX input with known data
        signal_ch = SignalChannel{Complex{Int16},1}(chunk_size, 16)

        tx_test_data = [
            FixedSizeMatrixDefault{Complex{Int16}}(
                [
                    Complex{Int16}(Int16(i + (k - 1) * chunk_size), Int16(k)) for
                    i = 1:chunk_size, _ = 1:1
                ],
            ) for k = 1:num_chunks
        ]

        rx_ch, stats_ch, warn_ch = stream_litex_m2sdr(
            Val(1),
            signal_ch;
            cmd = mock_cmd,
            rx_shm_path,
            tx_shm_path,
            channel_size = 32,
            quiet = true,
        )

        # Feed TX data in background
        tx_task = Threads.@spawn begin
            for chunk in tx_test_data
                put!(signal_ch, chunk)
            end
            close(signal_ch)
        end

        # Collect RX data
        rx_chunks = collect(rx_ch)
        @test length(rx_chunks) == num_chunks

        # Each RX chunk should be (1, chunk_size)
        @test size(rx_chunks[1]) == (1, chunk_size)

        # Verify RX sequential data pattern from mock
        expected_counter = Int16(1)
        for chunk in rx_chunks
            for j = 1:chunk_size
                expected = Complex{Int16}(expected_counter, expected_counter)
                @test chunk[1, j] == expected
                expected_counter = Int16(mod(Int(expected_counter), 32000) + 1)
            end
        end

        # Collect TX stats
        wait(tx_task)
        all_stats = collect(stats_ch)
        @test length(all_stats) > 0
        @test last(all_stats).total_samples == chunk_size * num_chunks

        # Verify TX data was received by mock process
        sleep(1.0)
        @test isfile(output_path)

        raw_bytes = read(output_path)
        received = reinterpret(Complex{Int16}, raw_bytes)
        @test length(received) == chunk_size * num_chunks

        offset = 1
        for k = 1:num_chunks
            for i = 1:chunk_size
                expected = Complex{Int16}(Int16(i + (k - 1) * chunk_size), Int16(k))
                @test received[offset] == expected
                offset += 1
            end
        end

        # Clean up
        rm(output_path; force = true)
    end

    @testset "two channel full duplex" begin
        rx_shm_path = tempname()
        tx_shm_path = tempname()
        output_path = tempname()
        chunk_size = 128
        num_chunks = 5

        mock_cmd = make_mock_duplex_cmd(;
            rx_shm_path,
            tx_shm_path,
            channels = 2,
            chunk_size,
            num_slots = 16,
            num_chunks,
            output_path,
        )

        signal_ch = SignalChannel{Complex{Int16},2}(chunk_size, 16)

        # Generate 2-channel TX data
        tx_test_data = [
            FixedSizeMatrixDefault{Complex{Int16}}(
                [
                    Complex{Int16}(Int16(i + (k - 1) * chunk_size), Int16(c)) for
                    i = 1:chunk_size, c = 1:2
                ],
            ) for k = 1:num_chunks
        ]

        rx_ch, stats_ch, warn_ch = stream_litex_m2sdr(
            Val(2),
            signal_ch;
            cmd = mock_cmd,
            rx_shm_path,
            tx_shm_path,
            channel_size = 16,
            quiet = true,
        )

        tx_task = Threads.@spawn begin
            for chunk in tx_test_data
                put!(signal_ch, chunk)
            end
            close(signal_ch)
        end

        rx_chunks = collect(rx_ch)
        @test length(rx_chunks) == num_chunks
        @test size(rx_chunks[1]) == (2, chunk_size)

        # Verify 2-channel RX data
        expected_counter = Int16(1)
        for chunk in rx_chunks
            for j = 1:chunk_size
                for c = 1:2
                    expected = Complex{Int16}(expected_counter, expected_counter)
                    @test chunk[c, j] == expected
                    expected_counter = Int16(mod(Int(expected_counter), 32000) + 1)
                end
            end
        end

        wait(tx_task)

        # Verify TX data received
        sleep(1.0)
        @test isfile(output_path)

        raw_bytes = read(output_path)
        received = reinterpret(Complex{Int16}, raw_bytes)
        @test length(received) == chunk_size * num_chunks * 2

        rm(output_path; force = true)
    end

    @testset "writer_done terminates cleanly" begin
        rx_shm_path = tempname()
        tx_shm_path = tempname()

        mock_cmd = make_mock_duplex_cmd(;
            rx_shm_path,
            tx_shm_path,
            channels = 1,
            chunk_size = 64,
            num_slots = 8,
            num_chunks = 3,
        )

        signal_ch = SignalChannel{Complex{Int16},1}(64, 8)

        rx_ch, stats_ch, warn_ch = stream_litex_m2sdr(
            Val(1),
            signal_ch;
            cmd = mock_cmd,
            rx_shm_path,
            tx_shm_path,
            channel_size = 8,
            quiet = true,
        )

        # Feed 3 TX chunks
        tx_task = Threads.@spawn begin
            for k = 1:3
                chunk = FixedSizeMatrixDefault{Complex{Int16}}(
                    rand(Complex{Int16}, 64, 1),
                )
                put!(signal_ch, chunk)
            end
            close(signal_ch)
        end

        rx_chunks = collect(rx_ch)
        @test length(rx_chunks) == 3

        wait(tx_task)
        collect(stats_ch)

        # All channels should be closed
        @test !isopen(rx_ch.pipe)
        @test !isopen(stats_ch)

        # SHM files should be cleaned up
        @test !isfile(rx_shm_path)
        @test !isfile(tx_shm_path)
    end
end
