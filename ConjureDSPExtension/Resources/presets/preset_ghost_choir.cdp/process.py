# Ghost Choir — choir of ghosts whispering secrets backwards.
#
# Lowpass formant softening → 3 series vowel-formant peak filters → 8-voice
# prime-spaced chorus modulated by 8 coprime LFOs → reversed-attack envelope
# shaper (slow-attack one-pole on delayed-dry abs) modulating chorus voices →
# whisper-band parallel layer → 4 modulated comb cathedral wash → 2 allpass
# diffusers → mid/side widening → breathing tremolo → mix.
#
# Params:
#   voices  (ms)  — chorus depth (0.5–6)
#   air     (Hz)  — formant softening LP cutoff (1500–6000)
#   whisper (pct) — whisper layer level
#   wash    (pct) — cathedral wash level
#   mix           — wet/dry blend

import math
from conjuredsp import (freq, mix, pct, time_ms,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "voices":  time_ms(0.5, 6.0, default=2.5),
    "air":     freq(min=1500.0, max=6000.0, default=3500.0),
    "whisper": pct(default=45),
    "wash":    pct(default=60),
    "mix":     mix(default=0.6),
}

# 8-voice chorus delays (prime-spaced ms) and LFO rates (coprime Hz)
CH_MS = [11.0, 13.0, 17.0, 19.0, 23.0, 29.0, 31.0, 37.0]
CH_LFO_HZ = [0.21, 0.27, 0.33, 0.39, 0.45, 0.51, 0.57, 0.63]
# Vowel formant frequencies (the "ah" vowel)
FORMANT_HZ = [700.0, 1200.0, 2500.0]
FORMANT_GAIN = 4.0
FORMANT_Q = 4.0
# Reversed-attack env: 80 ms pre-delay
REV_DELAY_MS = 80.0
# Cathedral wash combs (ms)
COMB_MS = [119.0, 137.0, 163.0, 197.0]
COMB_LFO_HZ = [0.07, 0.09, 0.11, 0.13]
COMB_DEPTH_MS = 2.0
COMB_FB = 0.78
# Diffusion allpasses (ms)
AP_MS = [18.3, 7.9]
AP_G = 0.6
# Tremolo
TREM_HZ = 6.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.3 * sr)
        self.lp = [Biquad() for _ in range(nch)]
        self.formants = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.chorus = [DelayLine(mx) for _ in range(nch)]
        self.rev_dl = [DelayLine(mx) for _ in range(nch)]
        self.rev_env = [0.0 for _ in range(nch)]
        self.whisper_bp = [Biquad() for _ in range(nch)]
        self.whisper_hs = [Biquad() for _ in range(nch)]
        self.combs = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(4)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.aps = [[0.0, 0.0] for _ in range(nch)]
        self.lfo_chorus = [LFO(sr, freq=h, waveform="sine") for h in CH_LFO_HZ]
        self.lfo_combs = [LFO(sr, freq=h, waveform="sine") for h in COMB_LFO_HZ]
        self.lfo_trem = LFO(sr, freq=TREM_HZ, waveform="triangle")


def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    voices_ms = params["voices"]
    air_hz = params["air"]
    whisper = params["whisper"] / 100.0
    wash = params["wash"] / 100.0
    mx = params["mix"]

    # Filter coefficients
    lpc = BiquadCoeffs.lowpass(air_hz, 0.707, sample_rate)
    formant_c = [BiquadCoeffs.peak(FORMANT_HZ[k], FORMANT_Q, FORMANT_GAIN, sample_rate)
                 for k in range(3)]
    whisper_bpc = BiquadCoeffs.bandpass(2500.0, 4.0, sample_rate)
    whisper_hsc = BiquadCoeffs.highshelf(8000.0, 0.707, 6.0, sample_rate)
    comb_lpc = BiquadCoeffs.lowpass(3000.0, 0.707, sample_rate)
    for ch in range(nch):
        s.lp[ch].set_coeffs(lpc)
        for k in range(3):
            s.formants[ch][k].set_coeffs(formant_c[k])
        s.whisper_bp[ch].set_coeffs(whisper_bpc)
        s.whisper_hs[ch].set_coeffs(whisper_hsc)
        for k in range(4):
            s.comb_lp[ch][k].set_coeffs(comb_lpc)

    # Delay times (samples)
    ch_d = [CH_MS[k] * 0.001 * sample_rate for k in range(8)]
    voice_depth = voices_ms * 0.001 * sample_rate
    rev_d = max(REV_DELAY_MS * 0.001 * sample_rate, 1.0)
    comb_d = [COMB_MS[k] * 0.001 * sample_rate for k in range(4)]
    comb_depth = COMB_DEPTH_MS * 0.001 * sample_rate
    ap_d = [max(AP_MS[k] * 0.001 * sample_rate, 1.0) for k in range(2)]

    # Reversed-attack one-pole (100 ms attack)
    rev_alpha = math.exp(-1.0 / (0.100 * sample_rate))
    one_minus_rev = 1.0 - rev_alpha

    trem_depth = 0.08

    wet = [0.0 for _ in range(nch)]

    for i in range(frame_count):
        # Tick global LFOs
        chl = [s.lfo_chorus[k].tick() for k in range(8)]
        cbl = [s.lfo_combs[k].tick() for k in range(4)]
        trem = s.lfo_trem.tick()
        trem_gain = 1.0 - trem_depth * (1.0 - (trem + 1.0) * 0.5)

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: lowpass formant softening
            x = s.lp[ch].process_sample(dry)

            # Stage B: vowel formant peaks
            x = s.formants[ch][0].process_sample(x)
            x = s.formants[ch][1].process_sample(x)
            x = s.formants[ch][2].process_sample(x)

            # Stage C: 8-voice chorus
            s.chorus[ch].write(x)
            d0 = max(ch_d[0] + chl[0] * voice_depth, 1.0)
            d1 = max(ch_d[1] + chl[1] * voice_depth, 1.0)
            d2 = max(ch_d[2] + chl[2] * voice_depth, 1.0)
            d3 = max(ch_d[3] + chl[3] * voice_depth, 1.0)
            d4 = max(ch_d[4] + chl[4] * voice_depth, 1.0)
            d5 = max(ch_d[5] + chl[5] * voice_depth, 1.0)
            d6 = max(ch_d[6] + chl[6] * voice_depth, 1.0)
            d7 = max(ch_d[7] + chl[7] * voice_depth, 1.0)
            csum = (s.chorus[ch].read(d0)
                    + s.chorus[ch].read(d1)
                    + s.chorus[ch].read(d2)
                    + s.chorus[ch].read(d3)
                    + s.chorus[ch].read(d4)
                    + s.chorus[ch].read(d5)
                    + s.chorus[ch].read(d6)
                    + s.chorus[ch].read(d7)) * 0.125

            # Stage D: reversed-attack envelope shaper on delayed dry
            s.rev_dl[ch].write(dry)
            rev_tap = s.rev_dl[ch].read(rev_d)
            target = abs(rev_tap)
            s.rev_env[ch] = rev_alpha * s.rev_env[ch] + one_minus_rev * target
            chorus_voice = csum * (0.4 + 1.6 * s.rev_env[ch])

            # Stage E: whisper layer (parallel)
            wb = s.whisper_bp[ch].process_sample(x)
            wb = math.tanh(wb * 1.5)
            wb = s.whisper_hs[ch].process_sample(wb)
            whisper_voice = wb * whisper

            # Stage F: cathedral wash — 4 modulated comb filters
            wash_in = chorus_voice
            cw0 = max(comb_d[0] + cbl[0] * comb_depth, 1.0)
            cw1 = max(comb_d[1] + cbl[1] * comb_depth, 1.0)
            cw2 = max(comb_d[2] + cbl[2] * comb_depth, 1.0)
            cw3 = max(comb_d[3] + cbl[3] * comb_depth, 1.0)
            f0 = s.comb_lp[ch][0].process_sample(s.comb_fb[ch][0])
            f1 = s.comb_lp[ch][1].process_sample(s.comb_fb[ch][1])
            f2 = s.comb_lp[ch][2].process_sample(s.comb_fb[ch][2])
            f3 = s.comb_lp[ch][3].process_sample(s.comb_fb[ch][3])
            s.combs[ch][0].write(wash_in + COMB_FB * f0)
            s.combs[ch][1].write(wash_in + COMB_FB * f1)
            s.combs[ch][2].write(wash_in + COMB_FB * f2)
            s.combs[ch][3].write(wash_in + COMB_FB * f3)
            s.comb_fb[ch][0] = s.combs[ch][0].read(cw0)
            s.comb_fb[ch][1] = s.combs[ch][1].read(cw1)
            s.comb_fb[ch][2] = s.combs[ch][2].read(cw2)
            s.comb_fb[ch][3] = s.combs[ch][3].read(cw3)
            cathedral = (s.comb_fb[ch][0] + s.comb_fb[ch][1]
                         + s.comb_fb[ch][2] + s.comb_fb[ch][3]) * 0.25

            # Stage G: 2 cascaded Schroeder allpass diffusers
            sig = chorus_voice + whisper_voice + cathedral * wash
            for k in range(2):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            wet[ch] = sig

        # Stage H: mid/side widening
        if nch >= 2:
            mid = (wet[0] + wet[1]) * 0.5
            side = (wet[0] - wet[1]) * 0.5 * 1.7
            wet[0] = mid + side
            wet[1] = mid - side

        # Stage I: breathing tremolo + final mix
        for ch in range(nch):
            dry = float(inputs[ch][i])
            outputs[ch][i] = dry * (1.0 - mx) + wet[ch] * trem_gain * mx
