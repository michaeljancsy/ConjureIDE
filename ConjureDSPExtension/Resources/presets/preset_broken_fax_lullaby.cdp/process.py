# Broken Fax Lullaby — broken fax machine trying to sing a lullaby.
#
# Lullaby chorus pre-stage → 4-carrier ring modulation (real fax modem
# frequencies, gated by deterministic square LFO patterns) → telephony
# bandpass → sample-and-hold rate reduction → bit-depth reduction →
# mechanical comb buzz → 60 Hz mains hum → highpass cleanup → mix.
#
# Params:
#   drift   (pct) — chorus depth (machine-wobble feel)
#   crush   (pct) — bit reduction amount, 0=clean / 100=destroyed
#   gate    (Hz)  — dropout rate (0.5–8)
#   lullaby (pct) — chorus mix into wet bus
#   mix           — wet/dry blend

import math
from conjuredsp import (freq, mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "drift":   pct(default=40),
    "crush":   pct(default=55),
    "gate":    freq(min=0.5, max=8.0, default=2.0),
    "lullaby": pct(default=60),
    "mix":     mix(default=0.55),
}

# Real fax modem carrier frequencies (Hz)
CARRIER_HZ = [1100.0, 1300.0, 2100.0, 2300.0]
# Coprime gate rates (Hz)
GATE_HZ = [0.4, 0.6, 0.7, 0.9]
# Chorus base delay (ms) and depth (ms)
CHORUS_BASE_MS = 9.0
CHORUS_DEPTH_MS = 1.2
# Mechanical comb (ms)
COMB_MS = 9.4
COMB_FB = 0.55

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.1 * sr)
        self.chorus = [DelayLine(mx) for _ in range(nch)]
        self.comb = [DelayLine(mx) for _ in range(nch)]
        self.comb_fb = [0.0 for _ in range(nch)]
        self.bp = [Biquad() for _ in range(nch)]
        self.hp = [Biquad() for _ in range(nch)]
        self.sh_held = [0.0 for _ in range(nch)]
        self.sh_count = 0
        self.lfo_chorus = LFO(sr, freq=1.5, waveform="sine")
        self.lfo_carriers = [LFO(sr, freq=h, waveform="sine") for h in CARRIER_HZ]
        self.lfo_gates = [LFO(sr, freq=h, waveform="square") for h in GATE_HZ]
        self.lfo_dropout = LFO(sr, freq=2.0, waveform="square")
        self.lfo_hum = LFO(sr, freq=60.0, waveform="sine")
        self.gate_env = 1.0


def process(ctx):
    global _st, _sr
    nch = len(ctx.inputs)
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    drift = ctx.params["drift"] / 100.0
    crush = ctx.params["crush"] / 100.0
    gate_hz = ctx.params["gate"]
    lullaby = ctx.params["lullaby"] / 100.0
    mx = ctx.params["mix"]

    # Update gate LFO rate from param (deterministic — once per block)
    s.lfo_dropout.set_freq(gate_hz)

    # Telephony bandpass and final highpass
    bpc = BiquadCoeffs.bandpass(1700.0, 2.0, ctx.sample_rate)
    hpc = BiquadCoeffs.highpass(250.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.bp[ch].set_coeffs(bpc)
        s.hp[ch].set_coeffs(hpc)

    chorus_d = CHORUS_BASE_MS * 0.001 * ctx.sample_rate
    chorus_depth = CHORUS_DEPTH_MS * drift * 0.001 * ctx.sample_rate
    comb_d = max(COMB_MS * 0.001 * ctx.sample_rate, 1.0)

    # Bit-crush levels: 2 bits at crush=1, 10 bits at crush=0
    bits = 10.0 - 8.0 * crush
    levels = 2.0 ** bits
    inv_levels = 1.0 / levels

    # Sample-and-hold period: 2 samples (clean) → 12 samples (crushed)
    sh_period = max(int(2.0 + 10.0 * crush), 1)

    # Smoothing for the dropout gate envelope (10 ms one-pole)
    gate_alpha = math.exp(-1.0 / (0.010 * ctx.sample_rate))
    one_minus_alpha = 1.0 - gate_alpha

    hum_gain = 0.079  # ≈ −22 dB

    for i in range(ctx.frame_count):
        # Tick all LFOs once per sample
        c_lfo = s.lfo_chorus.tick()
        car0 = s.lfo_carriers[0].tick()
        car1 = s.lfo_carriers[1].tick()
        car2 = s.lfo_carriers[2].tick()
        car3 = s.lfo_carriers[3].tick()
        # Gates: square LFO returns ±1; map to (0..1) gating envelopes
        g0 = (s.lfo_gates[0].tick() + 1.0) * 0.5
        g1 = (s.lfo_gates[1].tick() + 1.0) * 0.5
        g2 = (s.lfo_gates[2].tick() + 1.0) * 0.5
        g3 = (s.lfo_gates[3].tick() + 1.0) * 0.5
        drop = (s.lfo_dropout.tick() + 1.0) * 0.5
        hum = s.lfo_hum.tick()

        # Smoothed gate envelope (target tracks the square)
        s.gate_env = gate_alpha * s.gate_env + one_minus_alpha * drop

        # Sample-and-hold counter
        update_held = (s.sh_count % sh_period) == 0
        s.sh_count += 1

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: lullaby chorus pre-stage
            s.chorus[ch].write(dry)
            chorus_read = max(chorus_d + c_lfo * chorus_depth, 1.0)
            chr_voice = s.chorus[ch].read(chorus_read)
            x = dry + lullaby * (chr_voice - dry)

            # Stage B: 4-carrier ring modulation, gated by independent squares
            ring = (x * car0 * g0
                    + x * car1 * g1
                    + x * car2 * g2
                    + x * car3 * g3) * 0.25

            # Stage C: telephony bandpass
            ring = s.bp[ch].process_sample(ring)

            # Stage D: sample-and-hold (rate reduction)
            if update_held:
                s.sh_held[ch] = ring
            sig = s.sh_held[ch]

            # Stage E: bit-depth reduction
            sig = math.floor(sig * levels + 0.5) * inv_levels

            # Stage F: smoothed dropout gate
            sig = sig * s.gate_env

            # Stage G: mechanical comb buzz
            s.comb[ch].write(sig + COMB_FB * s.comb_fb[ch])
            s.comb_fb[ch] = s.comb[ch].read(comb_d)
            sig = sig + 0.4 * s.comb_fb[ch]

            # Stage H: 60 Hz mains hum
            sig = sig + hum * hum_gain

            # Stage I: final highpass
            sig = s.hp[ch].process_sample(sig)

            ctx.outputs[ch][i] = dry * (1.0 - mx) + sig * mx
