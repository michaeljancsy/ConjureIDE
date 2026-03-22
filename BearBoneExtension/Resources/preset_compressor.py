import numpy as np

# Parameters:
THRESHOLD = 0
RATIO = 1
ATTACK = 2
RELEASE = 3
MAKEUP = 4

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
        0 (Threshold): Compression threshold — 0.0 = -40 dB, 1.0 = -3 dB
        1 (Ratio):     Compression ratio — 0.0 = 2:1, 1.0 = 20:1
        2 (Attack):    Attack time — 0.0 = 0.5 ms, 1.0 = 50 ms
        3 (Release):   Release time — 0.0 = 10 ms, 1.0 = 500 ms
        4 (Makeup):    Makeup gain — 0.0 = 0 dB, 1.0 = 20 dB
    """
    global _envelope

    threshold_db = -40.0 + params[THRESHOLD] * 37.0    # -40 to -3 dB
    ratio = 2.0 + params[RATIO] * 18.0             # 2 to 20
    attack_ms = 0.5 + params[ATTACK] * 49.5         # 0.5 to 50 ms
    release_ms = 10.0 + params[RELEASE] * 490.0      # 10 to 500 ms
    makeup_db = params[MAKEUP] * 20.0               # 0 to 20 dB

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
