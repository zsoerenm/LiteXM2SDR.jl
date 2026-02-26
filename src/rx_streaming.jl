# LiteX M2SDR RX (receive) shared memory streaming

"""
    LitexM2SDRChannel{N}

A channel of SDR samples from the LiteX M2SDR.

Type parameters:
- `N`: Number of antenna channels (1 or 2, compile-time constant)

Each iteration yields a chunk:
- `chunk`: `FixedSizeMatrixDefault{Complex{Int16}}` of shape `(N, num_samples)`

Overflow information is provided via the warnings channel returned from
`read_from_litex_m2sdr()`.

The channel supports iteration and can be converted to a `SignalChannel` using
`sdr_chunks_to_signal_channel()`.

# Example
```julia
ch, warnings = read_from_litex_m2sdr(Val(1); sample_rate=40e6)

# Optionally monitor warnings in background
@async for w in warnings
    @warn "Overflow detected" w.type w.time_str
end

for chunk in ch
    # chunk is (1, 2048) Complex{Int16} matrix
end
```
"""
struct LitexM2SDRChannel{N}
    pipe::PipeChannel{FixedSizeMatrixDefault{Complex{Int16}}}
    num_samples::Int
end

# Forward iteration to the underlying PipeChannel
Base.iterate(ch::LitexM2SDRChannel) = iterate(ch.pipe)
Base.iterate(ch::LitexM2SDRChannel, state) = iterate(ch.pipe, state)
Base.IteratorSize(::Type{<:LitexM2SDRChannel}) = Base.SizeUnknown()
Base.eltype(::Type{LitexM2SDRChannel{N}}) where {N} = FixedSizeMatrixDefault{Complex{Int16}}

# Channel operations
Base.isopen(ch::LitexM2SDRChannel) = isopen(ch.pipe)
Base.isready(ch::LitexM2SDRChannel) = isready(ch.pipe)
function Base.close(ch::LitexM2SDRChannel)
    close(ch.pipe, InvalidStateException("Channel closed", :closed))
end
Base.take!(ch::LitexM2SDRChannel) = take!(ch.pipe)
Base.bind(ch::LitexM2SDRChannel, task::Task) = bind(ch.pipe, task)

# Accessor for number of antenna channels (compile-time)
num_channels(::LitexM2SDRChannel{N}) where {N} = N
num_channels(::Type{LitexM2SDRChannel{N}}) where {N} = N

# =============================================================================
# Unified SHM Header Layout (64 bytes, matching m2sdr_shm.h)
# =============================================================================
#
# Bytes  0-7:   write_index (UInt64) - next slot to write (producer)
# Bytes  8-15:  read_index (UInt64) - next slot to read (consumer)
# Bytes 16-23:  error_count (UInt64) - RX: DMA overflows; TX: DMA underflows
# Bytes 24-27:  chunk_size (UInt32) - samples per chunk (per channel)
# Bytes 28-31:  num_slots (UInt32) - number of slots in buffer
# Bytes 32-33:  num_channels (UInt16) - 1 or 2
# Bytes 34-35:  flags (UInt16) - bit 0 = writer_done
# Bytes 36-39:  sample_size (UInt32) - bytes per sample (4 for Complex{Int16})
# Bytes 40-47:  buffer_stall_count (UInt64) - RX: buffer-full waits; TX: buffer-empty events
# Bytes 48-63:  reserved (16 bytes)
#
# No per-chunk header - pure sample data follows immediately
const SHM_HEADER_SIZE = 64

# Header field offsets (1-indexed for Julia pointer arithmetic)
const OFFSET_WRITE_INDEX = 1
const OFFSET_READ_INDEX = 9
const OFFSET_ERROR_COUNT = 17
const OFFSET_CHUNK_SIZE = 25
const OFFSET_NUM_SLOTS = 29
const OFFSET_NUM_CHANNELS = 33
const OFFSET_FLAGS = 35
const OFFSET_SAMPLE_SIZE = 37
const OFFSET_BUFFER_STALL = 41

const FLAG_WRITER_DONE = UInt16(1)

"""
    SharedMemoryRingBuffer

A shared memory ring buffer for transferring SDR samples between processes.

# Fields
- `data`: The mmap'd shared memory region
- `num_slots`: Number of chunk slots in the buffer
- `chunk_bytes`: Size of each chunk in bytes
"""
struct SharedMemoryRingBuffer
    data::Vector{UInt8}
    num_slots::Int
    chunk_bytes::Int
end

# Atomic accessors for ring buffer
@inline function get_write_index(shm::SharedMemoryRingBuffer)
    Core.Intrinsics.atomic_pointerref(
        Ptr{UInt64}(pointer(shm.data, OFFSET_WRITE_INDEX)),
        :acquire,
    )
end

@inline function get_read_index(shm::SharedMemoryRingBuffer)
    unsafe_load(Ptr{UInt64}(pointer(shm.data, OFFSET_READ_INDEX)))
end

@inline function set_read_index(shm::SharedMemoryRingBuffer, val::UInt64)
    Core.Intrinsics.atomic_pointerset(
        Ptr{UInt64}(pointer(shm.data, OFFSET_READ_INDEX)),
        val,
        :release,
    )
end

@inline function get_overflow_count(shm::SharedMemoryRingBuffer)
    unsafe_load(Ptr{UInt64}(pointer(shm.data, OFFSET_ERROR_COUNT)))
end

@inline function get_flags(shm::SharedMemoryRingBuffer)
    unsafe_load(Ptr{UInt16}(pointer(shm.data, OFFSET_FLAGS)))
end

@inline function is_writer_done(shm::SharedMemoryRingBuffer)
    (get_flags(shm) & FLAG_WRITER_DONE) != 0
end

# Get pointer to slot data (no per-slot header, pure samples)
@inline function slot_data_ptr(shm::SharedMemoryRingBuffer, slot::UInt64)
    offset = SHM_HEADER_SIZE + Int(slot % shm.num_slots) * shm.chunk_bytes
    pointer(shm.data, offset + 1)
end

# Check if we can read (buffer not empty)
@inline function can_read(shm::SharedMemoryRingBuffer)
    write_idx = get_write_index(shm)
    read_idx = get_read_index(shm)
    write_idx > read_idx
end

"""
    open_shared_memory(path)

Open an existing shared memory ring buffer for reading.
"""
function open_shared_memory(path::String)
    if !isfile(path)
        error("Shared memory not found at $path - start writer first")
    end

    data = open(path, "r+") do f
        fsize = filesize(f)
        if fsize < SHM_HEADER_SIZE
            error("Shared memory file too small: $fsize bytes (need at least $SHM_HEADER_SIZE)")
        end
        Mmap.mmap(f, Vector{UInt8}, fsize)
    end

    if length(data) < SHM_HEADER_SIZE
        error("Mmap too small: $(length(data)) bytes")
    end

    # Read metadata from header
    chunk_size = Int(unsafe_load(Ptr{UInt32}(pointer(data, OFFSET_CHUNK_SIZE))))
    num_slots = Int(unsafe_load(Ptr{UInt32}(pointer(data, OFFSET_NUM_SLOTS))))
    num_channels = Int(unsafe_load(Ptr{UInt16}(pointer(data, OFFSET_NUM_CHANNELS))))

    if chunk_size == 0 || num_slots == 0 || num_channels == 0
        error(
            "Invalid shared memory header: chunk_size=$chunk_size, num_slots=$num_slots, num_channels=$num_channels",
        )
    end

    # chunk_bytes = samples * sizeof(Complex{Int16}) * channels
    chunk_bytes = chunk_size * 4 * num_channels

    shm = SharedMemoryRingBuffer(data, num_slots, chunk_bytes)

    @info "Opened shared memory ring buffer" path = path chunk_size = chunk_size num_channels =
        num_channels num_slots = num_slots

    return shm, chunk_size, num_channels
end

"""
    finalize_shm!(shm::SharedMemoryRingBuffer)

Finalize the shared memory buffer by syncing and releasing the mmap.
Must be called before deleting the shared memory file to prevent segfaults.
"""
function finalize_shm!(shm::SharedMemoryRingBuffer)
    Mmap.sync!(shm.data)
    finalize(shm.data)
end

"""
    read_from_litex_m2sdr(::Val{N};
        sample_rate::Unitful.Frequency=40u"MHz",
        frequency::Unitful.Frequency=5u"GHz",
        gain::Unitful.Gain=20u"dB",
        agc_mode::AGCMode=AGC_MANUAL,
        bandwidth::Union{Unitful.Frequency,Nothing}=nothing,
        buffer_time::Unitful.Time=3u"s",
        num_samples::Integer=0,
        shm_path::String=DEFAULT_SHM_PATH,
        device_num::Integer=0,
        channel_size::Integer=100,
        warning_channel_size::Integer=16,
        quiet::Bool=false
    ) where N

Start the LiteX M2SDR streaming process and return a channel of samples.

This spawns `m2sdr_rx_stream_shm` as a separate C process that streams SDR data
to shared memory, immune to Julia's GC pauses. The C process is automatically
killed when the channel is closed or iteration stops.

# Arguments
- `::Val{N}`: Number of antenna channels (1 or 2, compile-time constant)
- `sample_rate`: Sampling rate (default: 40 MHz)
- `frequency`: RX center frequency (default: 5 GHz)
- `gain`: RX gain in dB (default: 20 dB). In manual mode, this is the fixed gain.
  In AGC modes, this is the initial gain before AGC takes over.
- `agc_mode`: Automatic Gain Control mode (default: `AGC_MANUAL`)
  - `AGC_MANUAL`: Fixed gain (no automatic adjustment)
  - `AGC_FAST_ATTACK`: Quickly adapts to signal level changes
  - `AGC_SLOW_ATTACK`: Gradually adapts to signal level changes
  - `AGC_HYBRID`: Combines fast and slow attack characteristics
- `bandwidth`: RF bandwidth (default: same as sample_rate)
- `buffer_time`: Ring buffer duration (default: 3 s)
- `num_samples`: Number of samples to capture (0 = infinite)
- `shm_path`: Path to shared memory file
- `device_num`: M2SDR device number (default: 0)
- `channel_size`: Size of output channel buffer (default: 100)
- `warning_channel_size`: Size of warning channel buffer (default: 16)
- `quiet`: Suppress C process statistics output (default: false)

# Returns
A tuple of:
- `LitexM2SDRChannel{N}`: Channel yielding `FixedSizeMatrixDefault{Complex{Int16}}` chunks of shape `(N, num_samples)`
- `Channel{StreamWarning}`: Channel receiving overflow warnings when the C process detects DMA overflows

# Example
```julia
using Unitful: u"Hz", u"MHz", u"GHz", u"dB"

# Manual gain control (default)
ch, warnings = read_from_litex_m2sdr(Val(1); sample_rate=40u"MHz", frequency=5u"GHz", gain=20u"dB")

# Optionally monitor warnings in background
@async for w in warnings
    @warn "Overflow detected" w.type w.time_str
end

for chunk in ch
    # chunk is (1, ch.num_samples) Complex{Int16} matrix
end
# C process is automatically killed when loop exits
```
"""
function read_from_litex_m2sdr(
    ::Val{N};
    sample_rate::Unitful.Frequency = 40u"MHz",
    frequency::Unitful.Frequency = 5u"GHz",
    gain::Unitful.Gain = 20u"dB",
    agc_mode::AGCMode = AGC_MANUAL,
    bandwidth::Union{Unitful.Frequency,Nothing} = nothing,
    buffer_time::Unitful.Time = 3u"s",
    num_samples::Integer = 0,
    shm_path::String = DEFAULT_SHM_PATH,
    device_num::Integer = 0,
    channel_size::Integer = 100,
    warning_channel_size::Integer = 16,
    quiet::Bool = false,
    cmd::Union{Cmd,Nothing} = nothing,
) where {N}
    if N != 1 && N != 2
        error("Number of channels must be 1 or 2, got $N")
    end

    bw = isnothing(bandwidth) ? sample_rate : bandwidth

    # Convert Unitful quantities to numeric values
    sample_rate_hz = Int(ustrip(Hz, sample_rate))
    frequency_hz = Int(ustrip(Hz, frequency))
    gain_db = Int(ustrip(gain))
    bandwidth_hz = Int(ustrip(Hz, bw))
    buffer_time_s = ustrip(u"s", buffer_time)

    # Get AGC mode string
    agc_mode_str = AGC_MODE_STRINGS[agc_mode]

    # Build the command for the C streaming process (or use provided cmd for testing)
    if cmd === nothing
        cmd = `$(m2sdr_rx_stream_shm())
            -c $(device_num)
            -samplerate $(sample_rate_hz)
            -rx_freq $(frequency_hz)
            -rx_gain $(gain_db)
            -agc_mode $(agc_mode_str)
            -bandwidth $(bandwidth_hz)
            -channels $(N)
            -shm_path $(shm_path)
            -buffer_time $(buffer_time_s)
            -num_samples $(num_samples)`

        if quiet
            cmd = `$cmd -q`
        end
    end

    # Clean up stale shared memory
    if isfile(shm_path)
        @warn "Removing stale shared memory file" path = shm_path
        rm(shm_path)
    end

    # Redirect output to log file
    log_path = "/tmp/m2sdr_rx_stream.log"
    @info "Starting LiteX M2SDR stream" sample_rate frequency gain agc_mode channels = N log_file =
        log_path
    log_io = open(log_path, "w")
    proc = run(pipeline(cmd; stderr = log_io, stdout = log_io); wait = false)

    # Wait for shared memory initialization
    timeout_start = time()
    local shm, chunk_size, shm_num_channels
    while true
        if time() - timeout_start > 10.0
            kill_and_cleanup(proc, shm_path)
            error("Timeout waiting for shared memory file to be initialized")
        end
        if !isfile(shm_path)
            sleep(0.1)
            continue
        end
        try
            shm, chunk_size, shm_num_channels = open_shared_memory(shm_path)
            break
        catch e
            if e isa ErrorException && (
                contains(e.msg, "too small") ||
                contains(e.msg, "Invalid shared memory header")
            )
                sleep(0.01)
                continue
            end
            kill_and_cleanup(proc, shm_path)
            rethrow(e)
        end
    end

    if shm_num_channels != N
        kill_and_cleanup(proc, shm_path)
        error("Expected $N channels but shared memory has $shm_num_channels channels")
    end

    # Output channel: just chunks (no lost samples tuple)
    pipe = PipeChannel{FixedSizeMatrixDefault{Complex{Int16}}}(channel_size)

    # Warnings channel for overflow notifications
    warnings = Channel{StreamWarning}(warning_channel_size)

    # Total samples per chunk
    total_samples = chunk_size * N

    # Pre-allocate buffer pool
    num_buffers = channel_size + 2
    buffers =
        [FixedSizeMatrixDefault{Complex{Int16}}(undef, N, chunk_size) for _ = 1:num_buffers]

    task = Threads.@spawn begin
        chunks_read = UInt64(0)
        buffer_idx = 1
        exit_reason = :unknown
        last_overflow_count = UInt64(0)
        start_time = time()

        try
            while isopen(pipe) && process_running(proc)
                # Check for new overflows from C process
                current_overflow_count = get_overflow_count(shm)
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

                if can_read(shm)
                    read_idx = get_read_index(shm)

                    # Copy sample data directly (no chunk header to skip)
                    output_chunk = buffers[buffer_idx]
                    src = Ptr{Complex{Int16}}(slot_data_ptr(shm, read_idx))
                    unsafe_copyto!(pointer(output_chunk), src, total_samples)

                    put!(pipe, output_chunk)

                    buffer_idx = mod1(buffer_idx + 1, num_buffers)
                    chunks_read += 1
                    set_read_index(shm, read_idx + 1)
                elseif is_writer_done(shm)
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

            if exit_reason == :process_exited
                wait(proc)
                exit_code = proc.exitcode
                if exit_code != 0
                    @error "C streaming process exited with error" exit_code chunks_read
                    error(
                        "m2sdr_rx_stream_shm exited with code $exit_code after $chunks_read chunks",
                    )
                else
                    @warn "C streaming process exited unexpectedly" exit_code chunks_read
                end
            end
        catch e
            if !(e isa InvalidStateException) && !(e isa InterruptException)
                rethrow(e)
            end
            exit_reason = :interrupted
        finally
            if process_running(proc)
                kill(proc)
                try
                    wait(proc)
                catch
                end
            end
            try
                close(pipe)
            catch
            end
            try
                close(warnings)
            catch
            end
            finalize_shm!(shm)
            cleanup_shared_memory(shm_path)
        end
    end

    bind(pipe, task)
    bind(warnings, task)
    return (LitexM2SDRChannel{N}(pipe, chunk_size), warnings)
end

# Convenience method for single channel
function read_from_litex_m2sdr(;
    sample_rate::Unitful.Frequency = 40u"MHz",
    frequency::Unitful.Frequency = 5u"GHz",
    gain::Unitful.Gain = 20u"dB",
    agc_mode::AGCMode = AGC_MANUAL,
    bandwidth::Union{Unitful.Frequency,Nothing} = nothing,
    buffer_time::Unitful.Time = 3u"s",
    num_samples::Integer = 0,
    shm_path::String = DEFAULT_SHM_PATH,
    device_num::Integer = 0,
    channel_size::Integer = 100,
    warning_channel_size::Integer = 16,
    quiet::Bool = false,
    cmd::Union{Cmd,Nothing} = nothing,
)
    return read_from_litex_m2sdr(
        Val(1);
        sample_rate,
        frequency,
        gain,
        agc_mode,
        bandwidth,
        buffer_time,
        num_samples,
        shm_path,
        device_num,
        channel_size,
        warning_channel_size,
        quiet,
        cmd,
    )
end

"""
    get_shm_stats(path::String=DEFAULT_SHM_PATH)

Get statistics from a shared memory ring buffer.

Returns a NamedTuple with:
- `write_index`: Current write index
- `read_index`: Current read index
- `overflow_count`: Number of DMA overflows
- `writer_done`: Whether the writer has finished
"""
function get_shm_stats(path::String = DEFAULT_SHM_PATH)
    if !isfile(path)
        error("Shared memory not found at $path")
    end

    shm, _, _ = open_shared_memory(path)

    return (
        write_index = get_write_index(shm),
        read_index = get_read_index(shm),
        overflow_count = get_overflow_count(shm),
        writer_done = is_writer_done(shm),
    )
end
