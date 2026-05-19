import numpy as np
import math
from conjuredsp.params import param, choice, toggle

PARAMS = {
    "sync":     toggle(default=1),
    "rate":     param(1, 20, unit="Hz", default=4),
    "division": choice("1/4", "1/8", "1/16", "1/2", default="1/4"),
    "depth":    param(0, 1, default=0.8),
    "curve":    param(0.1, 3, default=1),
}

DIVISIONS = [1.0, 0.5, 0.25, 2.0]
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params, transport):
    """
    Sidechain Pump — EDM ducking/pumping effect.

    Creates the rhythmic "pumping" volume effect used in electronic
    dance music without needing an actual sidechain input. Simulates
    a kick drum ducking the signal via an internal LFO. The curve
    control shapes the pump from smooth breathing to sharp ducks.
    The defining sound of French house, EDM drops, and modern
    pop production. Think Daft Punk "One More Time."

    Params:
        sync:     BPM sync on/off
        rate:     Free-running pump rate (1–20 Hz)
        division: BPM-synced note division
        depth:    Pump depth (0 = no effect, 1 = full silence)
        curve:    Pump shape (0.1 = slow swell, 3 = sharp duck)
    """
    global _phase

    depth = params["depth"]
    curve = params["curve"]
    tempo = transport["tempo"]

    # Determine rate
    if params["sync"] > 0.5 and tempo > 0:
        div_idx = int(round(params["division"]))
        div_idx = max(0, min(div_idx, len(DIVISIONS) - 1))
        beats = DIVISIONS[div_idx]
        rate_hz = tempo / 60.0 / beats
    else:
        rate_hz = params["rate"]

    for i in range(frame_count):
        # Pump envelope: sharp duck at phase=0, smooth recovery
        # Using exponential curve for natural pump feel
        pump = _phase ** curve

        # Volume = 1 at phase=1 (recovered), (1-depth) at phase=0 (ducked)
        vol = 1.0 - depth * (1.0 - pump)

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * vol

        _phase = (_phase + rate_hz / sample_rate) % 1.0
