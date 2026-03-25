import numpy as np

PARAMS = {
    "rate":  {"min": 0.5, "max": 20.0, "unit": "Hz", "default": 5.0},
    "depth": {"min": 0.0, "max": 1.0,  "unit": "",   "default": 0.5},
}

# Persistent phase across callbacks
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tremolo — sine-based amplitude modulation.

    Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
    The LFO phase is tracked across callbacks for seamless modulation.

    Params:
        rate:  LFO rate (0.5–20 Hz)
        depth: Tremolo depth (0.0 = no effect, 1.0 = full tremolo)
    """
    global _phase

    rate_hz = params["rate"]
    depth = params["depth"]

    t = np.arange(frame_count, dtype=np.float32) / sample_rate
    lfo = 1.0 - depth * 0.5 * (1.0 + np.sin(2.0 * np.pi * rate_hz * t + _phase))

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], lfo, out=outputs[ch][:frame_count])

    _phase += 2.0 * np.pi * rate_hz * frame_count / sample_rate
    _phase %= 2.0 * np.pi
