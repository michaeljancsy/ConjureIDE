import numpy as np

# White noise parameters
AMPLITUDE = 0.3  # Output level (0.0–1.0)

# LCG random state (matches Rust implementation for deterministic output)
_rng_state = np.uint32(12345)


def _next_f32():
    """Linear congruential generator producing values in [-1, 1]."""
    global _rng_state
    _rng_state = np.uint32(np.uint32(_rng_state) * np.uint32(1664525) + np.uint32(1013904223))
    return float(_rng_state) / 4294967296.0 * 2.0 - 1.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    White Noise Generator — generates uniform white noise.

    Ignores the input signal and fills the output with pseudo-random
    noise using a linear congruential generator. The LCG state persists
    across callbacks for a continuous noise stream. Both Python and Rust
    implementations use the same LCG constants for identical output.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    for i in range(frame_count):
        sample = _next_f32() * AMPLITUDE
        for ch in range(len(outputs)):
            outputs[ch][i] = sample
