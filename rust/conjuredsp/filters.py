"""Biquad filter coefficient calculation and stateful filtering.

Implements the Audio EQ Cookbook formulas (Robert Bristow-Johnson).
Coefficients are computed once when parameters change; the filter
state persists across process() callbacks via module-level instances.
"""

import math


class BiquadCoeffs:
    """Biquad filter coefficients (b0, b1, b2, a1, a2).

    Normalized so a0 = 1. Use the static methods to compute coefficients
    for standard filter types, then pass to a Biquad instance.
    """

    __slots__ = ("b0", "b1", "b2", "a1", "a2")

    def __init__(self, b0: float, b1: float, b2: float, a1: float, a2: float) -> None:
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2

    @staticmethod
    def lowpass(freq: float, q: float, sample_rate: float) -> "BiquadCoeffs":
        """Low-pass filter. Passes frequencies below cutoff."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0=(1.0 - cos_w0) / 2.0 / a0,
            b1=(1.0 - cos_w0) / a0,
            b2=(1.0 - cos_w0) / 2.0 / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha) / a0,
        )

    @staticmethod
    def highpass(freq: float, q: float, sample_rate: float) -> "BiquadCoeffs":
        """High-pass filter. Passes frequencies above cutoff."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0=(1.0 + cos_w0) / 2.0 / a0,
            b1=-(1.0 + cos_w0) / a0,
            b2=(1.0 + cos_w0) / 2.0 / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha) / a0,
        )

    @staticmethod
    def bandpass(freq: float, q: float, sample_rate: float) -> "BiquadCoeffs":
        """Band-pass filter (constant skirt gain). Passes a frequency band."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0=alpha / a0,
            b1=0.0,
            b2=-alpha / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha) / a0,
        )

    @staticmethod
    def notch(freq: float, q: float, sample_rate: float) -> "BiquadCoeffs":
        """Notch (band-reject) filter. Removes a frequency band."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0=1.0 / a0,
            b1=-2.0 * cos_w0 / a0,
            b2=1.0 / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha) / a0,
        )

    @staticmethod
    def peak(
        freq: float, q: float, gain_db: float, sample_rate: float
    ) -> "BiquadCoeffs":
        """Peaking EQ filter. Boosts or cuts at the center frequency."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        A = 10.0 ** (gain_db / 40.0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha / A
        return BiquadCoeffs(
            b0=(1.0 + alpha * A) / a0,
            b1=-2.0 * cos_w0 / a0,
            b2=(1.0 - alpha * A) / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha / A) / a0,
        )

    @staticmethod
    def lowshelf(
        freq: float, q: float, gain_db: float, sample_rate: float
    ) -> "BiquadCoeffs":
        """Low shelf filter. Boosts or cuts frequencies below the cutoff."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        sin_w0 = math.sin(w0)
        A = 10.0 ** (gain_db / 40.0)
        alpha = sin_w0 / (2.0 * q)
        two_sqrt_A_alpha = 2.0 * math.sqrt(A) * alpha
        a0 = (A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_A_alpha
        return BiquadCoeffs(
            b0=(A * ((A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_A_alpha)) / a0,
            b1=(2.0 * A * ((A - 1.0) - (A + 1.0) * cos_w0)) / a0,
            b2=(A * ((A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_A_alpha)) / a0,
            a1=(-2.0 * ((A - 1.0) + (A + 1.0) * cos_w0)) / a0,
            a2=((A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_A_alpha) / a0,
        )

    @staticmethod
    def highshelf(
        freq: float, q: float, gain_db: float, sample_rate: float
    ) -> "BiquadCoeffs":
        """High shelf filter. Boosts or cuts frequencies above the cutoff."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        sin_w0 = math.sin(w0)
        A = 10.0 ** (gain_db / 40.0)
        alpha = sin_w0 / (2.0 * q)
        two_sqrt_A_alpha = 2.0 * math.sqrt(A) * alpha
        a0 = (A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_A_alpha
        return BiquadCoeffs(
            b0=(A * ((A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_A_alpha)) / a0,
            b1=(-2.0 * A * ((A - 1.0) + (A + 1.0) * cos_w0)) / a0,
            b2=(A * ((A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_A_alpha)) / a0,
            a1=(2.0 * ((A - 1.0) - (A + 1.0) * cos_w0)) / a0,
            a2=((A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_A_alpha) / a0,
        )

    @staticmethod
    def allpass(freq: float, q: float, sample_rate: float) -> "BiquadCoeffs":
        """All-pass filter. Passes all frequencies, shifts phase."""
        w0 = 2.0 * math.pi * freq / sample_rate
        cos_w0 = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0=(1.0 - alpha) / a0,
            b1=-2.0 * cos_w0 / a0,
            b2=(1.0 + alpha) / a0,
            a1=-2.0 * cos_w0 / a0,
            a2=(1.0 - alpha) / a0,
        )


class Biquad:
    """Stateful biquad filter using direct form II transposed.

    Maintains filter state across process() callbacks. Create one per channel.

    Example::

        from conjuredsp.filters import Biquad, BiquadCoeffs

        _filters = None

        def process(inputs, outputs, frame_count, sample_rate, params):
            global _filters
            if _filters is None:
                _filters = [Biquad() for _ in range(len(inputs))]

            coeffs = BiquadCoeffs.lowpass(params["cutoff"], params["resonance"], sample_rate)
            for ch in range(len(inputs)):
                _filters[ch].set_coeffs(coeffs)
                for i in range(frame_count):
                    outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i])
    """

    __slots__ = ("b0", "b1", "b2", "a1", "a2", "z1", "z2")

    def __init__(self, coeffs: BiquadCoeffs | None = None) -> None:
        if coeffs is not None:
            self.b0 = coeffs.b0
            self.b1 = coeffs.b1
            self.b2 = coeffs.b2
            self.a1 = coeffs.a1
            self.a2 = coeffs.a2
        else:
            # Passthrough by default
            self.b0 = 1.0
            self.b1 = 0.0
            self.b2 = 0.0
            self.a1 = 0.0
            self.a2 = 0.0
        self.z1 = 0.0
        self.z2 = 0.0

    def set_coeffs(self, coeffs: BiquadCoeffs) -> None:
        """Update filter coefficients (does not reset state)."""
        self.b0 = coeffs.b0
        self.b1 = coeffs.b1
        self.b2 = coeffs.b2
        self.a1 = coeffs.a1
        self.a2 = coeffs.a2

    def process_sample(self, x: float) -> float:
        """Process a single sample through the filter.

        Args:
            x: Input sample.

        Returns:
            Filtered output sample.
        """
        y = self.b0 * x + self.z1
        self.z1 = self.b1 * x - self.a1 * y + self.z2
        self.z2 = self.b2 * x - self.a2 * y
        return y

    def reset(self) -> None:
        """Reset filter state to zero (silence internal memory)."""
        self.z1 = 0.0
        self.z2 = 0.0
