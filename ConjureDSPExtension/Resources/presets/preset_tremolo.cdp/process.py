import numpy as np
from conjuredsp.params import param, toggle, choice
from conjuredsp.osc import LFO

PARAMS = {
    "sync":     toggle(),
    "rate":     param(0.5, 20, unit="Hz", default=5),
    "division": choice("1/1", "1/2", "1/4", "1/8", "1/16", "1/4T", "1/8T", default="1/4"),
    "depth":    param(0, 1, default=0.5),
}

# Division mapping: 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
# Values are in beats (quarter notes)
DIVISIONS = [4.0, 2.0, 1.0, 0.5, 0.25, 2.0 / 3.0, 1.0 / 3.0]

# Persistent LFO
_lfo = None


def process(ctx):
    """
    Tremolo — sine-based amplitude modulation.

    Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
    Supports free-running Hz rate or BPM-synced note divisions.

    Params:
        sync:     0 = free Hz, 1 = BPM sync
        rate:     LFO rate in free mode (0.5–20 Hz)
        division: Note division in BPM mode (0=1/1 .. 6=1/8T)
        depth:    Tremolo depth (0.0 = no effect, 1.0 = full tremolo)
    """
    global _lfo

    depth = ctx.params["depth"]
    tempo = ctx.transport.bpm

    # Determine LFO rate
    if ctx.params["sync"] > 0.5 and tempo > 0:
        div_idx = int(round(ctx.params["division"]))
        div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
        beats = DIVISIONS[div_idx]
        rate_hz = tempo / 60.0 / beats
    else:
        rate_hz = ctx.params["rate"]

    if _lfo is None:
        _lfo = LFO(ctx.sample_rate, freq=rate_hz)
    _lfo.set_freq(rate_hz)

    # Generate sine LFO values for the whole buffer
    lfo = _lfo.tick_n(ctx.frame_count)
    # Convert bipolar [-1, 1] to unipolar amplitude modulation
    mod = 1.0 - depth * 0.5 * (1.0 + lfo)

    for ch in range(len(ctx.inputs)):
        np.multiply(ctx.inputs[ch][:ctx.frame_count], mod, out=ctx.outputs[ch][:ctx.frame_count])
