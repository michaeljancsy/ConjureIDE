"""Tests for conjuredsp.dsp utility functions.

Currently covers VU calibration (0 VU = -18 dBFS, EBU R68); other dsp
helpers have parity coverage in rust/conjuredsp-rs/src/dsp.rs.
"""

from conjuredsp import VU_REF_DBFS, dbfs_to_vu
from conjuredsp.dsp import VU_REF_DBFS as VU_REF_DBFS_DSP
from conjuredsp.dsp import dbfs_to_vu as dbfs_to_vu_dsp


def test_vu_ref_dbfs_constant():
    assert VU_REF_DBFS == -18.0
    assert VU_REF_DBFS_DSP == -18.0


def test_dbfs_to_vu_at_reference():
    assert abs(dbfs_to_vu(-18.0) - 0.0) < 1e-9
    assert abs(dbfs_to_vu_dsp(-18.0) - 0.0) < 1e-9


def test_dbfs_to_vu_full_scale():
    # 0 dBFS is +18 VU under the EBU R68 calibration.
    assert abs(dbfs_to_vu(0.0) - 18.0) < 1e-9


def test_dbfs_to_vu_below_reference():
    # -24 dBFS = -6 VU
    assert abs(dbfs_to_vu(-24.0) - (-6.0)) < 1e-9
