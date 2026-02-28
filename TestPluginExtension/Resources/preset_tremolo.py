import numpy as np

# Tremolo parameters
RATE_HZ = 4.0
DEPTH = 0.5  # 0.0 = no effect, 1.0 = full tremolo

# Persistent phase across callbacks
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate):
    """Tremolo — sine-based amplitude modulation."""
    global _phase

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    lfo = 1.0 - DEPTH * 0.5 * (1.0 + np.sin(2.0 * np.pi * RATE_HZ * t + _phase))

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * lfo

    _phase += 2.0 * np.pi * RATE_HZ * frame_count / sample_rate
    _phase %= 2.0 * np.pi
