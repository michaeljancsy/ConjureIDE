import numpy as np

PARAMS = {
    "threshold": {"min": -40.0, "max": -3.0,  "unit": "dB", "default": -20.0},
    "ratio":     {"min": 2.0,   "max": 20.0,  "unit": ":1", "default": 4.0},
    "attack":    {"min": 0.5,   "max": 50.0,  "unit": "ms", "default": 5.0},
    "release":   {"min": 10.0,  "max": 500.0, "unit": "ms", "default": 50.0},
    "makeup":    {"min": 0.0,   "max": 20.0,  "unit": "dB", "default": 0.0},
}

# Persistent envelope follower state
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Compressor — dynamic range compression with envelope follower.

    Reduces the dynamic range of the audio signal using a peak-detecting
    envelope follower. When the signal exceeds the threshold, gain is reduced
    according to the compression ratio. Attack and release times control how
    quickly the compressor responds to level changes. Makeup gain compensates
    for the overall volume reduction caused by compression.

    The envelope follower operates per-sample across all channels (peak detection),
    so stereo signals are compressed with linked gain to preserve the stereo image.

    Params:
        threshold: Compression threshold (-40 to -3 dB)
        ratio:     Compression ratio (2:1 to 20:1)
        attack:    Attack time (0.5 to 50 ms)
        release:   Release time (10 to 500 ms)
        makeup:    Makeup gain (0 to 20 dB)
    """
    global _envelope

    threshold_db = params["threshold"]
    ratio = params["ratio"]
    attack_ms = params["attack"]
    release_ms = params["release"]
    makeup_db = params["makeup"]

    threshold = 10.0 ** (threshold_db / 20.0)
    makeup = 10.0 ** (makeup_db / 20.0)
    attack_coeff = np.exp(-1.0 / (attack_ms * 0.001 * sample_rate))
    release_coeff = np.exp(-1.0 / (release_ms * 0.001 * sample_rate))

    # Compute gain reduction per sample using peak envelope across channels
    gain = np.ones(frame_count, dtype=np.float32)
    env = _envelope

    for i in range(frame_count):
        # Peak detect across all channels
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        # Envelope follower
        if peak > env:
            env = attack_coeff * env + (1.0 - attack_coeff) * peak
        else:
            env = release_coeff * env + (1.0 - release_coeff) * peak

        # Gain computation
        if env > threshold:
            db_over = 20.0 * np.log10(env / threshold + 1e-30)
            db_reduction = db_over * (1.0 - 1.0 / ratio)
            gain[i] = 10.0 ** (-db_reduction / 20.0)

    _envelope = env

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * gain * makeup
