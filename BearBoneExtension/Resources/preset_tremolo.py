import numpy as np

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Rate", 1: "Depth"}

# Persistent phase across callbacks
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tremolo — sine-based amplitude modulation.

    Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
    The LFO phase is tracked across callbacks for seamless modulation.

    Params:
        0 (Rate):  LFO rate — 0.0 = 0.5 Hz, 1.0 = 20 Hz
        1 (Depth): Tremolo depth — 0.0 = no effect, 1.0 = full tremolo
    """
    global _phase

    rate_hz = 0.5 + params[0] * 19.5   # 0.5 Hz to 20 Hz
    depth = params[1]                    # 0.0 to 1.0

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    lfo = 1.0 - depth * 0.5 * (1.0 + np.sin(2.0 * np.pi * rate_hz * t + _phase))

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * lfo

    _phase += 2.0 * np.pi * rate_hz * frame_count / sample_rate
    _phase %= 2.0 * np.pi
