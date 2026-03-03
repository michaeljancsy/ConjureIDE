import numpy as np

# Compressor parameters
THRESHOLD_DB = -20.0  # Level above which compression kicks in
RATIO = 4.0           # Compression ratio (4:1)
ATTACK_MS = 5.0       # Attack time in milliseconds
RELEASE_MS = 50.0     # Release time in milliseconds
MAKEUP_DB = 6.0       # Makeup gain in dB

# Persistent envelope follower state
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate):
    """Compressor — dynamic range compression with envelope follower."""
    global _envelope

    threshold = 10.0 ** (THRESHOLD_DB / 20.0)
    makeup = 10.0 ** (MAKEUP_DB / 20.0)
    attack_coeff = np.exp(-1.0 / (ATTACK_MS * 0.001 * sample_rate))
    release_coeff = np.exp(-1.0 / (RELEASE_MS * 0.001 * sample_rate))

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
            db_reduction = db_over * (1.0 - 1.0 / RATIO)
            gain[i] = 10.0 ** (-db_reduction / 20.0)

    _envelope = env

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * gain * makeup
