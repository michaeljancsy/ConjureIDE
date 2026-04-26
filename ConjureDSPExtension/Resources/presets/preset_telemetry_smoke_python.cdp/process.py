# Telemetry smoke test (Python twin) — proves the DSP→UI scalar
# telemetry channel works for the Python backend.
#
# Mirrors preset_telemetry_smoke.cdp (Rust): scales the input by
# `drive`, soft-clips, runs a per-block peak detector + slow envelope
# follower over the input, publishes:
#   peak_db     — instantaneous block peak in dB.
#   envelope_db — slow-attack/release envelope in dB. Internal DSP
#                 state that the existing audio.onFrame fields can't
#                 reach — the whole point of the telemetry channel.
#
# The 7-arg process() signature is what triggers the kernel's
# telemetry-aware dispatch path. Authors who want telemetry but not
# transport accept transport as an unused arg, same way the existing
# levels work.

import numpy as np

PARAMS = {
    "drive": {"min": 1.0, "max": 10.0, "default": 1.0, "unit": "x"},
}

TELEMETRY = {
    "peak_db":     {"unit": "dB"},
    "envelope_db": {"unit": "dB"},
}

# Persistent envelope follower state.
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params, transport, telemetry):
    global _envelope

    drive = max(1.0, params["drive"])

    # 50ms attack, 200ms release smoothing.
    attack_coeff = float(np.exp(-1.0 / (0.050 * sample_rate)))
    release_coeff = float(np.exp(-1.0 / (0.200 * sample_rate)))

    # Block peak across all channels — drives both the envelope follower
    # and the published PEAK_DB telemetry.
    block_peak = 0.0
    for ch_in in inputs:
        peak_ch = float(np.max(np.abs(ch_in[:frame_count]))) if frame_count > 0 else 0.0
        if peak_ch > block_peak:
            block_peak = peak_ch

    # Per-sample envelope follower — uses the absolute value of the
    # last channel for the per-sample feedback (good enough for a
    # smoke test; production code would link across channels properly).
    last_ch = inputs[-1]
    env = _envelope
    for i in range(frame_count):
        target = abs(float(last_ch[i])) * drive
        coeff = attack_coeff if target > env else release_coeff
        env = target + coeff * (env - target)
    _envelope = env

    # Soft-clip drive applied to every output channel. np.tanh is
    # vectorised and cheap.
    for ch_in, ch_out in zip(inputs, outputs):
        ch_out[:frame_count] = np.tanh(ch_in[:frame_count] * drive)

    # dB conversion. -120 floor keeps the UI's bar from log(0)-ing.
    def lin_to_db(x):
        return -120.0 if x <= 1e-6 else float(20.0 * np.log10(x))

    telemetry["peak_db"] = lin_to_db(block_peak)
    telemetry["envelope_db"] = lin_to_db(env)
