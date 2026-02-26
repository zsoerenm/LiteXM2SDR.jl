# LiteX M2SDR Full-Duplex (RX + TX) shared memory streaming
#
# Launches a single `m2sdr_stream_shm` C process that simultaneously:
#   - Writes RX data to an RX shared memory ring buffer (Julia reads)
#   - Reads TX data from a TX shared memory ring buffer (Julia writes)
#
# Uses two separate Julia tasks for independent RX/TX operation.

"""
    stream_litex_m2sdr(::Val{N}, input_channel::SignalChannel{T,N}; kwargs...)

Start the LiteX M2SDR full-duplex streaming process. A single C process handles
both RX and TX via shared memory, while two Julia tasks independently manage
each direction.

# Arguments
- `::Val{N}`: Number of antenna channels (1 or 2, compile-time constant)
- `input_channel`: TX data source (`SignalChannel{Complex{Int16},N}` or `SignalChannel{Int16,N}`)

# Keyword Arguments
- `sample_rate`: Sampling rate (default: 40 MHz)
- `rx_frequency`: RX center frequency (default: 5 GHz)
- `tx_frequency`: TX center frequency (default: 5 GHz)
- `rx_gain`: RX gain in dB (default: 20 dB)
- `tx_gain`: TX gain in dB (default: -10 dB, negative = attenuation)
- `agc_mode`: AGC mode (default: `AGC_MANUAL`)
- `bandwidth`: RF bandwidth (default: same as sample_rate)
- `rx_buffer_time`: RX ring buffer duration (default: 3 s)
- `tx_buffer_time`: TX ring buffer duration (default: 3 s)
- `num_samples`: Samples to stream (0 = infinite)
- `rx_shm_path`: Path for RX shared memory
- `tx_shm_path`: Path for TX shared memory
- `device_num`: M2SDR device number (default: 0)
- `channel_size`: RX output channel buffer size (default: 100)
- `warning_channel_size`: Warning channel buffer size (default: 16)
- `quiet`: Suppress C process output (default: false)
- `cmd`: Override C process command (for testing)
- `stats_buffer_size`: TX stats channel buffer size (default: 1000)

# Returns
A tuple of:
- `LitexM2SDRChannel{N}`: RX data output channel
- `Channel{TxStats}`: TX statistics channel
- `Channel{StreamWarning}`: Combined RX/TX warning channel (overflows + underflows)

# Example
```julia
using Unitful: @u_str
using SignalChannels: SignalChannel

# Create TX signal source
tx_ch = SignalChannel{Complex{Int16}, 1}(2048, 16)

# Start full-duplex streaming
rx_ch, tx_stats, warnings = stream_litex_m2sdr(Val(1), tx_ch;
    sample_rate=40u"MHz",
    rx_frequency=5u"GHz",
    tx_frequency=5u"GHz",
)

# Monitor warnings in background
@async for w in warnings
    @warn "SDR warning" w.type w.time_str
end

# TX: feed samples
@async begin
    for chunk in my_tx_source
        put!(tx_ch, chunk)
    end
    close(tx_ch)
end

# RX: consume samples
for chunk in rx_ch
    process(chunk)
end
```
"""
function stream_litex_m2sdr(
    ::Val{N},
    input_channel::SignalChannel{T,N};
    sample_rate::Unitful.Frequency = 40u"MHz",
    rx_frequency::Unitful.Frequency = 5u"GHz",
    tx_frequency::Unitful.Frequency = 5u"GHz",
    rx_gain::Unitful.Gain = 20u"dB",
    tx_gain::Unitful.Gain = -10u"dB",
    agc_mode::AGCMode = AGC_MANUAL,
    bandwidth::Union{Unitful.Frequency,Nothing} = nothing,
    rx_buffer_time::Unitful.Time = 3u"s",
    tx_buffer_time::Unitful.Time = 3u"s",
    num_samples::Integer = 0,
    rx_shm_path::String = DEFAULT_SHM_PATH,
    tx_shm_path::String = DEFAULT_TX_SHM_PATH,
    device_num::Integer = 0,
    channel_size::Integer = 100,
    warning_channel_size::Integer = 16,
    quiet::Bool = false,
    cmd::Union{Cmd,Nothing} = nothing,
    stats_buffer_size::Integer = 1000,
) where {T<:Union{Complex{Int16},Int16},N}
    if N != 1 && N != 2
        error("Number of channels must be 1 or 2, got $N")
    end

    bw = isnothing(bandwidth) ? sample_rate : bandwidth

    # Convert Unitful quantities to numeric values
    sample_rate_hz = Int(ustrip(Hz, sample_rate))
    rx_frequency_hz = Int(ustrip(Hz, rx_frequency))
    tx_frequency_hz = Int(ustrip(Hz, tx_frequency))
    rx_gain_db = Int(ustrip(rx_gain))
    tx_gain_db = Int(ustrip(tx_gain))
    bandwidth_hz = Int(ustrip(Hz, bw))
    rx_buffer_time_s = ustrip(u"s", rx_buffer_time)
    tx_buffer_time_s = ustrip(u"s", tx_buffer_time)

    agc_mode_str = AGC_MODE_STRINGS[agc_mode]

    # === Create TX SHM (Julia is the TX producer) ===
    chunk_size = input_channel.num_samples
    chunk_bytes = chunk_size * sizeof(Complex{Int16}) * N

    bytes_per_second = sample_rate_hz * sizeof(Complex{Int16}) * N
    total_buffer_bytes = bytes_per_second * tx_buffer_time_s
    num_slots = max(16, Int(ceil(total_buffer_bytes / chunk_bytes)))

    total_size = TX_SHM_HEADER_SIZE + num_slots * chunk_bytes

    if isfile(tx_shm_path)
        rm(tx_shm_path)
    end

    tx_io = open(tx_shm_path, "w+")
    truncate(tx_io, total_size)
    tx_shm = Mmap.mmap(tx_io, Vector{UInt8}, total_size)

    fill!(view(tx_shm, 1:TX_SHM_HEADER_SIZE), 0)
    unsafe_store!(Ptr{UInt32}(pointer(tx_shm, TX_OFFSET_CHUNK_SIZE)), UInt32(chunk_size))
    unsafe_store!(Ptr{UInt32}(pointer(tx_shm, TX_OFFSET_NUM_SLOTS)), UInt32(num_slots))
    unsafe_store!(Ptr{UInt16}(pointer(tx_shm, TX_OFFSET_NUM_CHANNELS)), UInt16(N))
    unsafe_store!(
        Ptr{UInt32}(pointer(tx_shm, TX_OFFSET_SAMPLE_SIZE)),
        UInt32(sizeof(Complex{Int16})),
    )

    @info "Created TX shared memory" path = tx_shm_path chunk_size num_channels = N num_slots

    # === Build and launch C process ===
    if cmd === nothing
        cmd = `$(m2sdr_stream_shm())
            -c $(device_num)
            -samplerate $(sample_rate_hz)
            -rx_freq $(rx_frequency_hz)
            -rx_gain $(rx_gain_db)
            -agc_mode $(agc_mode_str)
            -tx_freq $(tx_frequency_hz)
            -tx_gain $(tx_gain_db)
            -bandwidth $(bandwidth_hz)
            -channels $(N)
            -rx_shm_path $(rx_shm_path)
            -tx_shm_path $(tx_shm_path)
            -rx_buffer_time $(rx_buffer_time_s)
            -tx_buffer_time $(tx_buffer_time_s)
            -num_samples $(num_samples)
            -w`

        if quiet
            cmd = `$cmd -q`
        end
    end

    if isfile(rx_shm_path)
        @warn "Removing stale RX shared memory file" path = rx_shm_path
        rm(rx_shm_path)
    end

    log_path = "/tmp/m2sdr_stream.log"
    @info "Starting LiteX M2SDR full-duplex stream" sample_rate rx_frequency tx_frequency rx_gain tx_gain agc_mode channels =
        N log_file = log_path
    log_io = open(log_path, "w")
    proc = run(pipeline(cmd; stderr = log_io, stdout = log_io); wait = false)

    # === Wait for RX SHM to be created by C process ===
    timeout_start = time()
    local rx_shm, rx_chunk_size, rx_num_channels
    while true
        if time() - timeout_start > 10.0
            kill_and_cleanup(proc, rx_shm_path)
            cleanup_shared_memory(tx_shm_path)
            error("Timeout waiting for RX shared memory to be initialized")
        end
        if !process_running(proc)
            cleanup_shared_memory(tx_shm_path)
            error("C process exited before creating RX shared memory")
        end
        if !isfile(rx_shm_path)
            sleep(0.1)
            continue
        end
        try
            rx_shm, rx_chunk_size, rx_num_channels = open_shared_memory(rx_shm_path)
            break
        catch e
            if e isa ErrorException && (
                contains(e.msg, "too small") ||
                contains(e.msg, "Invalid shared memory header")
            )
                sleep(0.01)
                continue
            end
            kill_and_cleanup(proc, rx_shm_path)
            cleanup_shared_memory(tx_shm_path)
            rethrow(e)
        end
    end

    if rx_num_channels != N
        kill_and_cleanup(proc, rx_shm_path)
        cleanup_shared_memory(tx_shm_path)
        error("Expected $N channels but RX shared memory has $rx_num_channels channels")
    end

    # === Create output channels ===
    pipe = PipeChannel{FixedSizeMatrixDefault{Complex{Int16}}}(channel_size)
    warnings = Channel{StreamWarning}(warning_channel_size)
    stats_channel = Channel{TxStats}(stats_buffer_size)

    rx_total_samples = rx_chunk_size * N

    # Pre-allocate RX buffer pool
    num_buffers = channel_size + 2
    rx_buffers =
        [FixedSizeMatrixDefault{Complex{Int16}}(undef, N, rx_chunk_size) for _ = 1:num_buffers]

    # === RX Task ===
    rx_task = Threads.@spawn begin
        chunks_read = UInt64(0)
        buffer_idx = 1
        exit_reason = :unknown
        last_overflow_count = UInt64(0)
        start_time = time()

        try
            while isopen(pipe) && process_running(proc)
                # Check for overflows
                current_overflow_count = get_overflow_count(rx_shm)
                if current_overflow_count > last_overflow_count
                    new_overflows = current_overflow_count - last_overflow_count
                    elapsed = time() - start_time
                    time_str = @sprintf("%.2fs", elapsed)
                    if isopen(warnings) && Base.n_avail(warnings) < warnings.sz_max
                        put!(
                            warnings,
                            StreamWarning(
                                :overflow,
                                time_str,
                                nothing,
                                "DMA overflow #$current_overflow_count ($new_overflows new)",
                            ),
                        )
                    end
                    last_overflow_count = current_overflow_count
                end

                if can_read(rx_shm)
                    read_idx = get_read_index(rx_shm)

                    output_chunk = rx_buffers[buffer_idx]
                    src = Ptr{Complex{Int16}}(slot_data_ptr(rx_shm, read_idx))
                    unsafe_copyto!(pointer(output_chunk), src, rx_total_samples)

                    put!(pipe, output_chunk)

                    buffer_idx = mod1(buffer_idx + 1, num_buffers)
                    chunks_read += 1
                    set_read_index(rx_shm, read_idx + 1)
                elseif is_writer_done(rx_shm)
                    exit_reason = :writer_done
                    break
                else
                    yield()
                    sleep(0.001)
                end
            end

            if exit_reason == :unknown
                if !isopen(pipe)
                    exit_reason = :pipe_closed
                elseif !process_running(proc)
                    exit_reason = :process_exited
                end
            end
        catch e
            if !(e isa InvalidStateException) && !(e isa InterruptException)
                rethrow(e)
            end
            exit_reason = :interrupted
        finally
            try
                close(pipe)
            catch
            end
            finalize_shm!(rx_shm)
            cleanup_shared_memory(rx_shm_path)
        end
    end

    # === TX Task ===
    tx_task = Threads.@spawn begin
        chunks_written = UInt64(0)
        total_samples_written = 0
        last_underflow_count = UInt64(0)
        last_buffer_empty_count = UInt64(0)

        try
            for chunk in input_channel
                # Check for underflows
                current_underflow_count =
                    unsafe_load(Ptr{UInt64}(pointer(tx_shm, TX_OFFSET_ERROR_COUNT)))
                if current_underflow_count > last_underflow_count
                    time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                    if isopen(warnings) &&
                       Base.n_avail(warnings) < warnings.sz_max
                        put!(
                            warnings,
                            StreamWarning(:underflow, time_str, nothing, nothing),
                        )
                    end
                    last_underflow_count = current_underflow_count
                end

                # Check for buffer empty events
                current_buffer_empty_count =
                    unsafe_load(Ptr{UInt64}(pointer(tx_shm, TX_OFFSET_BUFFER_STALL)))
                if current_buffer_empty_count > last_buffer_empty_count
                    new_events = current_buffer_empty_count - last_buffer_empty_count
                    time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                    if isopen(warnings) &&
                       Base.n_avail(warnings) < warnings.sz_max
                        put!(
                            warnings,
                            StreamWarning(
                                :buffer_empty,
                                time_str,
                                nothing,
                                "C sent $new_events zero buffers (total: $current_buffer_empty_count)",
                            ),
                        )
                    end
                    last_buffer_empty_count = current_buffer_empty_count
                end

                # Wait for space in ring buffer
                while !_can_write_tx(tx_shm, num_slots)
                    if !process_running(proc)
                        time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                        if isopen(warnings) &&
                           Base.n_avail(warnings) < warnings.sz_max
                            put!(
                                warnings,
                                StreamWarning(
                                    :error,
                                    time_str,
                                    nothing,
                                    "C process exited unexpectedly",
                                ),
                            )
                        end
                        break
                    end
                    yield()
                end

                if !process_running(proc)
                    break
                end

                # Copy chunk data to TX SHM
                write_idx =
                    unsafe_load(Ptr{UInt64}(pointer(tx_shm, TX_OFFSET_WRITE_INDEX)))
                slot_offset = TX_SHM_HEADER_SIZE + (write_idx % num_slots) * chunk_bytes

                dst = Ptr{Complex{Int16}}(pointer(tx_shm, slot_offset + 1))
                if T === Complex{Int16}
                    if N == 1
                        unsafe_copyto!(dst, pointer(chunk), chunk_size)
                    else
                        for i = 1:chunk_size
                            for c = 1:N
                                unsafe_store!(dst, chunk[i, c], (i - 1) * N + c)
                            end
                        end
                    end
                else
                    if N == 1
                        @inbounds for i = 1:chunk_size
                            unsafe_store!(dst, Complex{Int16}(chunk[i], Int16(0)), i)
                        end
                    else
                        @inbounds for i = 1:chunk_size
                            for c = 1:N
                                unsafe_store!(
                                    dst,
                                    Complex{Int16}(chunk[i, c], Int16(0)),
                                    (i - 1) * N + c,
                                )
                            end
                        end
                    end
                end

                # Atomic release-store write_index
                Core.Intrinsics.atomic_pointerset(
                    Ptr{UInt64}(pointer(tx_shm, TX_OFFSET_WRITE_INDEX)),
                    write_idx + 1,
                    :release,
                )
                chunks_written += 1
                total_samples_written += chunk_size

                # Push stats
                if isopen(stats_channel) &&
                   Base.n_avail(stats_channel) < stats_channel.sz_max
                    put!(stats_channel, TxStats(total_samples_written))
                end
            end
        catch e
            if !(e isa InvalidStateException) && !(e isa InterruptException)
                @error "Duplex TX task failed" exception = (e, catch_backtrace())
            end
            rethrow()
        finally
            # Signal writer done on TX SHM
            flags_ptr = Ptr{UInt16}(pointer(tx_shm, TX_OFFSET_FLAGS))
            current_flags = unsafe_load(flags_ptr)
            unsafe_store!(flags_ptr, current_flags | TX_FLAG_WRITER_DONE)

            # Give C process time to flush
            sleep(0.5)

            # Kill C process
            if process_running(proc)
                kill(proc)
            end

            cleanup_shared_memory(tx_shm_path)

            @info "Duplex stream complete" chunks_written = chunks_written
        end
    end

    bind(pipe, rx_task)
    bind(stats_channel, tx_task)
    bind(warnings, tx_task)
    bind(input_channel, tx_task)

    return (LitexM2SDRChannel{N}(pipe, rx_chunk_size), stats_channel, warnings)
end

# Convenience method for single channel
function stream_litex_m2sdr(
    input_channel::SignalChannel{T,1};
    sample_rate::Unitful.Frequency = 40u"MHz",
    rx_frequency::Unitful.Frequency = 5u"GHz",
    tx_frequency::Unitful.Frequency = 5u"GHz",
    rx_gain::Unitful.Gain = 20u"dB",
    tx_gain::Unitful.Gain = -10u"dB",
    agc_mode::AGCMode = AGC_MANUAL,
    bandwidth::Union{Unitful.Frequency,Nothing} = nothing,
    rx_buffer_time::Unitful.Time = 3u"s",
    tx_buffer_time::Unitful.Time = 3u"s",
    num_samples::Integer = 0,
    rx_shm_path::String = DEFAULT_SHM_PATH,
    tx_shm_path::String = DEFAULT_TX_SHM_PATH,
    device_num::Integer = 0,
    channel_size::Integer = 100,
    warning_channel_size::Integer = 16,
    quiet::Bool = false,
    cmd::Union{Cmd,Nothing} = nothing,
    stats_buffer_size::Integer = 1000,
) where {T<:Union{Complex{Int16},Int16}}
    return stream_litex_m2sdr(
        Val(1),
        input_channel;
        sample_rate,
        rx_frequency,
        tx_frequency,
        rx_gain,
        tx_gain,
        agc_mode,
        bandwidth,
        rx_buffer_time,
        tx_buffer_time,
        num_samples,
        rx_shm_path,
        tx_shm_path,
        device_num,
        channel_size,
        warning_channel_size,
        quiet,
        cmd,
        stats_buffer_size,
    )
end
