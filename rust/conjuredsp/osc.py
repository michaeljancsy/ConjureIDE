"""LFO and oscillator utilities for ConjureDSP presets.

Provides stateful oscillators and stateless waveform functions.
"""

import math

import numpy as np


class LFO:
    """Low-frequency oscillator with multiple waveforms.

    Maintains phase across process() callbacks. Create at module level
    and use in the process function.

    Example::

        from conjuredsp.osc import LFO

        _lfo = None

        def process(ctx):
            global _lfo
            if _lfo is None:
                _lfo = LFO(ctx.sample_rate)
            _lfo.set_freq(ctx.params["rate"])

            # Frames-outer: tick() advances phase once per sample so every
            # channel sees the same mod value at the same sample i.
            n_ch, frame_count = ctx.inputs.shape
            for i in range(frame_count):
                mod = _lfo.tick()
                ctx.outputs[:, i] = ctx.inputs[:, i] * (0.5 + 0.5 * mod)
    """

    __slots__ = ("_sample_rate", "_freq", "_phase", "_waveform", "value")

    def __init__(
        self,
        sample_rate: float,
        freq: float = 1.0,
        waveform: str = "sine",
    ) -> None:
        """Create an LFO.

        Args:
            sample_rate: Audio sample rate in Hz.
            freq: Oscillation frequency in Hz.
            waveform: One of "sine", "triangle", "saw", "square".
        """
        self._sample_rate = sample_rate
        self._freq = freq
        self._phase = 0.0
        self._waveform = waveform
        self.value = 0.0

    def set_freq(self, freq: float) -> None:
        """Update the oscillation frequency."""
        self._freq = freq

    def set_waveform(self, waveform: str) -> None:
        """Change the waveform type."""
        self._waveform = waveform

    def tick(self) -> float:
        """Advance by one sample and return the current value.

        Returns:
            Waveform value in [-1, 1].
        """
        p = self._phase
        if self._waveform == "sine":
            self.value = math.sin(2.0 * math.pi * p)
        elif self._waveform == "triangle":
            self.value = triangle(p)
        elif self._waveform == "saw":
            self.value = saw(p)
        elif self._waveform == "square":
            self.value = 1.0 if p < 0.5 else -1.0
        else:
            self.value = math.sin(2.0 * math.pi * p)

        self._phase = (p + self._freq / self._sample_rate) % 1.0
        return self.value

    def tick_n(self, n: int) -> np.ndarray:
        """Advance by n samples and return all values as a numpy array.

        More efficient than calling tick() in a loop for vectorized effects.

        Args:
            n: Number of samples to generate.

        Returns:
            numpy float32 array of shape (n,) with values in [-1, 1].
        """
        phases = (self._phase + np.arange(n, dtype=np.float64) * self._freq / self._sample_rate) % 1.0

        if self._waveform == "sine":
            result = np.sin(2.0 * np.pi * phases).astype(np.float32)
        elif self._waveform == "triangle":
            result = (4.0 * np.abs(phases - 0.5) - 1.0).astype(np.float32)
        elif self._waveform == "saw":
            result = (2.0 * phases - 1.0).astype(np.float32)
        elif self._waveform == "square":
            result = np.where(phases < 0.5, 1.0, -1.0).astype(np.float32)
        else:
            result = np.sin(2.0 * np.pi * phases).astype(np.float32)

        self._phase = (self._phase + n * self._freq / self._sample_rate) % 1.0
        self.value = float(result[-1]) if n > 0 else self.value
        return result

    def reset(self) -> None:
        """Reset phase to zero."""
        self._phase = 0.0
        self.value = 0.0


def sine(phase: float) -> float:
    """Compute sin(2*pi*phase). Phase in [0, 1), output in [-1, 1]."""
    return math.sin(2.0 * math.pi * phase)


def triangle(phase: float) -> float:
    """Triangle wave from phase [0, 1). Output in [-1, 1]."""
    return 4.0 * abs(phase - 0.5) - 1.0


def saw(phase: float) -> float:
    """Sawtooth wave from phase [0, 1). Output in [-1, 1]."""
    return 2.0 * phase - 1.0


def advance_phase(phase: float, freq: float, sample_rate: float) -> float:
    """Advance phase by one sample, wrapping at 1.0.

    Args:
        phase: Current phase in [0, 1).
        freq: Frequency in Hz.
        sample_rate: Sample rate in Hz.

    Returns:
        New phase in [0, 1).
    """
    return (phase + freq / sample_rate) % 1.0
