#!/usr/bin/env python3
"""Generate built-in test signals for the ConjureDSP host app.

Outputs four mono, 48 kHz, 32-bit float WAVs into ConjureDSP/Common/Audio/:
  - a440_sine.wav             (440 Hz pure sine)
  - white_noise.wav           (gaussian)
  - a55_sawtooth_series.wav   (harmonics of A1 = 55 Hz, n = 1..363, random phase)
  - a_octave_stack.wav        (ten A-note octaves A0..A9, random phase)

All four are 10 s long, peak-normalized to -1 dBFS (~0.891 linear), and seeded
with numpy.random.default_rng(0) for any randomness.

Format note: 32-bit float. scipy.io.wavfile.write emits IEEE_FLOAT when given a
float32 array; AVAudioFile reads it without conversion. scipy.io.wavfile cannot
write 24-bit PCM (no int24 path), and the prior 24-bit a440_60s_-1dbfs.wav is
being deleted, so there is no 24-bit convention to match.

Reproducibility: same numpy version on the same machine produces identical
bytes. Cross-version / cross-machine determinism is best-effort only (PCG64
stream stability isn't formally guaranteed, and float32 summation interacts
with BLAS). Committed bytes were produced with numpy 2.4.4.

Invocation:
    cd <repo root>
    # Prerequisite: rust/python-dist/ must exist. In the main repo, run
    # `rust/setup-python.sh` once. In a Claude Code worktree, run
    # `xcodebuild build` once (auto-symlinks from main) or
    # `ln -s <main-repo>/rust/python-dist rust/python-dist`.
    rust/python-dist/bin/python3 scripts/generate-test-signals.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from scipy.io import wavfile

SAMPLE_RATE = 48_000
DURATION_S = 10.0
PEAK = 10.0 ** (-1.0 / 20.0)  # -1 dBFS ~= 0.891
SEED = 0


def _peak_normalize(x: np.ndarray) -> np.ndarray:
    peak = float(np.max(np.abs(x)))
    if peak == 0.0:
        return x.astype(np.float32, copy=False)
    return (x * (PEAK / peak)).astype(np.float32, copy=False)


def _time_axis(n: int) -> np.ndarray:
    return np.arange(n, dtype=np.float64) / SAMPLE_RATE


def a440_sine(n: int) -> np.ndarray:
    t = _time_axis(n)
    return (PEAK * np.sin(2.0 * np.pi * 440.0 * t)).astype(np.float32)


def white_noise(n: int, rng: np.random.Generator) -> np.ndarray:
    return _peak_normalize(rng.standard_normal(n))


def a55_sawtooth_series(n: int, rng: np.random.Generator) -> np.ndarray:
    t = _time_axis(n)
    accum = np.zeros(n, dtype=np.float64)
    fundamental = 55.0
    # Harmonics of A1 up to 20 kHz (n=363 -> 19_965 Hz). Stops before Nyquist
    # to avoid content that aliases on downsampled monitoring chains.
    k = 1
    while True:
        f = fundamental * k
        if f > 20_000.0:
            break
        phase = rng.uniform(0.0, 2.0 * np.pi)
        accum += np.sin(2.0 * np.pi * f * t + phase)
        k += 1
    return _peak_normalize(accum)


def a_octave_stack(n: int, rng: np.random.Generator) -> np.ndarray:
    t = _time_axis(n)
    accum = np.zeros(n, dtype=np.float64)
    for f in (27.5, 55.0, 110.0, 220.0, 440.0, 880.0, 1760.0, 3520.0, 7040.0, 14080.0):
        phase = rng.uniform(0.0, 2.0 * np.pi)
        accum += np.sin(2.0 * np.pi * f * t + phase)
    return _peak_normalize(accum)


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    out_dir = repo_root / "ConjureDSP" / "Common" / "Audio"
    out_dir.mkdir(parents=True, exist_ok=True)

    n = int(SAMPLE_RATE * DURATION_S)
    rng = np.random.default_rng(SEED)

    wavfile.write(out_dir / "a440_sine.wav", SAMPLE_RATE, a440_sine(n))
    wavfile.write(out_dir / "white_noise.wav", SAMPLE_RATE, white_noise(n, rng))
    wavfile.write(out_dir / "a55_sawtooth_series.wav", SAMPLE_RATE, a55_sawtooth_series(n, rng))
    wavfile.write(out_dir / "a_octave_stack.wav", SAMPLE_RATE, a_octave_stack(n, rng))

    for name in ("a440_sine.wav", "white_noise.wav", "a55_sawtooth_series.wav", "a_octave_stack.wav"):
        path = out_dir / name
        print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
