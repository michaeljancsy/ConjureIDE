import numpy as np
from conjuredsp.params import db, freq
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "air":       db(0, 12, default=6),
    "frequency": freq(min=6000, max=16000, default=10000),
    "presence":  db(-6, 6, default=2),
}

_hs = None
_peak = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vocal Air — high-frequency presence and "air" boost.

    Adds the elusive "air" quality to vocals — that breathy,
    open, expensive-sounding top end that separates professional
    recordings from amateur ones. A high shelf boosts the extreme
    highs while a presence peak adds clarity in the 3-5 kHz range.
    The trick used on virtually every pop vocal, podcast, and
    voiceover recording.

    Params:
        air:       Extreme high-frequency boost (0–12 dB)
        frequency: Air band frequency (6–16 kHz)
        presence:  Mid-presence boost/cut (-6 to +6 dB)
    """
    global _hs, _peak

    from conjuredsp.dsp import db_to_gain

    air_db = params["air"]
    air_freq = params["frequency"]
    presence_db = params["presence"]

    n_ch = len(inputs)

    if _hs is None:
        _hs = [Biquad() for _ in range(n_ch)]
        _peak = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _hs[ch].set_coeffs(BiquadCoeffs.highshelf(air_freq, 0.7, air_db, sample_rate))
        _peak[ch].set_coeffs(BiquadCoeffs.peak(4000.0, 1.5, presence_db, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            x = _hs[ch].process_sample(x)
            x = _peak[ch].process_sample(x)
            outputs[ch][i] = x
