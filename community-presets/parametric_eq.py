import numpy as np
from conjuredsp.params import freq, db, param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "freq_1":  freq(min=50, max=500, default=100),
    "gain_1":  db(-12, 12, default=0),
    "freq_2":  freq(min=200, max=2000, default=500),
    "gain_2":  db(-12, 12, default=0),
    "freq_3":  freq(min=1000, max=8000, default=3000),
    "gain_3":  db(-12, 12, default=0),
    "freq_4":  freq(min=4000, max=20000, default=10000),
    "gain_4":  db(-12, 12, default=0),
}

_bands = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Parametric EQ — 4-band fully parametric equalizer.

    Four peaking EQ bands with adjustable frequency and gain. Each
    band can boost or cut by up to 12 dB. The workhorse of mixing
    and mastering — use for surgical cuts, broad tonal shaping,
    or creative sound design. Fixed Q of 1.5 provides musical
    bandwidth for each band.

    Params:
        freq_1/gain_1: Band 1 — Low (50–500 Hz, +/-12 dB)
        freq_2/gain_2: Band 2 — Low-Mid (200–2000 Hz, +/-12 dB)
        freq_3/gain_3: Band 3 — High-Mid (1–8 kHz, +/-12 dB)
        freq_4/gain_4: Band 4 — High (4–20 kHz, +/-12 dB)
    """
    global _bands

    n_ch = len(inputs)

    if _bands is None:
        _bands = [[Biquad() for _ in range(4)] for _ in range(n_ch)]

    freqs = [params["freq_1"], params["freq_2"], params["freq_3"], params["freq_4"]]
    gains = [params["gain_1"], params["gain_2"], params["gain_3"], params["gain_4"]]

    for ch in range(n_ch):
        for b in range(4):
            coeffs = BiquadCoeffs.peak(freqs[b], 1.5, gains[b], sample_rate)
            _bands[ch][b].set_coeffs(coeffs)

        for i in range(frame_count):
            x = inputs[ch][i]
            for b in range(4):
                x = _bands[ch][b].process_sample(x)
            outputs[ch][i] = x
