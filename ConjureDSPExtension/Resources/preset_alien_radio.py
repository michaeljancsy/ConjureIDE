# Alien Radio — alien radio signal bleeding through from another dimension.
#
# Per-channel telephony bandpass → per-channel ring modulation (L: 110 Hz,
# R: 1760 Hz alien harmonic) → heterodyne squeal feedback comb → sample-and-
# hold rate reduction → bit-depth reduction → squelch tremolo → carrier
# interference (800 Hz beating tone) → mid/side widening → final highpass → mix.
#
# Params:
#   drift        (pct) — modulates carrier ring-mod offsets
#   interference (pct) — tremolo depth + carrier bleed amount
#   static       (pct) — heterodyne squeal feedback amount
#   crush        (pct) — bit-depth reduction amount, 0=clean / 100=destroyed
#   mix                — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "drift":        pct(default=40),
    "interference": pct(default=55),
    "static":       pct(default=60),
    "crush":        pct(default=50),
    "mix":          mix(default=0.6),
}

# Per-channel bandpass center frequencies (L low, R high — wide stereo)
BP_HZ = [800.0, 2400.0]
BP_Q = 8.0
# Per-channel ring-mod carriers (alien harmonic series)
CARRIER_HZ = [110.0, 1760.0]
# Drift LFO frequency (Hz) — modulates carriers
DRIFT_LFO_HZ = 0.17
DRIFT_DEPTH_HZ = 12.0
# Squelch tremolo LFO (Hz)
TREM_HZ = 11.0
# Carrier interference (slow swoon)
INTERFERE_LFO_HZ = 0.3
INTERFERE_TONE_HZ = 800.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.05 * sr)
        self.bp = [Biquad() for _ in range(nch)]
        self.squeal = [DelayLine(mx) for _ in range(nch)]
        self.squeal_fb = [0.0 for _ in range(nch)]
        self.hp = [Biquad() for _ in range(nch)]
        self.sh_held = [0.0 for _ in range(nch)]
        self.sh_count = 0
        self.lfo_drift = LFO(sr, freq=DRIFT_LFO_HZ, waveform="sine")
        self.lfo_carriers = [LFO(sr, freq=CARRIER_HZ[0], waveform="sine"),
                             LFO(sr, freq=CARRIER_HZ[1], waveform="sine")]
        self.lfo_trem = LFO(sr, freq=TREM_HZ, waveform="square")
        self.trem_env = 1.0
        self.lfo_interfere_amp = LFO(sr, freq=INTERFERE_LFO_HZ, waveform="sine")
        self.lfo_interfere_tone = LFO(sr, freq=INTERFERE_TONE_HZ, waveform="sine")


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    drift = params["drift"] / 100.0
    interference = params["interference"] / 100.0
    static = params["static"] / 100.0
    crush = params["crush"] / 100.0
    mx = params["mix"]

    # Per-channel bandpass coefficients
    for ch in range(nch):
        bpc = BiquadCoeffs.bandpass(BP_HZ[ch], BP_Q, sample_rate)
        s.bp[ch].set_coeffs(bpc)

    # Final highpass at 250 Hz (per-channel state, same coeffs)
    hpc = BiquadCoeffs.highpass(250.0, 0.707, sample_rate)
    for ch in range(nch):
        s.hp[ch].set_coeffs(hpc)

    # Heterodyne squeal: delay = period of carrier frequency (per channel)
    squeal_d = [max(sample_rate / CARRIER_HZ[ch], 1.0) for ch in range(nch)]

    # Bit-crush levels: 3 bits at crush=1, 12 bits at crush=0
    bits = 12.0 - 9.0 * crush
    levels = 2.0 ** bits
    inv_levels = 1.0 / levels

    # Sample-and-hold period: 1 → 6 samples
    sh_period = max(int(1.0 + 5.0 * crush), 1)

    # Squelch tremolo smoothing (12 ms one-pole)
    trem_alpha = math.exp(-1.0 / (0.012 * sample_rate))
    one_minus_alpha = 1.0 - trem_alpha
    trem_depth = interference * 0.6

    # Heterodyne feedback amount (capped at 0.85 for parity safety)
    squeal_fb_amt = 0.85 * static

    # Carrier interference (-18 dB · interference)
    interfere_gain = 0.126 * interference

    wet = [0.0 for _ in range(nch)]

    for i in range(frame_count):
        # Tick all LFOs once per sample
        d_lfo = s.lfo_drift.tick()
        car0 = s.lfo_carriers[0].tick()
        car1 = s.lfo_carriers[1].tick()
        trem = (s.lfo_trem.tick() + 1.0) * 0.5
        ia = s.lfo_interfere_amp.tick()
        it = s.lfo_interfere_tone.tick()

        # Smoothed squelch tremolo envelope
        s.trem_env = trem_alpha * s.trem_env + one_minus_alpha * trem
        trem_gain = 1.0 - trem_depth * (1.0 - s.trem_env)

        # Sample-and-hold counter
        update_held = (s.sh_count % sh_period) == 0
        s.sh_count += 1

        # Carrier interference signal (one for both channels)
        interfere = it * (0.5 + 0.5 * ia) * interfere_gain

        # Drift modulates the ring-mod amplitude (deterministic carrier wobble)
        car_mod0 = car0 * (1.0 + drift * 0.3 * d_lfo)
        car_mod1 = car1 * (1.0 + drift * 0.3 * d_lfo)
        car = [car_mod0, car_mod1]

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: per-channel bandpass
            x = s.bp[ch].process_sample(dry)

            # Stage B: per-channel ring modulation
            x = x * car[ch]

            # Stage C: heterodyne squeal feedback comb
            s.squeal[ch].write(x + squeal_fb_amt * s.squeal_fb[ch])
            s.squeal_fb[ch] = s.squeal[ch].read(squeal_d[ch])
            x = x + 0.5 * s.squeal_fb[ch]

            # Stage D: sample-and-hold rate reduction
            if update_held:
                s.sh_held[ch] = x
            sig = s.sh_held[ch]

            # Stage E: bit-depth reduction
            sig = math.floor(sig * levels + 0.5) * inv_levels

            # Stage F: squelch tremolo
            sig = sig * trem_gain

            # Stage G: carrier interference bleed
            sig = sig + interfere

            wet[ch] = sig

        # Stage H: mid/side widening
        if nch >= 2:
            mid = (wet[0] + wet[1]) * 0.5
            side = (wet[0] - wet[1]) * 0.5 * 1.7
            wet[0] = mid + side
            wet[1] = mid - side

        # Stage I: final highpass + wet/dry mix
        for ch in range(nch):
            dry = float(inputs[ch][i])
            sig = s.hp[ch].process_sample(wet[ch])
            outputs[ch][i] = dry * (1.0 - mx) + sig * mx
