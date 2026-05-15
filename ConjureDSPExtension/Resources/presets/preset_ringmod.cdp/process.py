import numpy as np
from conjuredsp import freq
from conjuredsp.osc import LFO

PARAMS = {
    "frequency": freq(20, 20000, default=440),
}

# Persistent LFO
_lfo = None


def process(ctx):
    """
    Ring Modulator — multiplies the signal by a sine-wave carrier.

    Multiplies the input signal by a sine wave at the carrier frequency.
    This creates sum and difference frequencies, producing metallic,
    bell-like, or robotic timbres. Unlike tremolo (which modulates
    amplitude around a bias), ring modulation has no DC offset, so the
    carrier frequency components are always present in the output.

    Controls:
        frequency: Carrier frequency (20–20000 Hz)
    """
    global _lfo

    carrier_hz = ctx.params["frequency"]

    if _lfo is None:
        _lfo = LFO(ctx.sample_rate, freq=carrier_hz)
    _lfo.set_freq(carrier_hz)

    carrier = _lfo.tick_n(ctx.frame_count)

    n_ch = ctx.inputs.shape[0]
    for ch in range(n_ch):
        np.multiply(ctx.inputs[ch], carrier, out=ctx.outputs[ch])
