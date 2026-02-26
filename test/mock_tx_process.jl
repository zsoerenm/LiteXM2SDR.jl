# Mock TX process — replaces m2sdr_tx_stream_shm for testing.
#
# Speaks the same shared memory ring buffer protocol:
# 1. Opens SHM file created by Julia (write_to_litex_m2sdr creates it)
# 2. Reads data from slots as they become available
# 3. Advances read_index with atomic :release store
# 4. When FLAG_WRITER_DONE is set and all data consumed, writes collected
#    samples to output_path as raw bytes for verification
# 5. Exits
#
# Usage:
#   julia --startup-file=no mock_tx_process.jl \
#     -shm_path /tmp/test_tx_shm -output_path /tmp/tx_output.bin

using Mmap

# Unified SHM Header layout (must match tx_streaming.jl / m2sdr_shm.h)
const TX_SHM_HEADER_SIZE = 64
const TX_OFFSET_WRITE_INDEX = 1      # UInt64
const TX_OFFSET_READ_INDEX = 9       # UInt64
const TX_OFFSET_ERROR_COUNT = 17     # UInt64 (TX: underflow_count)
const TX_OFFSET_CHUNK_SIZE = 25      # UInt32
const TX_OFFSET_NUM_SLOTS = 29       # UInt32
const TX_OFFSET_NUM_CHANNELS = 33    # UInt16
const TX_OFFSET_FLAGS = 35           # UInt16
const TX_OFFSET_SAMPLE_SIZE = 37     # UInt32
const TX_OFFSET_BUFFER_STALL = 41    # UInt64 (TX: buffer_empty_count)
const TX_FLAG_WRITER_DONE = UInt16(1)

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
    output_path = get(args, "output_path", nothing)

    # Wait for SHM file to appear and have content
    timeout_start = time()
    while time() - timeout_start < 10.0
        if isfile(shm_path) && filesize(shm_path) >= TX_SHM_HEADER_SIZE
            break
        end
        sleep(0.01)
    end

    if !isfile(shm_path)
        error("Timeout waiting for SHM file at $shm_path")
    end

    # Open SHM file
    io = open(shm_path, "r+")
    fsize = filesize(shm_path)
    shm = Mmap.mmap(io, Vector{UInt8}, fsize)

    # Read header
    chunk_size = Int(unsafe_load(Ptr{UInt32}(pointer(shm, TX_OFFSET_CHUNK_SIZE))))
    num_slots = Int(unsafe_load(Ptr{UInt32}(pointer(shm, TX_OFFSET_NUM_SLOTS))))
    num_channels = Int(unsafe_load(Ptr{UInt16}(pointer(shm, TX_OFFSET_NUM_CHANNELS))))
    chunk_bytes = chunk_size * sizeof(Complex{Int16}) * num_channels
    total_samples_per_chunk = chunk_size * num_channels

    # Collect all received data
    collected = Complex{Int16}[]

    timeout_start = time()
    while time() - timeout_start < 30.0
        write_idx = Core.Intrinsics.atomic_pointerref(
            Ptr{UInt64}(pointer(shm, TX_OFFSET_WRITE_INDEX)),
            :acquire,
        )
        read_idx = unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_READ_INDEX)))

        if write_idx > read_idx
            slot_offset = TX_SHM_HEADER_SIZE + (read_idx % num_slots) * chunk_bytes
            src = Ptr{Complex{Int16}}(pointer(shm, slot_offset + 1))

            for i in 1:total_samples_per_chunk
                push!(collected, unsafe_load(src, i))
            end

            # Atomic release-store read_index (signals Julia writer the slot is free)
            Core.Intrinsics.atomic_pointerset(
                Ptr{UInt64}(pointer(shm, TX_OFFSET_READ_INDEX)),
                read_idx + 1,
                :release,
            )
        else
            # No data available — check if writer is done
            flags = unsafe_load(Ptr{UInt16}(pointer(shm, TX_OFFSET_FLAGS)))
            if (flags & TX_FLAG_WRITER_DONE) != 0
                # Drain any remaining data
                write_idx = Core.Intrinsics.atomic_pointerref(
                    Ptr{UInt64}(pointer(shm, TX_OFFSET_WRITE_INDEX)),
                    :acquire,
                )
                read_idx = unsafe_load(Ptr{UInt64}(pointer(shm, TX_OFFSET_READ_INDEX)))
                if read_idx >= write_idx
                    break
                end
            end
            sleep(0.001)
        end
    end

    # Write collected data to output file for verification
    if output_path !== nothing
        open(output_path, "w") do f
            write(f, reinterpret(UInt8, collected))
        end
    end
end

main()
