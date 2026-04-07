import numpy as np
import math
from conjuredsp.params import param, mix

PARAMS = {
    "density":    param(1, 30, unit="Hz", default=10),
    "grain_size": param(5, 100, unit="ms", default=30),
    "scatter":    param(0, 1, default=0.5),
    "mix":        mix(default=0.5),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

_buffer = None
_write_pos = 0
_grains = []
MAX_BUF = 96000


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Granular Scatter — grain-based audio scattering.

    Captures audio into a buffer and plays back small "grains"
    (chunks) at random positions. The scatter control randomizes
    the playback position within the buffer. At low scatter, grains
    play back close to real-time; at high scatter, grains jump
    around creating a fragmented, pointillist texture. Essential
    for ambient, sound design, and experimental music.

    Params:
        density:    How many grains per second (1–30)
        grain_size: Length of each grain (5–100 ms)
        scatter:    Randomness of grain position (0–1)
        mix:        Wet/dry blend
    """
    global _buffer, _write_pos, _grains

    density = params["density"]
    grain_ms = params["grain_size"]
    scatter = params["scatter"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    grain_samples = int(grain_ms * 0.001 * sample_rate)

    if _buffer is None or len(_buffer) != n_ch:
        _buffer = [np.zeros(MAX_BUF, dtype=np.float32) for _ in range(n_ch)]

    # Write input to circular buffer
    for i in range(frame_count):
        for ch in range(n_ch):
            _buffer[ch][_write_pos] = inputs[ch][i]
        _write_pos = (_write_pos + 1) % MAX_BUF

    # Spawn new grains
    grain_interval = int(sample_rate / density) if density > 0 else sample_rate
    spawn_count = max(1, frame_count // grain_interval)

    for _ in range(spawn_count):
        if _rng() < density * frame_count / sample_rate:
            # Random offset based on scatter
            max_offset = int(scatter * MAX_BUF * 0.5)
            offset = 0 + int(_rng() * (max(1, max_offset) - 0 + 1))
            start = (_write_pos - grain_samples - offset + MAX_BUF) % MAX_BUF
            _grains.append({"start": start, "pos": 0, "len": grain_samples})

    # Mix grains into output
    for ch in range(n_ch):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * (1.0 - wet_mix)

    active_grains = []
    for grain in _grains:
        for i in range(frame_count):
            if grain["pos"] < grain["len"]:
                # Hanning window for smooth grains
                t = grain["pos"] / grain["len"]
                window = 0.5 * (1.0 - math.cos(2.0 * math.pi * t))

                read_idx = (grain["start"] + grain["pos"]) % MAX_BUF
                for ch in range(n_ch):
                    outputs[ch][i] += _buffer[ch][read_idx] * window * wet_mix * 0.3

                grain["pos"] += 1

        if grain["pos"] < grain["len"]:
            active_grains.append(grain)

    _grains = active_grains[-20:]  # limit active grains
