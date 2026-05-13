"""Tests for conjuredsp.filters that aren't already covered by parity
with rust/conjuredsp-rs/src/filters.rs.

The eight cookbook constructors (lowpass, highpass, …) have direct Rust
counterparts and are tested there. Python-only contracts live here.
"""

from conjuredsp.filters import Biquad, BiquadCoeffs


def test_identity_is_passthrough():
    c = BiquadCoeffs.identity()
    assert c.b0 == 1.0
    assert c.b1 == 0.0
    assert c.b2 == 0.0
    assert c.a1 == 0.0
    assert c.a2 == 0.0


def test_identity_pre_allocates_slot_array():
    # The motivating use case: a parametric EQ where each slot gets a
    # different filter type assigned at runtime.
    bands = [BiquadCoeffs.identity() for _ in range(5)]
    assert len(bands) == 5
    assert all(b.b0 == 1.0 for b in bands)
    # Each entry is a distinct instance — overwriting one doesn't touch others.
    bands[2] = BiquadCoeffs.lowpass(1000.0, 0.707, 44100.0)
    assert bands[0].b0 == 1.0
    assert bands[2].b0 != 1.0


def test_biquad_with_identity_coeffs_is_passthrough():
    b = Biquad(BiquadCoeffs.identity())
    for i in range(10):
        x = i * 0.1
        y = b.process_sample(x)
        assert abs(y - x) < 1e-10, f"identity not passthrough at i={i}: {y} != {x}"
