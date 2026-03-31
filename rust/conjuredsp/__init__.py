"""ConjureDSP — utilities for audio effect preset development.

This package provides type definitions, parameter helpers, DSP utilities,
and building blocks for writing ConjureDSP presets.

Quick start::

    from conjuredsp import freq, db, mix, time_ms
    from conjuredsp.dsp import db_to_gain, smooth_coeff
    from conjuredsp.buffers import DelayLine
    from conjuredsp.filters import Biquad, BiquadCoeffs
    from conjuredsp.osc import LFO

    PARAMS = {
        "cutoff": freq(),
        "gain": db(),
        "mix": mix(),
        "attack": time_ms(0.5, 50, default=5),
    }
"""

# Types
from .types import AudioBuffer, ChannelList, ParamDict, ParamSpec, ParamValues

# Parameter helpers
from .params import choice, db, freq, mix, param, pct, ratio, time_ms, toggle

# DSP utilities
from .dsp import (
    crossfade,
    db_to_gain,
    equal_power_crossfade,
    freq_to_period,
    gain_to_db,
    lerp,
    ms_to_samples,
    samples_to_ms,
    smooth_coeff,
    soft_clip,
)

# Building blocks
from .buffers import DelayLine
from .filters import Biquad, BiquadCoeffs
from .osc import LFO

# NAM (Neural Amp Modeler) inference
from .nam import NamModel, load_model

__all__ = [
    # Types
    "AudioBuffer",
    "ChannelList",
    "ParamDict",
    "ParamSpec",
    "ParamValues",
    # Parameter helpers
    "param",
    "choice",
    "freq",
    "db",
    "time_ms",
    "pct",
    "mix",
    "toggle",
    "ratio",
    # DSP utilities
    "db_to_gain",
    "gain_to_db",
    "ms_to_samples",
    "samples_to_ms",
    "freq_to_period",
    "smooth_coeff",
    "crossfade",
    "equal_power_crossfade",
    "soft_clip",
    "lerp",
    # Building blocks
    "DelayLine",
    "Biquad",
    "BiquadCoeffs",
    "LFO",
    # NAM inference
    "NamModel",
    "load_model",
]
