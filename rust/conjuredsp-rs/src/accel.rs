//! Hardware-accelerated vectorized math operations.
//!
//! On `wasm32`, these call host imports backed by Apple's Accelerate framework.
//! On native macOS (host-side NAM inference), they call Accelerate directly.
//!
//! # Example
//!
//! ```ignore
//! use conjuredsp::accel;
//!
//! let a = [1.0, 2.0, 3.0, 4.0];  // 2x2
//! let b = [5.0, 6.0, 7.0, 8.0];  // 2x2
//! let mut c = [0.0f32; 4];
//! accel::matmul(&a, &b, &mut c, 2, 2, 2);
//! // c = [19.0, 22.0, 43.0, 50.0]
//! ```

// ---------------------------------------------------------------------------
// WASM host imports (backed by Accelerate on the host side)
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
#[link(wasm_import_module = "conjuredsp")]
extern "C" {
    fn host_matmul(a: *const f32, b: *const f32, out: *mut f32, m: i32, k: i32, n: i32);
    fn host_matmul_acc(a: *const f32, b: *const f32, c: *mut f32, m: i32, k: i32, n: i32);
    fn host_vec_add(a: *const f32, b: *const f32, out: *mut f32, len: i32);
    fn host_vec_mul(a: *const f32, b: *const f32, out: *mut f32, len: i32);
    fn host_vec_tanh(inp: *const f32, out: *mut f32, len: i32);
    fn host_vec_sigmoid(inp: *const f32, out: *mut f32, len: i32);
    fn host_vec_add_scalar(vec: *const f32, scalar: *const f32, out: *mut f32, len: i32);
}

// ---------------------------------------------------------------------------
// Native Accelerate FFI (direct calls on macOS)
// ---------------------------------------------------------------------------

#[cfg(not(target_arch = "wasm32"))]
#[link(name = "Accelerate", kind = "framework")]
extern "C" {
    fn vDSP_mmul(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        m: u32, n: u32, k: u32,
    );
    fn cblas_sgemm(
        order: i32, transa: i32, transb: i32,
        m: i32, n: i32, k: i32,
        alpha: f32, a: *const f32, lda: i32,
        b: *const f32, ldb: i32,
        beta: f32, c: *mut f32, ldc: i32,
    );
    fn vDSP_vadd(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    fn vDSP_vmul(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    fn vvtanhf(y: *mut f32, x: *const f32, n: *const i32);
    fn vvexpf(y: *mut f32, x: *const f32, n: *const i32);
    fn vDSP_vneg(
        a: *const f32, a_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    fn vDSP_svdiv(
        a: *const f32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    fn vDSP_vsadd(
        a: *const f32, a_stride: i32,
        b: *const f32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Matrix multiply: `out[m×n] = a[m×k] @ b[k×n]`. All slices are row-major.
pub fn matmul(a: &[f32], b: &[f32], out: &mut [f32], m: usize, k: usize, n: usize) {
    debug_assert!(a.len() >= m * k, "a too small: {} < {}", a.len(), m * k);
    debug_assert!(b.len() >= k * n, "b too small: {} < {}", b.len(), k * n);
    debug_assert!(out.len() >= m * n, "out too small: {} < {}", out.len(), m * n);

    #[cfg(target_arch = "wasm32")]
    unsafe {
        host_matmul(a.as_ptr(), b.as_ptr(), out.as_mut_ptr(), m as i32, k as i32, n as i32);
    }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe {
        vDSP_mmul(a.as_ptr(), 1, b.as_ptr(), 1, out.as_mut_ptr(), 1, m as u32, n as u32, k as u32);
    }
}

/// Matrix multiply-accumulate: `c[m×n] += a[m×k] @ b[k×n]`. All slices are row-major.
pub fn matmul_acc(a: &[f32], b: &[f32], c: &mut [f32], m: usize, k: usize, n: usize) {
    debug_assert!(a.len() >= m * k, "a too small: {} < {}", a.len(), m * k);
    debug_assert!(b.len() >= k * n, "b too small: {} < {}", b.len(), k * n);
    debug_assert!(c.len() >= m * n, "c too small: {} < {}", c.len(), m * n);

    #[cfg(target_arch = "wasm32")]
    unsafe {
        host_matmul_acc(a.as_ptr(), b.as_ptr(), c.as_mut_ptr(), m as i32, k as i32, n as i32);
    }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe {
        // CblasRowMajor=101, CblasNoTrans=111; C = 1.0 * A @ B + 1.0 * C
        cblas_sgemm(101, 111, 111, m as i32, n as i32, k as i32,
                    1.0, a.as_ptr(), k as i32, b.as_ptr(), n as i32,
                    1.0, c.as_mut_ptr(), n as i32);
    }
}

/// Element-wise addition: `out[i] = a[i] + b[i]`.
pub fn vec_add(a: &[f32], b: &[f32], out: &mut [f32]) {
    let len = a.len().min(b.len()).min(out.len());

    #[cfg(target_arch = "wasm32")]
    unsafe { host_vec_add(a.as_ptr(), b.as_ptr(), out.as_mut_ptr(), len as i32); }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe { vDSP_vadd(a.as_ptr(), 1, b.as_ptr(), 1, out.as_mut_ptr(), 1, len as u32); }
}

/// Element-wise multiplication: `out[i] = a[i] * b[i]`.
pub fn vec_mul(a: &[f32], b: &[f32], out: &mut [f32]) {
    let len = a.len().min(b.len()).min(out.len());

    #[cfg(target_arch = "wasm32")]
    unsafe { host_vec_mul(a.as_ptr(), b.as_ptr(), out.as_mut_ptr(), len as i32); }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe { vDSP_vmul(a.as_ptr(), 1, b.as_ptr(), 1, out.as_mut_ptr(), 1, len as u32); }
}

/// Element-wise tanh: `out[i] = tanh(input[i])`.
pub fn vec_tanh(input: &[f32], output: &mut [f32]) {
    let len = input.len().min(output.len());

    #[cfg(target_arch = "wasm32")]
    unsafe { host_vec_tanh(input.as_ptr(), output.as_mut_ptr(), len as i32); }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe {
        let n = len as i32;
        vvtanhf(output.as_mut_ptr(), input.as_ptr(), &n);
    }
}

/// Element-wise sigmoid: `out[i] = 1 / (1 + exp(-input[i]))`.
pub fn vec_sigmoid(input: &[f32], output: &mut [f32]) {
    let len = input.len().min(output.len());

    #[cfg(target_arch = "wasm32")]
    unsafe { host_vec_sigmoid(input.as_ptr(), output.as_mut_ptr(), len as i32); }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe {
        let count = len as u32;
        let n = len as i32;
        let one = 1.0f32;
        // sigmoid(x) = 1 / (1 + exp(-x))
        vDSP_vneg(input.as_ptr(), 1, output.as_mut_ptr(), 1, count);
        for i in 0..len { *output.as_mut_ptr().add(i) = (*output.as_ptr().add(i)).clamp(-88.0, 88.0); }
        vvexpf(output.as_mut_ptr(), output.as_ptr(), &n);
        vDSP_vsadd(output.as_ptr(), 1, &one, output.as_mut_ptr(), 1, count);
        vDSP_svdiv(&one, output.as_ptr(), 1, output.as_mut_ptr(), 1, count);
    }
}

/// Add scalar to each element: `out[i] = input[i] + scalar`.
pub fn vec_add_scalar(input: &[f32], scalar: f32, output: &mut [f32]) {
    let len = input.len().min(output.len());

    #[cfg(target_arch = "wasm32")]
    unsafe { host_vec_add_scalar(input.as_ptr(), &scalar as *const f32, output.as_mut_ptr(), len as i32); }

    #[cfg(not(target_arch = "wasm32"))]
    unsafe { vDSP_vsadd(input.as_ptr(), 1, &scalar, output.as_mut_ptr(), 1, len as u32); }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_matmul_2x3_times_3x2() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let b = [7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
        let mut c = [0.0f32; 4];
        matmul(&a, &b, &mut c, 2, 3, 2);
        assert_eq!(c, [58.0, 64.0, 139.0, 154.0]);
    }

    #[test]
    fn test_matmul_identity() {
        let identity = [1.0, 0.0, 0.0, 1.0];
        let a = [3.0, 7.0, 2.0, 5.0];
        let mut c = [0.0f32; 4];
        matmul(&identity, &a, &mut c, 2, 2, 2);
        assert_eq!(c, [3.0, 7.0, 2.0, 5.0]);
    }

    #[test]
    fn test_matmul_zero() {
        let a = [1.0, 2.0, 3.0, 4.0];
        let zero = [0.0f32; 4];
        let mut c = [99.0f32; 4];
        matmul(&a, &zero, &mut c, 2, 2, 2);
        assert_eq!(c, [0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn test_matmul_acc_accumulates() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let b = [7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
        let mut c = [1.0, 2.0, 3.0, 4.0f32];
        matmul_acc(&a, &b, &mut c, 2, 3, 2);
        assert_eq!(c, [59.0, 66.0, 142.0, 158.0]);
    }

    #[test]
    fn test_matmul_acc_zero_matrix_unchanged() {
        let a = [0.0f32; 4];
        let b = [1.0, 2.0, 3.0, 4.0f32];
        let mut c = [5.0, 6.0, 7.0, 8.0f32];
        matmul_acc(&a, &b, &mut c, 2, 2, 2);
        assert_eq!(c, [5.0, 6.0, 7.0, 8.0]);
    }

    #[test]
    fn test_vec_add_basic() {
        let a = [1.0, 2.0, 3.0, 4.0];
        let b = [10.0, 20.0, 30.0, 40.0];
        let mut out = [0.0f32; 4];
        vec_add(&a, &b, &mut out);
        assert_eq!(out, [11.0, 22.0, 33.0, 44.0]);
    }

    #[test]
    fn test_vec_mul_basic() {
        let a = [1.0, 2.0, 3.0, 4.0];
        let b = [5.0, 6.0, 7.0, 8.0];
        let mut out = [0.0f32; 4];
        vec_mul(&a, &b, &mut out);
        assert_eq!(out, [5.0, 12.0, 21.0, 32.0]);
    }

    #[test]
    fn test_vec_tanh_known_values() {
        let input = [0.0, 1.0, -1.0, 10.0, -10.0];
        let mut output = [0.0f32; 5];
        vec_tanh(&input, &mut output);
        assert!((output[0] - 0.0).abs() < 1e-5, "tanh(0) = 0");
        assert!((output[1] - 0.7615942).abs() < 1e-4, "tanh(1)");
        assert!((output[2] - (-0.7615942)).abs() < 1e-4, "tanh(-1)");
        assert!((output[3] - 1.0).abs() < 1e-4, "tanh(10) ≈ 1");
        assert!((output[4] - (-1.0)).abs() < 1e-4, "tanh(-10) ≈ -1");
    }

    #[test]
    fn test_vec_sigmoid_known_values() {
        let input = [0.0, 1.0, -1.0, 10.0, -10.0, 88.0, -88.0];
        let mut output = [0.0f32; 7];
        vec_sigmoid(&input, &mut output);
        assert!((output[0] - 0.5).abs() < 1e-5, "sigmoid(0) = 0.5");
        assert!((output[1] - 0.7310586).abs() < 1e-4, "sigmoid(1)");
        assert!((output[2] - 0.2689414).abs() < 1e-4, "sigmoid(-1)");
        assert!((output[3] - 1.0).abs() < 1e-3, "sigmoid(10) ≈ 1");
        assert!((output[4]).abs() < 1e-3, "sigmoid(-10) ≈ 0");
        assert!((output[5] - 1.0).abs() < 1e-5, "sigmoid(88) ≈ 1");
        assert!(output[6].abs() < 1e-5, "sigmoid(-88) ≈ 0");
    }

    #[test]
    fn test_vec_add_scalar_basic() {
        let input = [1.0, 2.0, 3.0, 4.0];
        let mut output = [0.0f32; 4];
        vec_add_scalar(&input, 10.0, &mut output);
        assert_eq!(output, [11.0, 12.0, 13.0, 14.0]);
    }
}
