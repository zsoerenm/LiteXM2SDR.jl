# LiteXM2SDR.jl

Julia package for real-time SDR streaming with the [LiteX M2SDR](https://github.com/enjoy-digital/litex_m2sdr), using shared memory ring buffers to communicate with C processes immune to GC pauses.

## Features

- **RX streaming** — receive IQ samples from the AD9361 frontend via `read_from_litex_m2sdr`
- **TX streaming** — transmit IQ samples via `write_to_litex_m2sdr`
- **Lock-free shared memory** — data flows through memory-mapped ring buffers with atomic operations, keeping the C streaming process decoupled from Julia's garbage collector
- **Multi-channel support** — 1 or 2 antenna channels (SISO/MIMO)
- **AGC modes** — manual, fast attack, slow attack, and hybrid automatic gain control
- **SignalChannel integration** — convert SDR chunks to `SignalChannel` for downstream processing via `sdr_chunks_to_signal_channel`

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaComputing/LiteXM2SDR.jl")
```

## Quick Start

### Receiving

```julia
using LiteXM2SDR
using Unitful: @u_str

# Start RX streaming (single channel)
ch, warnings = read_from_litex_m2sdr(Val(1);
    sample_rate=40u"MHz",
    frequency=2.4u"GHz",
    gain=20u"dB",
)

# Process received chunks
for chunk in ch
    # chunk is a (1, num_samples) matrix of Complex{Int16}
    println("Received $(size(chunk, 2)) samples")
end
```

### Transmitting

```julia
using LiteXM2SDR
using SignalChannels: SignalChannel
using Unitful: @u_str

# Create a signal source
signal_ch = SignalChannel{Complex{Int16}, 1}(2048, 16)

# Start TX streaming
stats_ch, warning_ch = write_to_litex_m2sdr(signal_ch;
    sample_rate=40u"MHz",
    frequency=5u"GHz",
    gain=-10u"dB",
)

# Feed samples
for _ in 1:1000
    chunk = rand(Complex{Int16}, 2048, 1)
    put!(signal_ch, chunk)
end
close(signal_ch)
```

### Converting to SignalChannel

```julia
ch, warnings = read_from_litex_m2sdr(Val(1); sample_rate=40u"MHz", frequency=2.4u"GHz")
signal_ch = sdr_chunks_to_signal_channel(ch)

# signal_ch is a SignalChannel{Complex{Int16}, 1} ready for downstream processing
```

## API Reference

### RX

- `read_from_litex_m2sdr(Val(N); kwargs...)` — start RX streaming with N channels. Returns `(LitexM2SDRChannel{N}, Channel{StreamWarning})`.
- `sdr_chunks_to_signal_channel(ch)` — convert a `LitexM2SDRChannel` to a `SignalChannel`.
- `get_shm_stats(path)` — read ring buffer statistics from a shared memory file.

### TX

- `write_to_litex_m2sdr(input_channel; kwargs...)` — start TX streaming. Accepts `SignalChannel{Complex{Int16},N}` or `SignalChannel{Int16,N}`. Returns `(Channel{TxStats}, Channel{StreamWarning})`.

### Common

- `AGCMode` — enum: `AGC_MANUAL`, `AGC_FAST_ATTACK`, `AGC_SLOW_ATTACK`, `AGC_HYBRID`
- `cleanup_shared_memory(path)` — remove a shared memory file.

## Architecture

```
Julia process                    C process (m2sdr_*_stream_shm)
+------------------+             +------------------+
|  SignalChannel   |   shared    |  DMA / AD9361    |
|  read/write loop | <-- mmap --> |  hardware I/O   |
|  (GC-safe)       |   memory    |  (real-time)     |
+------------------+             +------------------+
```

The C streaming processes (`m2sdr_rx_stream_shm`, `m2sdr_tx_stream_shm`) handle real-time DMA transfers with the FPGA. Julia communicates through a lock-free shared memory ring buffer using acquire/release atomic operations, ensuring data integrity without locks or system calls.

## Testing

Tests use mock Julia processes that speak the same shared memory protocol, so no SDR hardware is needed:

```bash
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
```

## License

MIT
