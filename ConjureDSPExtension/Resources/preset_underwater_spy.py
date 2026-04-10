# Underwater Spy — guitar played underwater in a 1960s spy movie.
#
# Resonant underwater lowpass + 250 Hz cavity resonance → vibrato pre-stage →
# 4-voice chorus → spring-reverb impression (4 cascaded Schroeder allpasses +
# feedback tank) → Bond-era tape slap → tremolo → mid/side widening → mix.
#
# Params:
#   depth  (Hz)  — underwater LP cutoff (300–2000, log)
#   bubble (ms)  — chorus depth (0.5–8)
#   spring (pct) — spring tank feedback amount (0–100)
#   tide   (pct) — tremolo depth (0–100)
#   mix          — wet/dry blend

from conjuredsp import (freq, time_ms, mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "depth":  freq(min=300, max=2000, default=900),
    "bubble": time_ms(0.5, 8, default=3.0),
    "spring": pct(default=55),
    "tide":   pct(default=35),
    "mix":    mix(default=0.55),
}

# Chorus voice delays (ms) — 4 prime-ish times
CH_MS = [4.0, 7.0, 11.0, 15.0]
# Schroeder allpass diffuser delays (ms) and gain
AP_MS = [5.1, 7.3, 11.7, 17.3]
AP_G = 0.55
# Spring tank feedback comb delay (ms)
TANK_MS = 38.0
# Tape slap delay (ms)
SLAP_MS = 95.0
# Vibrato pre-stage center delay (ms) and depth (ms)
VIB_MS = 5.0
VIB_DEPTH_MS = 0.25

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.25 * sr)
        # Per-channel state
        self.lp = [Biquad() for _ in range(nch)]
        self.cav = [Biquad() for _ in range(nch)]
        self.vib = [DelayLine(mx) for _ in range(nch)]
        self.ch = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.aps = [[0.0] * 4 for _ in range(nch)]
        self.tank = [DelayLine(mx) for _ in range(nch)]
        self.tank_lp = [Biquad() for _ in range(nch)]
        self.tank_fb = [0.0 for _ in range(nch)]
        self.slap = [DelayLine(mx) for _ in range(nch)]
        self.slap_lp = [Biquad() for _ in range(nch)]
        self.slap_fb = [0.0 for _ in range(nch)]
        # Shared LFOs
        self.lfo_vib = LFO(sr, freq=6.0, waveform="sine")
        self.lfos_ch = [LFO(sr, freq=r, waveform="sine")
                        for r in [0.4, 0.5, 0.6, 0.8]]
        self.lfo_trem = LFO(sr, freq=4.0, waveform="triangle")


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    depth_hz = params["depth"]
    bubble_ms = params["bubble"]
    spring = params["spring"] / 100.0
    tide = params["tide"] / 100.0
    mx = params["mix"]

    # Filter coefficients (computed once per block)
    lpc = BiquadCoeffs.lowpass(depth_hz, 2.0, sample_rate)
    cavc = BiquadCoeffs.peak(250.0, 3.0, 6.0, sample_rate)
    fblpc = BiquadCoeffs.lowpass(2500.0, 0.707, sample_rate)
    for ch in range(nch):
        s.lp[ch].set_coeffs(lpc)
        s.cav[ch].set_coeffs(cavc)
        s.tank_lp[ch].set_coeffs(fblpc)
        s.slap_lp[ch].set_coeffs(fblpc)

    # Precomputed delay times (samples)
    vib_d = VIB_MS * 0.001 * sample_rate
    vib_depth = VIB_DEPTH_MS * 0.001 * sample_rate
    ch_d = [CH_MS[c] * 0.001 * sample_rate for c in range(4)]
    ap_d = [max(AP_MS[a] * 0.001 * sample_rate, 1.0) for a in range(4)]
    tank_d = TANK_MS * 0.001 * sample_rate
    slap_d = SLAP_MS * 0.001 * sample_rate

    bubble_samp = bubble_ms * 0.001 * sample_rate
    tank_fb_amt = 0.85 * spring
    slap_fb_amt = 0.4

    for i in range(frame_count):
        v = s.lfo_vib.tick()
        m0 = s.lfos_ch[0].tick()
        m1 = s.lfos_ch[1].tick()
        m2 = s.lfos_ch[2].tick()
        m3 = s.lfos_ch[3].tick()
        trem = s.lfo_trem.tick()
        trem_gain = 1.0 - tide * 0.25 * (1.0 - trem)

        # Per-channel wet signal
        wet = [0.0] * nch
        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: underwater lowpass
            x = s.lp[ch].process_sample(dry)

            # Stage B: water cavity peak
            x = s.cav[ch].process_sample(x)

            # Stage C: vibrato pre-stage
            s.vib[ch].write(x)
            x = s.vib[ch].read(max(vib_d + v * vib_depth, 1.0))

            # Stage D: 4-voice chorus
            csum = 0.0
            for c in range(4):
                s.ch[ch][c].write(x)
            d0 = max(ch_d[0] + m0 * bubble_samp, 1.0)
            d1 = max(ch_d[1] + m1 * bubble_samp, 1.0)
            d2 = max(ch_d[2] + m2 * bubble_samp, 1.0)
            d3 = max(ch_d[3] + m3 * bubble_samp, 1.0)
            csum = (s.ch[ch][0].read(d0)
                    + s.ch[ch][1].read(d1)
                    + s.ch[ch][2].read(d2)
                    + s.ch[ch][3].read(d3)) * 0.25

            sig = csum

            # Stage E: 4 cascaded Schroeder allpass diffusers
            for a in range(4):
                vd = s.aps[ch][a]
                vn = sig + AP_G * vd
                s.ap[ch][a].write(vn)
                s.aps[ch][a] = s.ap[ch][a].read(ap_d[a])
                sig = vd - AP_G * vn

            # Stage F: spring tank feedback comb (LP in feedback loop)
            tflt = s.tank_lp[ch].process_sample(s.tank_fb[ch])
            s.tank[ch].write(sig + tank_fb_amt * tflt)
            s.tank_fb[ch] = s.tank[ch].read(tank_d)
            sig = sig + 0.6 * s.tank_fb[ch]

            # Stage G: Bond tape slap
            sflt = s.slap_lp[ch].process_sample(s.slap_fb[ch])
            s.slap[ch].write(sig + slap_fb_amt * sflt)
            s.slap_fb[ch] = s.slap[ch].read(slap_d)
            sig = sig + 0.3 * s.slap_fb[ch]

            # Stage H: tremolo gain
            sig = sig * trem_gain

            wet[ch] = sig

        # Stage I: mid/side widening (only meaningful at nch >= 2)
        if nch >= 2:
            mid = (wet[0] + wet[1]) * 0.5
            side = (wet[0] - wet[1]) * 0.5 * 1.5
            wet[0] = mid + side
            wet[1] = mid - side

        # Stage J: final wet/dry mix
        for ch in range(nch):
            dry = float(inputs[ch][i])
            outputs[ch][i] = dry * (1.0 - mx) + wet[ch] * mx
