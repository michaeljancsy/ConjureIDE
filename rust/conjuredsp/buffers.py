"""Circular buffer and delay line for ConjureDSP presets.

Numpy-backed for efficient memory use and compatibility with the
audio buffer types used throughout ConjureDSP.
"""

import numpy as np


class DelayLine:
    """Pre-allocated circular buffer for delay effects.

    Backed by a numpy float32 array. Supports fractional-sample reads
    via linear or cubic interpolation.

    Example usage in a delay effect::

        _delays = None

        def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
            global _delays
            if _delays is None:
                max_samples = int(0.5 * sample_rate)  # 500ms max
                _delays = [DelayLine(max_samples) for _ in range(len(inputs))]

            delay_samples = params["time"] * 0.001 * sample_rate
            feedback = params["feedback"]
            mix = params["mix"]

            for ch in range(len(inputs)):
                dl = _delays[ch]
                for i in range(frame_count):
                    delayed = dl.read(delay_samples)
                    dl.write(inputs[ch][i] + delayed * feedback)
                    outputs[ch][i] = inputs[ch][i] * (1 - mix) + delayed * mix
    """

    __slots__ = ("_buf", "_size", "_write_pos")

    def __init__(self, max_samples: int) -> None:
        """Allocate a delay line with the given maximum length in samples."""
        self._buf = np.zeros(max_samples, dtype=np.float32)
        self._size = max_samples
        self._write_pos = 0

    @property
    def max_samples(self) -> int:
        """Maximum delay length in samples."""
        return self._size

    def write(self, sample: float) -> None:
        """Write a sample and advance the write head."""
        self._buf[self._write_pos] = sample
        self._write_pos = (self._write_pos + 1) % self._size

    def read(self, delay_samples: float) -> float:
        """Read from the delay line with linear interpolation.

        Args:
            delay_samples: Delay in samples (can be fractional).

        Returns:
            Interpolated sample value.
        """
        read_pos = self._write_pos - delay_samples
        if read_pos < 0.0:
            read_pos += self._size
        idx = int(read_pos)
        frac = read_pos - idx
        idx0 = idx % self._size
        idx1 = (idx + 1) % self._size
        return float(self._buf[idx0] * (1.0 - frac) + self._buf[idx1] * frac)

    def read_cubic(self, delay_samples: float) -> float:
        """Read with cubic (Hermite) interpolation.

        Better quality than linear for pitch shifting and modulated delays.
        Uses 4-point Hermite interpolation.

        Args:
            delay_samples: Delay in samples (can be fractional).

        Returns:
            Interpolated sample value.
        """
        read_pos = self._write_pos - delay_samples
        if read_pos < 0.0:
            read_pos += self._size
        idx = int(read_pos)
        frac = read_pos - idx

        # Four sample points for cubic interpolation
        s = self._size
        buf = self._buf
        y0 = float(buf[(idx - 1) % s])
        y1 = float(buf[idx % s])
        y2 = float(buf[(idx + 1) % s])
        y3 = float(buf[(idx + 2) % s])

        # Hermite interpolation
        c0 = y1
        c1 = 0.5 * (y2 - y0)
        c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return c0 + frac * (c1 + frac * (c2 + frac * c3))

    def tap(self, delay_samples: int) -> float:
        """Read at an integer delay (no interpolation).

        Args:
            delay_samples: Delay in whole samples.

        Returns:
            Sample value at the given delay.
        """
        idx = (self._write_pos - delay_samples) % self._size
        return float(self._buf[idx])

    def clear(self) -> None:
        """Zero the entire buffer and reset write position."""
        self._buf.fill(0.0)
        self._write_pos = 0
