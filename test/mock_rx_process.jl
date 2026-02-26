# Mock RX process — replaces m2sdr_rx_stream_shm for testing.
#
# Speaks the same shared memory ring buffer protocol:
# 1. Creates SHM file with valid RX header
# 2. Writes sequential Complex{Int16} data into slots
# 3. Advances write_index with atomic :release store
# 4. Sets FLAG_WRITER_DONE when all chunks are written
# 5. Waits for reader to consume all data, then exits
#
# Usage:
#   julia --startup-file=no mock_rx_process.jl \
#     -shm_path /tmp/test_shm -channels 1 -chunk_size 256 -num_slots 16 -num_chunks 10

using Mmap

# Unified SHM Header layout (must match rx_streaming.jl / m2sdr_shm.h)
const SHM_HEADER_SIZE = 64
const OFFSET_WRITE_INDEX = 1       # UInt64
const OFFSET_READ_INDEX = 9        # UInt64
const OFFSET_ERROR_COUNT = 17      # UInt64 (RX: overflow_count)
const OFFSET_CHUNK_SIZE = 25       # UInt32
const OFFSET_NUM_SLOTS = 29        # UInt32
const OFFSET_NUM_CHANNELS = 33     # UInt16
const OFFSET_FLAGS = 35            # UInt16
const OFFSET_SAMPLE_SIZE = 37      # UInt32
const FLAG_WRITER_DONE = UInt16(1)

function parse_args(args)
    d = Dict{String,String}()
    i = 1
    while i <= length(args)
        if startswith(args[i], "-")
            key = lstrip(args[i], '-')
            d[key] = args[i+1]
            i += 2
        else
            i += 1
        end
    end
    return d
end

function main()
    args = parse_args(ARGS)
    shm_path = args["shm_path"]
    num_channels = parse(Int, get(args, "channels", "1"))
    chunk_size = parse(Int, get(args, "chunk_size", "256"))
    num_slots = parse(Int, get(args, "num_slots", "16"))
    num_chunks = parse(Int, get(args, "num_chunks", "10"))

    chunk_bytes = chunk_size * sizeof(Complex{Int16}) * num_channels
    total_size = SHM_HEADER_SIZE + num_slots * chunk_bytes

    # Create SHM file
    io = open(shm_path, "w+")
    truncate(io, total_size)
    shm = Mmap.mmap(io, Vector{UInt8}, total_size)

    # Initialize header
    fill!(view(shm, 1:SHM_HEADER_SIZE), 0)
    unsafe_store!(Ptr{UInt32}(pointer(shm, OFFSET_CHUNK_SIZE)), UInt32(chunk_size))
    unsafe_store!(Ptr{UInt32}(pointer(shm, OFFSET_NUM_SLOTS)), UInt32(num_slots))
    unsafe_store!(Ptr{UInt16}(pointer(shm, OFFSET_NUM_CHANNELS)), UInt16(num_channels))
    unsafe_store!(Ptr{UInt32}(pointer(shm, OFFSET_SAMPLE_SIZE)), UInt32(sizeof(Complex{Int16})))

    # Write chunks with sequential data
    sample_counter = Int16(1)
    for chunk_idx in 0:(num_chunks - 1)
        # Wait for space in ring buffer (backpressure)
        while true
            write_idx = unsafe_load(Ptr{UInt64}(pointer(shm, OFFSET_WRITE_INDEX)))
            read_idx = Core.Intrinsics.atomic_pointerref(
                Ptr{UInt64}(pointer(shm, OFFSET_READ_INDEX)),
                :acquire,
            )
            if (write_idx - read_idx) < num_slots
                break
            end
            sleep(0.001)
        end

        write_idx = unsafe_load(Ptr{UInt64}(pointer(shm, OFFSET_WRITE_INDEX)))
        slot_offset = SHM_HEADER_SIZE + (write_idx % num_slots) * chunk_bytes
        dst = Ptr{Complex{Int16}}(pointer(shm, slot_offset + 1))

        # Fill with sequential pattern: Complex{Int16}(counter, counter)
        total_samples = chunk_size * num_channels
        for i in 1:total_samples
            unsafe_store!(dst, Complex{Int16}(sample_counter, sample_counter), i)
            sample_counter = Int16(mod(Int(sample_counter), 32000) + 1)
        end

        # Atomic release-store write_index (makes data visible to reader)
        Core.Intrinsics.atomic_pointerset(
            Ptr{UInt64}(pointer(shm, OFFSET_WRITE_INDEX)),
            write_idx + 1,
            :release,
        )
    end

    # Set writer_done flag
    flags_ptr = Ptr{UInt16}(pointer(shm, OFFSET_FLAGS))
    unsafe_store!(flags_ptr, FLAG_WRITER_DONE)

    # Wait for reader to consume all data before exiting
    timeout_start = time()
    while time() - timeout_start < 30.0
        write_idx = unsafe_load(Ptr{UInt64}(pointer(shm, OFFSET_WRITE_INDEX)))
        read_idx = unsafe_load(Ptr{UInt64}(pointer(shm, OFFSET_READ_INDEX)))
        if read_idx >= write_idx
            break
        end
        sleep(0.01)
    end

    # Brief grace period so reader sees writer_done before process exits
    sleep(0.1)
end

main()
