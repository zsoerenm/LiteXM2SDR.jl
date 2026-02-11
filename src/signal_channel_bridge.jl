# Conversion from LitexM2SDRChannel to SignalChannel

"""
    sdr_chunks_to_signal_channel(in::LitexM2SDRChannel{N}, channel_size::Integer=100) where {N}

Convert a LitexM2SDRChannel to a SignalChannel.

Input: LitexM2SDRChannel{N} yielding chunks
Output: SignalChannel{Complex{Int16}, N} with shape (num_samples, N)

Note: Overflow warnings are provided by the warnings channel returned from
`read_from_litex_m2sdr()`, not from this function.
"""
function sdr_chunks_to_signal_channel(
    in::LitexM2SDRChannel{N},
    channel_size::Integer = 100,
) where {N}
    num_samples = in.num_samples

    out = SignalChannel{Complex{Int16},N}(num_samples, channel_size)

    # Pre-allocate buffer pool for N > 1 case
    num_buffers = channel_size + 2
    output_buffers = [
        FixedSizeMatrixDefault{Complex{Int16}}(undef, num_samples, N) for _ = 1:num_buffers
    ]

    task = Threads.@spawn begin
        buffer_idx = 1

        for sdr_chunk in in
            output_buffer = output_buffers[buffer_idx]
            if N == 1
                # Copy to output buffer to avoid race condition with input buffer pool
                copyto!(output_buffer, sdr_chunk)
            else
                # In-place transpose for multi-channel
                permutedims!(output_buffer, sdr_chunk, (2, 1))
            end
            put!(out, output_buffer)
            buffer_idx = mod1(buffer_idx + 1, num_buffers)
        end
    end

    bind(out, task)
    bind(in, task)
    return out
end
