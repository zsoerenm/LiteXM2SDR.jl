# LiteX M2SDR TX (transmit) shared memory streaming

# TX uses the unified SHM header layout (matching m2sdr_shm.h)
# TX Header layout (first 64 bytes, cache-line aligned):
# Bytes  0-7:   write_index (UInt64) - next slot to write
# Bytes  8-15:  read_index (UInt64) - next slot to read
# Bytes 16-23:  error_count (UInt64) - TX: DMA underflows
# Bytes 24-27:  chunk_size (UInt32) - samples per chunk (per channel)
# Bytes 28-31:  num_slots (UInt32) - number of slots in buffer
# Bytes 32-33:  num_channels (UInt16) - number of channels (1 or 2)
# Bytes 34-35:  flags (UInt16) - control flags (bit 0 = writer_done)
# Bytes 36-39:  sample_size (UInt32) - bytes per sample (4 for Complex{Int16})
# Bytes 40-47:  buffer_stall_count (UInt64) - TX: times C found SHM empty (sent zeros)
# Bytes 48-63:  reserved (16 bytes)
const TX_SHM_HEADER_SIZE = 64

# TX Header field offsets (1-indexed for Julia pointer arithmetic)
# These match the unified layout in m2sdr_shm.h
const TX_OFFSET_WRITE_INDEX = 1
const TX_OFFSET_READ_INDEX = 9
const TX_OFFSET_ERROR_COUNT = 17
const TX_OFFSET_CHUNK_SIZE = 25
const TX_OFFSET_NUM_SLOTS = 29
const TX_OFFSET_NUM_CHANNELS = 33
const TX_OFFSET_FLAGS = 35
const TX_OFFSET_SAMPLE_SIZE = 37
const TX_OFFSET_BUFFER_STALL = 41

const TX_FLAG_WRITER_DONE = UInt16(1)

"""
    write_to_litex_m2sdr(input_channel::SignalChannel{T, N};
        sample_rate::Unitful.Frequency=40u"MHz",
        frequency::Unitful.Frequency=5u"GHz",
        gain::Unitful.Gain=-10u"dB",
        bandwidth::Union{Unitful.Frequency,Nothing}=nothing,
        buffer_time::Unitful.Time=3u"s",
        shm_path::String=DEFAULT_TX_SHM_PATH,
        device_num::Integer=0,
        quiet::Bool=false,
        warning_buffer_size::Integer=16,
        stats_buffer_size::Integer=1000
    ) where {T<:Union{Complex{Int16},Int16}, N}

Start the LiteX M2SDR TX streaming process and drain the input channel to the SDR.

This spawns `m2sdr_tx_stream_shm` as a separate C process that reads from shared memory
and streams to the SDR, immune to Julia's GC pauses. A background task drains the
input channel to shared memory.

# Arguments
- `input_channel`: SignalChannel{T, N} where T is Complex{Int16} or Int16. Real Int16 input is converted to Complex{Int16} with zero imaginary part.
- `sample_rate`: Sampling rate (default: 40 MHz)
- `frequency`: TX center frequency (default: 5 GHz)
- `gain`: TX gain in dB (default: -10 dB, negative = attenuation on AD9361)
- `bandwidth`: RF bandwidth (default: same as sample_rate)
- `buffer_time`: Ring buffer duration (default: 3 s)
- `shm_path`: Path to shared memory file
- `device_num`: M2SDR device number (default: 0)
- `quiet`: Suppress C process statistics output (default: false)
- `warning_buffer_size`: Size of the warning channel buffer (default: 16)
- `stats_buffer_size`: Size of the stats channel buffer (default: 1000)

# Returns
- `Tuple{Channel{TxStats}, Channel{StreamWarning}}`: Tuple of (stats channel, warning channel).
  The stats channel receives `TxStats` updates after each chunk is written.
  The warning channel receives underflow warnings from the C process.
  Both channels close when transmission completes.

# Example
```julia
using Unitful: @u_str
using SignalChannels: SignalChannel

# Create a signal source channel
signal_ch = SignalChannel{Complex{Int16}, 1}(2048, 16)

# Start TX streaming
stats_ch, warning_ch = write_to_litex_m2sdr(signal_ch;
    sample_rate=40u"MHz",
    frequency=5u"GHz",
    gain=-10u"dB"
)

# Monitor stats and warnings
@async for stats in stats_ch
    println("Transmitted \$(stats.total_samples) samples")
end
@async for warning in warning_ch
    @warn "TX warning" type=warning.type time=warning.time_str
end

# Generate and send samples
for _ in 1:1000
    chunk = rand(Complex{Int16}, 2048, 1)
    put!(signal_ch, chunk)
end

# Signal done
close(signal_ch)
```
"""
function write_to_litex_m2sdr(
    input_channel::SignalChannel{T,N};
    sample_rate::Unitful.Frequency = 40u"MHz",
    frequency::Unitful.Frequency = 5u"GHz",
    gain::Unitful.Gain = -10u"dB",
    bandwidth::Union{Unitful.Frequency,Nothing} = nothing,
    buffer_time::Unitful.Time = 3u"s",
    shm_path::String = DEFAULT_TX_SHM_PATH,
    device_num::Integer = 0,
    quiet::Bool = false,
    warning_buffer_size::Integer = 16,
    stats_buffer_size::Integer = 1000,
    cmd::Union{Cmd,Nothing} = nothing,
) where {T<:Union{Complex{Int16},Int16},N}
    if N != 1 && N != 2
        error("Number of channels must be 1 or 2, got $N")
    end

    bw = isnothing(bandwidth) ? sample_rate : bandwidth

    # Convert Unitful quantities to numeric values
    sample_rate_hz = Int(ustrip(Hz, sample_rate))
    frequency_hz = Int(ustrip(Hz, frequency))
    gain_db = Int(ustrip(gain))  # Gain is already in dB
    bandwidth_hz = Int(ustrip(Hz, bw))
    buffer_time_s = ustrip(u"s", buffer_time)

    # Get chunk size from the input channel
    chunk_size = input_channel.num_samples
    chunk_bytes = chunk_size * sizeof(Complex{Int16}) * N

    # Calculate number of slots for the ring buffer
    bytes_per_second = sample_rate_hz * sizeof(Complex{Int16}) * N
    total_buffer_bytes = bytes_per_second * buffer_time_s
    num_slots = max(16, Int(ceil(total_buffer_bytes / chunk_bytes)))

    # Create shared memory file
    total_size = TX_SHM_HEADER_SIZE + num_slots * chunk_bytes

    # Remove existing file if present
    if isfile(shm_path)
        rm(shm_path)
    end

    # Create and initialize shared memory
    io = open(shm_path, "w+")
    truncate(io, total_size)
    shm = Mmap.mmap(io, Vector{UInt8}, total_size)
    # Note: We don't close io - the file handle must stay open for the mmap to remain valid

    # Initialize header (unified layout matching m2sdr_shm.h)
    fill!(view(shm, 1:TX_SHM_HEADER_SIZE), 0)
    unsafe_store!(Ptr{UInt32}(pointer(shm, TX_OFFSET_CHUNK_SIZE)), UInt32(chunk_size))
    unsafe_store!(Ptr{UInt32}(pointer(shm, TX_OFFSET_NUM_SLOTS)), UInt32(num_slots))
    unsafe_store!(Ptr{UInt16}(pointer(shm, TX_OFFSET_NUM_CHANNELS)), UInt16(N))
    unsafe_store!(
        Ptr{UInt32}(pointer(shm, TX_OFFSET_SAMPLE_SIZE)),
        UInt32(sizeof(Complex{Int16})),
    )

    @info "Created TX shared memory ring buffer" path = shm_path chunk_size num_channels = N num_slots

    # Build the command for the C streaming process (or use provided cmd for testing)
    if cmd === nothing
        cmd = `$(m2sdr_tx_stream_shm())
            -c $(device_num)
            -samplerate $(sample_rate_hz)
            -tx_freq $(frequency_hz)
            -tx_gain $(gain_db)
            -bandwidth $(bandwidth_hz)
            -channels $(N)
            -shm_path $(shm_path)
            -num_samples 0`

        if quiet
            cmd = `$cmd -q`
        end
    end

    @info "Starting LiteX M2SDR TX stream" sample_rate frequency gain channels = N

    # When not quiet, redirect C process output to a log file since the Julia GUI
    # would otherwise overwrite it. The log file can be monitored with: tail -f /tmp/m2sdr_tx.log
    if !quiet
        log_file = "/tmp/m2sdr_tx.log"
        @info "C process stats redirected to $log_file (use: tail -f $log_file)"
        log_io = open(log_file, "w")
        proc = run(pipeline(cmd; stderr = log_io, stdout = log_io); wait = false)
    else
        proc = run(cmd; wait = false)
    end

    # Give the C process time to initialize
    sleep(0.5)

    # Check if C process started successfully - fail early with clear error
    if !process_running(proc)
        wait(proc)  # Ensure process fully terminates to get exit code
        exit_code = proc.exitcode
        log_content = if !quiet
            try
                read(log_file, String)[1:min(2000, end)]  # First 2000 chars of log
            catch
                "(could not read log file)"
            end
        else
            "(logging disabled)"
        end
        error("""
            TX C process (m2sdr_tx_stream_shm) failed to start or exited immediately.
            Exit code: $exit_code

            Common causes:
            - Another m2sdr process is already using the SDR device
              (check with: pgrep -a m2sdr)
            - SDR device not available or permissions issue
            - DMA initialization failed

            Log output:
            $log_content
            """)
    end

    # Create output channels matching stream_data interface
    stats_channel = Channel{TxStats}(stats_buffer_size)
    warning_channel = Channel{StreamWarning}(warning_buffer_size)

    # Spawn background task to drain the input channel to shared memory
    task = Threads.@spawn begin
        chunks_written = UInt64(0)
        total_samples_written = 0
        last_underflow_count = UInt64(0)
        last_buffer_empty_count = UInt64(0)

        try
            for chunk in input_channel
                # Check for underflows reported by C process
                current_underflow_count =
                    unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_ERROR_COUNT)))
                if current_underflow_count > last_underflow_count
                    time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                    if isopen(warning_channel) &&
                       Base.n_avail(warning_channel) < warning_channel.sz_max
                        put!(
                            warning_channel,
                            StreamWarning(:underflow, time_str, nothing, nothing),
                        )
                    end
                    last_underflow_count = current_underflow_count
                end

                # Check for buffer empty events (C sent zeros because Julia was slow)
                current_buffer_empty_count =
                    unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_BUFFER_STALL)))
                if current_buffer_empty_count > last_buffer_empty_count
                    new_events = current_buffer_empty_count - last_buffer_empty_count
                    time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                    if isopen(warning_channel) &&
                       Base.n_avail(warning_channel) < warning_channel.sz_max
                        put!(
                            warning_channel,
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

                # Wait for space in the ring buffer
                while !_can_write_tx(shm, num_slots)
                    if !process_running(proc)
                        # Emit warning about unexpected process exit
                        time_str = @sprintf("%.2fs", total_samples_written / sample_rate_hz)
                        if isopen(warning_channel) &&
                           Base.n_avail(warning_channel) < warning_channel.sz_max
                            put!(
                                warning_channel,
                                StreamWarning(
                                    :error,
                                    time_str,
                                    nothing,
                                    "TX C process exited unexpectedly",
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

                # Get write slot
                write_idx =
                    unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_WRITE_INDEX)))
                slot_offset = TX_SHM_HEADER_SIZE + (write_idx % num_slots) * chunk_bytes

                # Copy chunk data to shared memory
                # Input chunk is (num_samples, N), C code expects interleaved Complex{Int16}
                dst = Ptr{Complex{Int16}}(pointer(shm, slot_offset + 1))
                if T === Complex{Int16}
                    if N == 1
                        # Single channel complex: direct copy
                        unsafe_copyto!(dst, pointer(chunk), chunk_size)
                    else
                        # Multi-channel complex: transpose to interleaved format
                        for i = 1:chunk_size
                            for c = 1:N
                                unsafe_store!(dst, chunk[i, c], (i - 1) * N + c)
                            end
                        end
                    end
                else
                    # Real Int16 input: convert to Complex{Int16} with zero imaginary part
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

                # Atomic release-store: ensures all sample data is visible before the index update.
                # Using atomic_pointerset with :release ordering provides a proper release-store
                # that synchronizes with the C consumer's acquire-load of write_index.
                # A fence + plain store is insufficient - the plain store can still be reordered.
                Core.Intrinsics.atomic_pointerset(
                    Ptr{UInt64}(pointer(shm, TX_OFFSET_WRITE_INDEX)),
                    write_idx + 1,
                    :release,
                )
                chunks_written += 1
                total_samples_written += chunk_size

                # Push stats update (non-blocking if channel is full)
                if isopen(stats_channel) &&
                   Base.n_avail(stats_channel) < stats_channel.sz_max
                    put!(stats_channel, TxStats(total_samples_written))
                end
            end
        catch e
            if !(e isa InvalidStateException) && !(e isa InterruptException)
                @error "TX task failed" exception = (e, catch_backtrace())
            end
            rethrow()
        finally
            # Signal writer done
            flags_ptr = Ptr{UInt16}(pointer(shm, TX_OFFSET_FLAGS))
            current_flags = unsafe_load(flags_ptr)
            unsafe_store!(flags_ptr, current_flags | TX_FLAG_WRITER_DONE)

            # Give the C process time to finish transmitting buffered data
            sleep(0.5)

            # Kill C process and cleanup
            if process_running(proc)
                kill(proc)
            end
            cleanup_shared_memory(shm_path)

            # Don't close stats_channel and warning_channel here - let bind handle it
            # so that any exception is properly propagated to consumers

            @info "TX stream complete" chunks_written
        end
    end

    bind(stats_channel, task)
    bind(warning_channel, task)
    bind(input_channel, task)

    return (stats_channel, warning_channel)
end

# Helper function to check if there's space to write
@inline function _can_write_tx(shm::Vector{UInt8}, num_slots::Int)
    write_idx = unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_WRITE_INDEX)))
    # Atomic acquire-load: synchronizes with C consumer's release-store of read_index.
    # Using atomic_pointerref with :acquire ordering ensures we see all memory writes
    # that happened before the C side's release-store. A plain load + acquire fence
    # is insufficient because the fence comes after the load.
    read_idx = Core.Intrinsics.atomic_pointerref(
        Ptr{UInt64}(pointer(shm, TX_OFFSET_READ_INDEX)),
        :acquire,
    )
    return (write_idx - read_idx) < num_slots
end
