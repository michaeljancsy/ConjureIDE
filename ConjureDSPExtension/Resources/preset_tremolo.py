import numpy as np
from conjuredsp.params import param
from conjuredsp.osc import LFO

PARAMS = {
    "rate":  param(0.5, 20, unit="Hz", default=5),
    "depth": param(0, 1, default=0.5),
}

# Persistent LFO
_lfo = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tremolo — sine-based amplitude modulation.

    Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
    The LFO phase is tracked across callbacks for seamless modulation.

    Params:
        rate:  LFO rate (0.5–20 Hz)
        depth: Tremolo depth (0.0 = no effect, 1.0 = full tremolo)
    """
    global _lfo

    rate_hz = params["rate"]
    depth = params["depth"]

    if _lfo is None:
        _lfo = LFO(sample_rate, freq=rate_hz)
    _lfo.set_freq(rate_hz)

    # Generate sine LFO values for the whole buffer
    lfo = _lfo.tick_n(frame_count)
    # Convert bipolar [-1, 1] to unipolar amplitude modulation
    mod = 1.0 - depth * 0.5 * (1.0 + lfo)

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], mod, out=outputs[ch][:frame_count])
