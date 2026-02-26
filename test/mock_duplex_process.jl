# Mock full-duplex process — replaces m2sdr_stream_shm for testing.
#
# Combines mock_rx_process.jl (RX producer) and mock_tx_process.jl (TX consumer)
# into a single process with two concurrent tasks.
#
# RX side (producer): Creates RX SHM, writes sequential Complex{Int16} data
# TX side (consumer): Opens TX SHM (with -w wait option), reads data, saves to file
#
# Usage:
#   julia --startup-file=no mock_duplex_process.jl \
#     -rx_shm_path /tmp/test_rx_shm -tx_shm_path /tmp/test_tx_shm \
#     -channels 1 -chunk_size 256 -num_slots 16 -num_chunks 10 \
#     -output_path /tmp/tx_output.bin -w

using Mmap

# Unified SHM Header layout (must match m2sdr_shm.h / rx_streaming.jl / tx_streaming.jl)
const SHM_HEADER_SIZE = 64
const OFFSET_WRITE_INDEX = 1       # UInt64
const OFFSET_READ_INDEX = 9        # UInt64
const OFFSET_ERROR_COUNT = 17      # UInt64
const OFFSET_CHUNK_SIZE = 25       # UInt32
const OFFSET_NUM_SLOTS = 29        # UInt32
const OFFSET_NUM_CHANNELS = 33     # UInt16
const OFFSET_FLAGS = 35            # UInt16
const OFFSET_SAMPLE_SIZE = 37      # UInt32
const OFFSET_BUFFER_STALL = 41     # UInt64
const FLAG_WRITER_DONE = UInt16(1)

function parse_args(args)
    d = Dict{String,String}()
    flags = Set{String}()
    i = 1
    while i <= length(args)
        if args[i] == "-w"
            push!(flags, "w")
            i += 1
        elseif startswith(args[i], "-")
            key = lstrip(args[i], '-')
            d[key] = args[i+1]
            i += 2
        else
            i += 1
        end
    end
    return d, flags
end

function main()
    args, flags = parse_args(ARGS)
    rx_shm_path = args["rx_shm_path"]
    tx_shm_path = args["tx_shm_path"]
    num_channels = parse(Int, get(args, "channels", "1"))
    chunk_size = parse(Int, get(args, "chunk_size", "256"))
    num_slots = parse(Int, get(args, "num_slots", "16"))
    num_chunks = parse(Int, get(args, "num_chunks", "10"))
    output_path = get(args, "output_path", nothing)
    wait_for_tx = "w" in flags

    chunk_bytes = chunk_size * sizeof(Complex{Int16}) * num_channels
    total_size = SHM_HEADER_SIZE + num_slots * chunk_bytes

    # === Wait for TX SHM if -w flag ===
    if wait_for_tx
        timeout_start = time()
        while time() - timeout_start < 10.0
            if isfile(tx_shm_path) && filesize(tx_shm_path) >= SHM_HEADER_SIZE
                break
            end
            sleep(0.01)
        end
        if !isfile(tx_shm_path)
            error("Timeout waiting for TX SHM at $tx_shm_path")
        end
    end

    # === Create RX SHM (this process is the RX producer) ===
    rx_io = open(rx_shm_path, "w+")
    truncate(rx_io, total_size)
    rx_shm = Mmap.mmap(rx_io, Vector{UInt8}, total_size)

    fill!(view(rx_shm, 1:SHM_HEADER_SIZE), 0)
    unsafe_store!(Ptr{UInt32}(pointer(rx_shm, OFFSET_CHUNK_SIZE)), UInt32(chunk_size))
    unsafe_store!(Ptr{UInt32}(pointer(rx_shm, OFFSET_NUM_SLOTS)), UInt32(num_slots))
    unsafe_store!(Ptr{UInt16}(pointer(rx_shm, OFFSET_NUM_CHANNELS)), UInt16(num_channels))
    unsafe_store!(Ptr{UInt32}(pointer(rx_shm, OFFSET_SAMPLE_SIZE)), UInt32(sizeof(Complex{Int16})))

    # === Open TX SHM (this process is the TX consumer) ===
    tx_io = open(tx_shm_path, "r+")
    tx_fsize = filesize(tx_shm_path)
    tx_shm = Mmap.mmap(tx_io, Vector{UInt8}, tx_fsize)

    tx_chunk_size = Int(unsafe_load(Ptr{UInt32}(pointer(tx_shm, OFFSET_CHUNK_SIZE))))
    tx_num_slots = Int(unsafe_load(Ptr{UInt32}(pointer(tx_shm, OFFSET_NUM_SLOTS))))
    tx_num_channels = Int(unsafe_load(Ptr{UInt16}(pointer(tx_shm, OFFSET_NUM_CHANNELS))))
    tx_chunk_bytes = tx_chunk_size * sizeof(Complex{Int16}) * tx_num_channels
    tx_total_samples_per_chunk = tx_chunk_size * tx_num_channels

    # === RX Writer Task (produces data to RX SHM) ===
    rx_task = Threads.@spawn begin
        sample_counter = Int16(1)
        total_samples = chunk_size * num_channels

        for chunk_idx in 0:(num_chunks - 1)
            # Wait for space in ring buffer
            while true
                write_idx = unsafe_load(Ptr{UInt64}(pointer(rx_shm, OFFSET_WRITE_INDEX)))
                read_idx = Core.Intrinsics.atomic_pointerref(
                    Ptr{UInt64}(pointer(rx_shm, OFFSET_READ_INDEX)),
                    :acquire,
                )
                if (write_idx - read_idx) < num_slots
                    break
                end
                sleep(0.001)
            end

            write_idx = unsafe_load(Ptr{UInt64}(pointer(rx_shm, OFFSET_WRITE_INDEX)))
            slot_offset = SHM_HEADER_SIZE + (write_idx % num_slots) * chunk_bytes
            dst = Ptr{Complex{Int16}}(pointer(rx_shm, slot_offset + 1))

            for i in 1:total_samples
                unsafe_store!(dst, Complex{Int16}(sample_counter, sample_counter), i)
                sample_counter = Int16(mod(Int(sample_counter), 32000) + 1)
            end

            Core.Intrinsics.atomic_pointerset(
                Ptr{UInt64}(pointer(rx_shm, OFFSET_WRITE_INDEX)),
                write_idx + 1,
                :release,
            )
        end

        # Set writer_done flag on RX SHM
        flags_ptr = Ptr{UInt16}(pointer(rx_shm, OFFSET_FLAGS))
        unsafe_store!(flags_ptr, FLAG_WRITER_DONE)

        # Wait for reader to consume all data
        timeout_start = time()
        while time() - timeout_start < 30.0
            write_idx = unsafe_load(Ptr{UInt64}(pointer(rx_shm, OFFSET_WRITE_INDEX)))
            read_idx = unsafe_load(Ptr{UInt64}(pointer(rx_shm, OFFSET_READ_INDEX)))
            if read_idx >= write_idx
                break
            end
            sleep(0.01)
        end
    end

    # === TX Reader Task (consumes data from TX SHM) ===
    collected = Complex{Int16}[]

    tx_task = Threads.@spawn begin
        timeout_start = time()
        while time() - timeout_start < 30.0
            write_idx = Core.Intrinsics.atomic_pointerref(
                Ptr{UInt64}(pointer(tx_shm, OFFSET_WRITE_INDEX)),
                :acquire,
            )
            read_idx = unsafe_load(Ptr{UInt64}(pointer(tx_shm, OFFSET_READ_INDEX)))

            if write_idx > read_idx
                slot_offset = SHM_HEADER_SIZE + (read_idx % tx_num_slots) * tx_chunk_bytes
                src = Ptr{Complex{Int16}}(pointer(tx_shm, slot_offset + 1))

                for i in 1:tx_total_samples_per_chunk
                    push!(collected, unsafe_load(src, i))
                end

                Core.Intrinsics.atomic_pointerset(
                    Ptr{UInt64}(pointer(tx_shm, OFFSET_READ_INDEX)),
                    read_idx + 1,
                    :release,
                )
            else
                flags = unsafe_load(Ptr{UInt16}(pointer(tx_shm, OFFSET_FLAGS)))
                if (flags & FLAG_WRITER_DONE) != 0
                    # Drain remaining
                    write_idx = Core.Intrinsics.atomic_pointerref(
                        Ptr{UInt64}(pointer(tx_shm, OFFSET_WRITE_INDEX)),
                        :acquire,
                    )
                    read_idx = unsafe_load(Ptr{UInt64}(pointer(tx_shm, OFFSET_READ_INDEX)))
                    if read_idx >= write_idx
                        break
                    end
                end
                sleep(0.001)
            end
        end
    end

    # Wait for both tasks
    wait(rx_task)
    wait(tx_task)

    # Write collected TX data to output file
    if output_path !== nothing
        open(output_path, "w") do f
            write(f, reinterpret(UInt8, collected))
        end
    end

    # Brief grace period
    sleep(0.1)
end

main()
