import numpy as np

# Ping-pong delay parameters
DELAY_MS = 375.0   # Delay time per side in ms
FEEDBACK = 0.4     # Cross-feedback amount (0.0–0.95)
MIX = 0.5          # Wet/dry mix

# Max delay in samples (supports 500 ms at 96 kHz)
MAX_DELAY = 48000

# Persistent state
_left_buf = None
_right_buf = None
_write_pos = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ping-Pong Delay — stereo bouncing echo.

    Creates echoes that alternate between left and right channels. The
    input feeds into the left delay, the left delay's output feeds into
    the right delay, and the right delay feeds back into the left. This
    creates a bouncing stereo effect. For mono input, the bouncing still
    occurs across the single delay line with feedback.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _left_buf, _right_buf, _write_pos

    n_ch = len(inputs)

    if _left_buf is None:
        _left_buf = np.zeros(MAX_DELAY, dtype=np.float32)
        _right_buf = np.zeros(MAX_DELAY, dtype=np.float32)

    delay_samples = int(DELAY_MS * 0.001 * sample_rate)
    if delay_samples >= MAX_DELAY:
        delay_samples = MAX_DELAY - 1

    wp = _write_pos

    if n_ch < 2:
        # Mono: simple delay with feedback
        for i in range(frame_count):
            rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY
            delayed = _left_buf[rp]
            _left_buf[wp] = inputs[0][i] + delayed * FEEDBACK
            outputs[0][i] = inputs[0][i] * (1.0 - MIX) + delayed * MIX
            wp = (wp + 1) % MAX_DELAY
    else:
        # Stereo: ping-pong
        for i in range(frame_count):
            rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY

            left_delayed = _left_buf[rp]
            right_delayed = _right_buf[rp]

            # Input goes to left, left feeds right, right feeds back to left
            mono_in = (inputs[0][i] + inputs[1][i]) * 0.5
            _left_buf[wp] = mono_in + right_delayed * FEEDBACK
            _right_buf[wp] = left_delayed * FEEDBACK

            # Mix dry + wet
            outputs[0][i] = inputs[0][i] * (1.0 - MIX) + left_delayed * MIX
            outputs[1][i] = inputs[1][i] * (1.0 - MIX) + right_delayed * MIX

            wp = (wp + 1) % MAX_DELAY

    _write_pos = wp
