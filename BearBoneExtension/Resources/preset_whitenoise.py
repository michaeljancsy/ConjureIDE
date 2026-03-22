import numpy as np

# Parameters:
LEVEL = 0

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

    Params:
        0 (Level): Output level — 0.0 = silence, 1.0 = full level
    """
    amplitude = params[LEVEL]  # 0 to 1

    for i in range(frame_count):
        sample = _next_f32() * amplitude
        for ch in range(len(outputs)):
            outputs[ch][i] = sample
