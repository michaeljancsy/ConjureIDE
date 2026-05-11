"""Tests for conjuredsp.params builder defaults.

The named builders (freq, lfo_rate, db, time_ms, ratio) carry a static
default that's sensible at the builder's default range. When the caller
customizes min/max so the static default no longer fits, the builder must
fall back to an in-range value automatically — otherwise a perfectly
reasonable shorthand like `time_ms(0.5, 50)` raises `ValueError`.

The fallback rule:
- If the static default is in `[min, max]`, use it.
- Else, log curve → geometric mean; linear curve → arithmetic mean.

Explicit out-of-range `default=` still raises (param() validates), so
genuine mistakes are still caught.
"""

import math

import pytest

from conjuredsp.params import db, freq, lfo_rate, ratio, time_ms


# --- time_ms -----------------------------------------------------------------


def test_time_ms_default_range_uses_static_default():
    spec = time_ms()
    assert spec["default"] == 100.0


def test_time_ms_custom_range_excluding_static_default_uses_geometric_mean():
    # Range [0.5, 50] excludes the static default (100). The agent UX
    # experiment caught this case — `time_ms(0.5, 50)` was the agent's
    # natural shorthand for an attack-time control, and it raised.
    spec = time_ms(0.5, 50.0)
    expected = math.sqrt(0.5 * 50.0)  # 5.0 ms
    assert abs(spec["default"] - expected) < 1e-9
    assert spec["min"] == 0.5
    assert spec["max"] == 50.0


def test_time_ms_custom_range_including_static_default_uses_static():
    # Range [10, 500] includes 100, so the static default still wins.
    spec = time_ms(10.0, 500.0)
    assert spec["default"] == 100.0


def test_time_ms_explicit_default_overrides_static():
    spec = time_ms(0.5, 50.0, default=10.0)
    assert spec["default"] == 10.0


def test_time_ms_explicit_default_out_of_range_still_raises():
    # Smart-default fallback must NOT bypass param()'s validation when the
    # caller explicitly passed something invalid — that's a real bug to
    # surface, not a UX papercut to paper over.
    with pytest.raises(ValueError, match="outside the declared range"):
        time_ms(0.5, 50.0, default=100.0)


# --- freq --------------------------------------------------------------------


def test_freq_default_range_uses_static_default():
    spec = freq()
    assert spec["default"] == 1000.0


def test_freq_custom_range_excluding_static_uses_geometric_mean():
    spec = freq(50.0, 200.0)  # Excludes 1000
    expected = math.sqrt(50.0 * 200.0)  # 100 Hz
    assert abs(spec["default"] - expected) < 1e-9


def test_freq_custom_range_including_static_uses_static():
    spec = freq(500.0, 5000.0)  # Includes 1000
    assert spec["default"] == 1000.0


# --- lfo_rate ----------------------------------------------------------------


def test_lfo_rate_default_range_uses_static_default():
    spec = lfo_rate()
    assert spec["default"] == 1.0


def test_lfo_rate_custom_range_excluding_static_uses_geometric_mean():
    spec = lfo_rate(2.0, 8.0)  # Excludes 1
    expected = math.sqrt(2.0 * 8.0)  # 4 Hz
    assert abs(spec["default"] - expected) < 1e-9


# --- db ----------------------------------------------------------------------


def test_db_default_range_uses_static_default():
    spec = db()
    assert spec["default"] == 0.0


def test_db_custom_range_excluding_zero_uses_arithmetic_mean():
    # db is linear, so midpoint is arithmetic.
    spec = db(min=6.0, max=24.0)  # Excludes 0
    assert spec["default"] == 15.0


def test_db_custom_range_including_zero_uses_static():
    spec = db(min=-12.0, max=12.0)  # Includes 0
    assert spec["default"] == 0.0


# --- ratio -------------------------------------------------------------------


def test_ratio_default_range_uses_static_default():
    spec = ratio()
    assert spec["default"] == 4.0


def test_ratio_custom_range_excluding_static_uses_arithmetic_mean():
    spec = ratio(min=8.0, max=20.0)  # Excludes 4
    assert spec["default"] == 14.0


def test_ratio_custom_range_including_static_uses_static():
    spec = ratio(min=2.0, max=10.0)  # Includes 4
    assert spec["default"] == 4.0
