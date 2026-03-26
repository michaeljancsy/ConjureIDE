"""Common DSP utility functions for ConjureDSP presets.

These are stateless helpers for unit conversion, coefficient calculation,
and common audio math. Use these for setup and coefficient computation —
for inner-loop performance, inline the math directly.
"""

import math

import numpy as np

from .types import AudioBuffer


def db_to_gain(db: float) -> float:
    """Convert decibels to linear gain. 0 dB = 1.0."""
    return 10.0 ** (db / 20.0)


def gain_to_db(gain: float) -> float:
    """Convert linear gain to decibels. Clamps to avoid log(0)."""
    return 20.0 * math.log10(max(gain, 1e-30))


def ms_to_samples(ms: float, sample_rate: float) -> int:
    """Convert milliseconds to sample count (rounded to nearest int)."""
    return int(ms * 0.001 * sample_rate + 0.5)


def samples_to_ms(samples: int, sample_rate: float) -> float:
    """Convert sample count to milliseconds."""
    return samples * 1000.0 / sample_rate


def freq_to_period(freq: float, sample_rate: float) -> float:
    """Convert frequency in Hz to period in samples."""
    return sample_rate / freq


def smooth_coeff(time_ms: float, sample_rate: float) -> float:
    """One-pole smoothing coefficient from time constant in ms.

    Returns alpha for: state = alpha * state + (1 - alpha) * target

    Larger time_ms = slower smoothing (alpha closer to 1).
    """
    if time_ms <= 0.0:
        return 0.0
    return math.exp(-1.0 / (time_ms * 0.001 * sample_rate))


def crossfade(
    dry: AudioBuffer,
    wet: AudioBuffer,
    mix: float,
    out: AudioBuffer,
    n: int,
) -> None:
    """Linear crossfade between dry and wet signals.

    Args:
        dry: Dry signal buffer.
        wet: Wet signal buffer.
        mix: 0.0 = fully dry, 1.0 = fully wet.
        out: Output buffer (written in-place).
        n: Number of samples to process.
    """
    np.multiply(dry[:n], 1.0 - mix, out=out[:n])
    np.add(out[:n], wet[:n] * mix, out=out[:n])


def equal_power_crossfade(
    dry: AudioBuffer,
    wet: AudioBuffer,
    mix: float,
    out: AudioBuffer,
    n: int,
) -> None:
    """Equal-power crossfade (constant energy across the mix range).

    Uses sine/cosine curves so energy is preserved at 50% mix.
    """
    angle = mix * math.pi * 0.5
    dry_gain = math.cos(angle)
    wet_gain = math.sin(angle)
    np.multiply(dry[:n], dry_gain, out=out[:n])
    np.add(out[:n], wet[:n] * wet_gain, out=out[:n])


def soft_clip(x: float, drive: float = 1.0) -> float:
    """Soft clipper using tanh saturation.

    Args:
        x: Input sample.
        drive: Pre-gain before saturation (1.0 = no extra drive).
    """
    return math.tanh(x * drive)


def lerp(a: float, b: float, t: float) -> float:
    """Linear interpolation between a and b. t=0 returns a, t=1 returns b."""
    return a + (b - a) * t
