# Common types, constants, and helpers shared between RX and TX

# =============================================================================
# AGC Mode enum (used by LiteX M2SDR RX streaming)
# =============================================================================

"""
    AGCMode

Automatic Gain Control mode for the AD9361 RX frontend.

# Values
- `AGC_MANUAL`: Manual gain control (default) - gain is fixed at the specified value
- `AGC_FAST_ATTACK`: Fast attack AGC - quickly adapts to signal level changes
- `AGC_SLOW_ATTACK`: Slow attack AGC - gradually adapts to signal level changes
- `AGC_HYBRID`: Hybrid AGC - combines fast and slow attack characteristics
"""
@enum AGCMode begin
    AGC_MANUAL = 0
    AGC_FAST_ATTACK = 1
    AGC_SLOW_ATTACK = 2
    AGC_HYBRID = 3
end

# Map AGCMode to command-line argument strings
const AGC_MODE_STRINGS = Dict(
    AGC_MANUAL => "manual",
    AGC_FAST_ATTACK => "fast_attack",
    AGC_SLOW_ATTACK => "slow_attack",
    AGC_HYBRID => "hybrid",
)

# Default paths for shared memory
const DEFAULT_SHM_PATH = "/dev/shm/sdr_ringbuffer"
const DEFAULT_TX_SHM_PATH = "/dev/shm/sdr_tx_ringbuffer"

"""
    cleanup_shared_memory(path::String=DEFAULT_SHM_PATH)

Remove the shared memory file.
"""
function cleanup_shared_memory(path::String = DEFAULT_SHM_PATH)
    if isfile(path)
        rm(path)
        @info "Cleaned up shared memory" path = path
    end
end

# Helper to kill process and cleanup shared memory
function kill_and_cleanup(proc::Base.Process, shm_path::String)
    if process_running(proc)
        kill(proc)
    end
    cleanup_shared_memory(shm_path)
end
