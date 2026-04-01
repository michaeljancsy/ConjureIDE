"""Parity tests for conjuredsp.accel (Python) vs conjuredsp-rs accel (Rust).

These test vectors are shared with rust/conjuredsp-rs/src/accel.rs.
Both implementations must produce matching results.
"""

import numpy as np
from conjuredsp.accel import matmul, vec_add, vec_mul, vec_tanh, vec_sigmoid, vec_add_scalar


def test_matmul_2x3_times_3x2():
    # A = [[1, 2, 3], [4, 5, 6]]  (2x3)
    # B = [[7, 8], [9, 10], [11, 12]]  (3x2)
    # C = [[58, 64], [139, 154]]  (2x2)
    a = np.array([[1, 2, 3], [4, 5, 6]], dtype=np.float32)
    b = np.array([[7, 8], [9, 10], [11, 12]], dtype=np.float32)
    c = matmul(a, b)
    expected = np.array([[58, 64], [139, 154]], dtype=np.float32)
    np.testing.assert_allclose(c, expected, rtol=1e-5)


def test_matmul_identity():
    identity = np.eye(2, dtype=np.float32)
    a = np.array([[3, 7], [2, 5]], dtype=np.float32)
    c = matmul(identity, a)
    np.testing.assert_allclose(c, a, rtol=1e-5)


def test_matmul_zero():
    a = np.array([[1, 2], [3, 4]], dtype=np.float32)
    zero = np.zeros((2, 2), dtype=np.float32)
    c = matmul(a, zero)
    np.testing.assert_allclose(c, zero, rtol=1e-5)


def test_vec_add_basic():
    a = np.array([1, 2, 3, 4], dtype=np.float32)
    b = np.array([10, 20, 30, 40], dtype=np.float32)
    out = vec_add(a, b)
    np.testing.assert_allclose(out, [11, 22, 33, 44], rtol=1e-5)


def test_vec_mul_basic():
    a = np.array([1, 2, 3, 4], dtype=np.float32)
    b = np.array([5, 6, 7, 8], dtype=np.float32)
    out = vec_mul(a, b)
    np.testing.assert_allclose(out, [5, 12, 21, 32], rtol=1e-5)


def test_vec_tanh_known_values():
    x = np.array([0.0, 1.0, -1.0, 10.0, -10.0], dtype=np.float32)
    y = vec_tanh(x)
    np.testing.assert_allclose(y[0], 0.0, atol=1e-5)
    np.testing.assert_allclose(y[1], 0.7615942, rtol=1e-4)
    np.testing.assert_allclose(y[2], -0.7615942, rtol=1e-4)
    np.testing.assert_allclose(y[3], 1.0, atol=1e-4)
    np.testing.assert_allclose(y[4], -1.0, atol=1e-4)


def test_vec_sigmoid_known_values():
    x = np.array([0.0, 1.0, -1.0, 10.0, -10.0, 88.0, -88.0], dtype=np.float32)
    y = vec_sigmoid(x)
    np.testing.assert_allclose(y[0], 0.5, atol=1e-5)
    np.testing.assert_allclose(y[1], 0.7310586, rtol=1e-4)
    np.testing.assert_allclose(y[2], 0.2689414, rtol=1e-4)
    np.testing.assert_allclose(y[3], 1.0, atol=1e-3)
    np.testing.assert_allclose(y[4], 0.0, atol=1e-3)
    np.testing.assert_allclose(y[5], 1.0, atol=1e-5)
    np.testing.assert_allclose(y[6], 0.0, atol=1e-5)


def test_vec_add_scalar_basic():
    x = np.array([1, 2, 3, 4], dtype=np.float32)
    out = vec_add_scalar(x, 10.0)
    np.testing.assert_allclose(out, [11, 12, 13, 14], rtol=1e-5)


if __name__ == "__main__":
    tests = [
        test_matmul_2x3_times_3x2,
        test_matmul_identity,
        test_matmul_zero,
        test_vec_add_basic,
        test_vec_mul_basic,
        test_vec_tanh_known_values,
        test_vec_sigmoid_known_values,
        test_vec_add_scalar_basic,
    ]
    for t in tests:
        t()
        print(f"  PASS: {t.__name__}")
    print(f"\nAll {len(tests)} parity tests passed.")
