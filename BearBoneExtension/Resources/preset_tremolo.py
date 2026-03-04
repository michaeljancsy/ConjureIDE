import numpy as np

# Tremolo parameters
RATE_HZ = 4.0
DEPTH = 0.5  # 0.0 = no effect, 1.0 = full tremolo

# Persistent phase across callbacks
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tremolo — sine-based amplitude modulation.

    Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
    The LFO phase is tracked across callbacks for seamless modulation.
    At DEPTH=0.0 the signal passes through unchanged; at DEPTH=1.0 the signal
    fades fully to silence at the LFO troughs.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _phase

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    lfo = 1.0 - DEPTH * 0.5 * (1.0 + np.sin(2.0 * np.pi * RATE_HZ * t + _phase))

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * lfo

    _phase += 2.0 * np.pi * RATE_HZ * frame_count / sample_rate
    _phase %= 2.0 * np.pi
