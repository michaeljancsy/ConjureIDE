import math
from conjuredsp import freq
from conjuredsp.params import param

PARAMS = {
    "cutoff":    freq(),
    "resonance": param(0.5, 10, unit="Q", default=1),
}

# Mode: "low", "high", "band", "notch"
MODE = "low"

# Persistent state per channel: [ic1eq, ic2eq]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(ctx):
    """
    Resonant State Variable Filter — multi-mode TPT SVF (LP/HP/BP/Notch).

    Topology-preserving transform SVF (Zavalishin). Unconditionally stable
    across the full 20–20000 Hz range at any Q. The filter computes
    low-pass, high-pass, and band-pass simultaneously, and the MODE
    constant selects which output is used.

    Params:
        cutoff:    Cutoff frequency (20–20000 Hz)
        resonance: Resonance Q (0.5–10)
    """
    global _state

    cutoff_hz = min(ctx.params["cutoff"], ctx.sample_rate * 0.49)
    resonance = ctx.params["resonance"]

    g = math.tan(math.pi * cutoff_hz / ctx.sample_rate)
    k = 1.0 / resonance
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2

    n_ch, frame_count = ctx.inputs.shape

    for ch in range(n_ch):
        ic1eq = _state[ch][0] if ch < len(_state) else 0.0
        ic2eq = _state[ch][1] if ch < len(_state) else 0.0

        row_in = ctx.inputs[ch]
        row_out = ctx.outputs[ch]
        for i in range(frame_count):
            x = row_in[i]
            v3 = x - ic2eq
            v1 = a1 * ic1eq + a2 * v3
            v2 = ic2eq + a2 * ic1eq + a3 * v3
            ic1eq = 2.0 * v1 - ic1eq
            ic2eq = 2.0 * v2 - ic2eq

            low = v2
            band = v1
            high = x - k * v1 - v2

            if MODE == "low":
                row_out[i] = low
            elif MODE == "high":
                row_out[i] = high
            elif MODE == "band":
                row_out[i] = band
            else:  # notch
                row_out[i] = low + high

        if ch < len(_state):
            _state[ch][0] = ic1eq
            _state[ch][1] = ic2eq
