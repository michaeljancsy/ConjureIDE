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
# Telemetry flows through ctx.telemetry — the Python backend always
# exposes it via the single-ctx process() API, so authors who want
# telemetry but not transport just ignore ctx.transport.

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


def process(ctx):
    global _envelope

    drive = max(1.0, ctx.params["drive"])

    n_ch, frame_count = ctx.inputs.shape

    # 50ms attack, 200ms release smoothing.
    attack_coeff = float(np.exp(-1.0 / (0.050 * ctx.sample_rate)))
    release_coeff = float(np.exp(-1.0 / (0.200 * ctx.sample_rate)))

    # Block peak across all channels — drives both the envelope follower
    # and the published PEAK_DB telemetry.
    block_peak = 0.0
    for ch in range(n_ch):
        peak_ch = float(np.max(np.abs(ctx.inputs[ch]))) if frame_count > 0 else 0.0
        if peak_ch > block_peak:
            block_peak = peak_ch

    # Per-sample envelope follower — uses the absolute value of the
    # last channel for the per-sample feedback (good enough for a
    # smoke test; production code would link across channels properly).
    last_ch = ctx.inputs[n_ch - 1]
    env = _envelope
    for i in range(frame_count):
        target = abs(float(last_ch[i])) * drive
        coeff = attack_coeff if target > env else release_coeff
        env = target + coeff * (env - target)
    _envelope = env

    # Soft-clip drive applied to every output channel. np.tanh is
    # vectorised and cheap.
    for ch in range(n_ch):
        ctx.outputs[ch] = np.tanh(ctx.inputs[ch] * drive)

    # dB conversion. -120 floor keeps the UI's bar from log(0)-ing.
    def lin_to_db(x):
        return -120.0 if x <= 1e-6 else float(20.0 * np.log10(x))

    ctx.telemetry["peak_db"] = lin_to_db(block_peak)
    ctx.telemetry["envelope_db"] = lin_to_db(env)
