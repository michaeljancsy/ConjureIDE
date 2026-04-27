import numpy as np
from conjuredsp import freq
from conjuredsp.osc import LFO

PARAMS = {
    "frequency": freq(20, 20000, default=440),
}

# Persistent LFO
_lfo = None


def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
    """
    Ring Modulator — multiplies the signal by a sine-wave carrier.

    Multiplies the input signal by a sine wave at the carrier frequency.
    This creates sum and difference frequencies, producing metallic,
    bell-like, or robotic timbres. Unlike tremolo (which modulates
    amplitude around a bias), ring modulation has no DC offset, so the
    carrier frequency components are always present in the output.

    Params:
        frequency: Carrier frequency (20–20000 Hz)
    """
    global _lfo

    carrier_hz = params["frequency"]

    if _lfo is None:
        _lfo = LFO(sample_rate, freq=carrier_hz)
    _lfo.set_freq(carrier_hz)

    carrier = _lfo.tick_n(frame_count)

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], carrier, out=outputs[ch][:frame_count])
