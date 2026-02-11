using LiteXM2SDR
using SignalChannels: SignalChannel, TxStats, StreamWarning
using FixedSizeArrays: FixedSizeMatrixDefault
using Unitful: @u_str
using Test

const MOCK_TX_SCRIPT = joinpath(@__DIR__, "mock_tx_process.jl")

function make_mock_tx_cmd(; shm_path, output_path=nothing)
    args = `-shm_path $shm_path`
    if output_path !== nothing
        args = `$args -output_path $output_path`
    end
    return `$(Base.julia_cmd()) --startup-file=no --compile=min $MOCK_TX_SCRIPT $args`
end

@testset "TX Streaming" begin
    @testset "single channel Complex{Int16}" begin
        shm_path = tempname()
        output_path = tempname()
        chunk_size = 256
        num_chunks = 10

        mock_cmd = make_mock_tx_cmd(; shm_path, output_path)

        # Create input signal channel and fill with known data
        signal_ch = SignalChannel{Complex{Int16},1}(chunk_size, 16)

        # Generate test data
        test_data = [
            FixedSizeMatrixDefault{Complex{Int16}}(
                [Complex{Int16}(Int16(i + (k - 1) * chunk_size), Int16(k)) for i in 1:chunk_size, _ in 1:1],
            )
            for k in 1:num_chunks
        ]

        stats_ch, warn_ch = write_to_litex_m2sdr(signal_ch;
            cmd=mock_cmd,
            shm_path,
            buffer_time=1u"s",
            sample_rate=1u"MHz",
            quiet=true,
        )

        # Feed data and close
        for chunk in test_data
            put!(signal_ch, chunk)
        end
        close(signal_ch)

        # Collect stats until channel closes
        all_stats = collect(stats_ch)

        # Verify stats
        @test length(all_stats) > 0
        @test last(all_stats).total_samples == chunk_size * num_chunks

        # Read back what the mock TX process received
        # Wait briefly for mock process to write its output
        sleep(1.0)
        @test isfile(output_path)

        raw_bytes = read(output_path)
        received = reinterpret(Complex{Int16}, raw_bytes)

        # Verify data integrity
        @test length(received) == chunk_size * num_chunks

        offset = 1
        for k in 1:num_chunks
            for i in 1:chunk_size
                expected = Complex{Int16}(Int16(i + (k - 1) * chunk_size), Int16(k))
                @test received[offset] == expected
                offset += 1
            end
        end

        # Clean up
        rm(output_path; force=true)
    end

    @testset "real Int16 input conversion" begin
        shm_path = tempname()
        output_path = tempname()
        chunk_size = 128
        num_chunks = 5

        mock_cmd = make_mock_tx_cmd(; shm_path, output_path)

        signal_ch = SignalChannel{Int16,1}(chunk_size, 16)

        # Generate real Int16 test data
        test_data = [
            FixedSizeMatrixDefault{Int16}(
                [Int16(i + (k - 1) * chunk_size) for i in 1:chunk_size, _ in 1:1],
            )
            for k in 1:num_chunks
        ]

        stats_ch, warn_ch = write_to_litex_m2sdr(signal_ch;
            cmd=mock_cmd,
            shm_path,
            buffer_time=1u"s",
            sample_rate=1u"MHz",
            quiet=true,
        )

        for chunk in test_data
            put!(signal_ch, chunk)
        end
        close(signal_ch)

        collect(stats_ch)

        # Wait for mock to write output
        sleep(1.0)
        @test isfile(output_path)

        raw_bytes = read(output_path)
        received = reinterpret(Complex{Int16}, raw_bytes)

        @test length(received) == chunk_size * num_chunks

        # Verify Int16 was converted to Complex{Int16} with zero imaginary
        offset = 1
        for k in 1:num_chunks
            for i in 1:chunk_size
                expected_real = Int16(i + (k - 1) * chunk_size)
                @test real(received[offset]) == expected_real
                @test imag(received[offset]) == Int16(0)
                offset += 1
            end
        end

        rm(output_path; force=true)
    end

    @testset "stats updates accumulate correctly" begin
        shm_path = tempname()
        chunk_size = 64
        num_chunks = 20

        mock_cmd = make_mock_tx_cmd(; shm_path)

        signal_ch = SignalChannel{Complex{Int16},1}(chunk_size, 16)

        stats_ch, warn_ch = write_to_litex_m2sdr(signal_ch;
            cmd=mock_cmd,
            shm_path,
            buffer_time=1u"s",
            sample_rate=1u"MHz",
            quiet=true,
        )

        for k in 1:num_chunks
            chunk = FixedSizeMatrixDefault{Complex{Int16}}(
                rand(Complex{Int16}, chunk_size, 1),
            )
            put!(signal_ch, chunk)
        end
        close(signal_ch)

        all_stats = collect(stats_ch)

        # Stats should be monotonically increasing
        for i in 2:length(all_stats)
            @test all_stats[i].total_samples >= all_stats[i-1].total_samples
        end

        # Final stats should reflect all samples
        @test last(all_stats).total_samples == chunk_size * num_chunks
    end
end
