//! NAM (Neural Amp Modeler) inference for ConjureDSP Rust/WASM presets.
//!
//! Supports WaveNet and LSTM architectures.  Model data is injected into WASM
//! linear memory by the host via a binary protocol (see [`NamModel::from_binary`]).
//!
//! # Quick start
//!
//! ```ignore
//! use conjuredsp::*;
//! setup!();
//! nam!("tone3000://abc123/def456");
//!
//! params! {
//!     INPUT_GAIN = db().min(-12.0).max(12.0),
//!     MIX = mix(),
//! }
//!
//! #[no_mangle]
//! pub extern "C" fn process(
//!     input: *const f32, output: *mut f32,
//!     channels: i32, frame_count: i32, sample_rate: f32,
//! ) {
//!     let ctx = ctx(input, output, channels, frame_count, sample_rate);
//!     unsafe {
//!         if let Some(model) = NAM_MODEL.as_mut() {
//!             for c in 0..ctx.channels() {
//!                 let n = ctx.frames();
//!                 for i in 0..n { NAM_IN[i] = ctx.input(c, i); }
//!                 model.process_buffer(&NAM_IN[..n], &mut NAM_OUT[..n], c);
//!                 for i in 0..n { ctx.set_output(c, i, NAM_OUT[i]); }
//!             }
//!         }
//!     }
//! }
//! ```

extern crate alloc;
use alloc::vec;
use alloc::vec::Vec;

use crate::accel;

// ---------------------------------------------------------------------------
// Math helpers (scalar versions for single-value use in LSTM gates etc.)
// ---------------------------------------------------------------------------

/// Fast f32 exp approximation. Uses the identity exp(x) = 2^(x/ln2) with a
/// bit-level trick for the integer part and a polynomial for the fraction.
/// Accurate to ~1e-4 relative error over [-88, 88].
#[inline]
fn fast_expf(x: f32) -> f32 {
    // Clamp to avoid overflow/underflow
    let x = if x < -88.0 { -88.0 } else if x > 88.0 { 88.0 } else { x };
    // exp(x) = 2^(x * log2(e))
    let t = x * core::f32::consts::LOG2_E;
    let fi = if t >= 0.0 { t as i32 } else { t as i32 - 1 }; // floor
    let f = t - fi as f32; // fractional part in [0, 1)
    // Polynomial approximation of 2^f for f in [0,1)
    let p = 1.0 + f * (0.6931472 + f * (0.2402265 + f * (0.0554953 + f * 0.0096744)));
    // Multiply by 2^fi via IEEE 754 exponent manipulation
    let bits = ((fi + 127) as u32) << 23;
    p * f32::from_bits(bits)
}

#[inline]
fn sigmoidf(x: f32) -> f32 {
    let x = if x < -88.0 { -88.0 } else if x > 88.0 { 88.0 } else { x };
    1.0 / (1.0 + fast_expf(-x))
}

#[inline]
fn tanhf(x: f32) -> f32 {
    let x = if x < -10.0 { -10.0 } else if x > 10.0 { 10.0 } else { x };
    let e2x = fast_expf(2.0 * x);
    (e2x - 1.0) / (e2x + 1.0)
}

#[inline]
fn reluf(x: f32) -> f32 {
    if x > 0.0 { x } else { 0.0 }
}

// ---------------------------------------------------------------------------
// Weight reader (for binary protocol)
// ---------------------------------------------------------------------------

struct WeightReader<'a> {
    data: &'a [f32],
    offset: usize,
}

impl<'a> WeightReader<'a> {
    fn new(data: &'a [f32]) -> Self {
        Self { data, offset: 0 }
    }

    fn read(&mut self, count: usize) -> &'a [f32] {
        let slice = &self.data[self.offset..self.offset + count];
        self.offset += count;
        slice
    }

    fn read_to_vec(&mut self, count: usize) -> Vec<f32> {
        self.read(count).to_vec()
    }
}

// ---------------------------------------------------------------------------
// Activation functions
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Activation {
    Tanh,
    Relu,
    Sigmoid,
}

impl Activation {
    fn from_str(s: &str) -> Self {
        match s {
            "ReLU" => Activation::Relu,
            "Sigmoid" => Activation::Sigmoid,
            _ => Activation::Tanh,
        }
    }

    #[inline]
    #[allow(dead_code)]
    fn apply(self, x: f32) -> f32 {
        match self {
            Activation::Tanh => tanhf(x),
            Activation::Relu => reluf(x),
            Activation::Sigmoid => sigmoidf(x),
        }
    }
}

// ---------------------------------------------------------------------------
// Convolution primitives (operate on flat row-major buffers)
// ---------------------------------------------------------------------------

/// 1D causal dilated convolution.
/// x: [c_in × l_in] row-major
/// weight: [c_out × c_in × kernel] row-major
/// bias: [c_out] or empty
/// out: [c_out × l_out] row-major, where l_out = l_in - (kernel-1)*dilation
/// scratch: [c_in*kernel × l_out] temporary (caller pre-allocates)
fn conv1d(
    x: &[f32], c_in: usize, l_in: usize,
    weight: &[f32], c_out: usize, kernel: usize,
    bias: &[f32],
    dilation: usize,
    out: &mut [f32],
    scratch: &mut [f32],
) -> usize {
    let l_out = l_in.saturating_sub((kernel - 1) * dilation);
    if l_out == 0 {
        return 0;
    }

    let cik = c_in * kernel;

    // Build im2col matrix in scratch [cik × l_out]
    for k in 0..kernel {
        let offset = (kernel - 1 - k) * dilation;
        for c in 0..c_in {
            let src_row = c * l_in;
            let dst_row = (k * c_in + c) * l_out;
            for j in 0..l_out {
                scratch[dst_row + j] = x[src_row + offset + j];
            }
        }
    }

    // W_flat[c_out × cik] @ cols[cik × l_out] → out[c_out × l_out]
    accel::matmul(weight, scratch, out, c_out, cik, l_out);

    // Add bias (simple O(n) loop — not the bottleneck)
    if !bias.is_empty() {
        for i in 0..c_out {
            let row = i * l_out;
            let b = bias[i];
            for j in 0..l_out {
                out[row + j] += b;
            }
        }
    }

    l_out
}

/// 1x1 convolution (channel mixing).
/// x: [c_in × l] row-major, weight: [c_out × c_in], bias: [c_out] or empty
/// out: [c_out × l]
fn conv1x1(
    x: &[f32], c_in: usize, l: usize,
    weight: &[f32], c_out: usize,
    bias: &[f32],
    out: &mut [f32],
) {
    accel::matmul(weight, x, out, c_out, c_in, l);
    if !bias.is_empty() {
        for i in 0..c_out {
            let row = i * l;
            let b = bias[i];
            for j in 0..l {
                out[row + j] += b;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// WaveNet layer
// ---------------------------------------------------------------------------

struct WaveNetLayer {
    channels: usize,
    dilation: usize,
    kernel_size: usize,
    gated: bool,
    activation: Activation,
    // Weights stored as flat Vec<f32>
    conv_w: Vec<f32>,   // [mid_ch × channels × kernel]
    conv_b: Vec<f32>,   // [mid_ch]
    mix_w: Vec<f32>,    // [mid_ch × condition_size]
    has_layer1x1: bool,
    l1x1_w: Vec<f32>,   // [channels × channels]
    has_head1x1: bool,
    h1x1_w: Vec<f32>,   // [head1x1_out × channels]
    head1x1_out: usize,
    mid_ch: usize,
    condition_size: usize,
}

struct WaveNetLayerArray {
    receptive_field: usize,
    channels: usize,
    rechannel_w: Vec<f32>,  // [channels × input_size]
    input_size: usize,
    layers: Vec<WaveNetLayer>,
    head_rechannel_w: Vec<f32>,  // [head_size × skip_ch]
    head_rechannel_b: Vec<f32>,  // [head_size]
    head_size: usize,
    skip_ch: usize,
}

impl WaveNetLayerArray {
    fn from_config(cfg: &WaveNetLayerArrayConfig, reader: &mut WeightReader) -> Self {
        let channels = cfg.channels;
        let input_size = cfg.input_size;
        let condition_size = cfg.condition_size;
        let head_size = cfg.head_size;
        let kernel_size = cfg.kernel_size;
        let gated = cfg.gated;
        let activation = Activation::from_str(&cfg.activation);
        let has_layer1x1 = cfg.has_layer1x1;
        let has_head1x1 = cfg.has_head1x1;
        let head1x1_out = cfg.head1x1_out;

        let receptive_field = 1 + cfg.dilations.iter().map(|&d| (kernel_size - 1) * d).sum::<usize>();

        let rechannel_w = reader.read_to_vec(channels * input_size);

        let mid_ch = if gated { 2 * channels } else { channels };

        let mut layers = Vec::with_capacity(cfg.dilations.len());
        for &dil in &cfg.dilations {
            let conv_w = reader.read_to_vec(mid_ch * channels * kernel_size);
            let conv_b = reader.read_to_vec(mid_ch);
            let mix_w = reader.read_to_vec(mid_ch * condition_size);
            let l1x1_w = if has_layer1x1 { reader.read_to_vec(channels * channels) } else { Vec::new() };
            let h1x1_w = if has_head1x1 { reader.read_to_vec(head1x1_out * channels) } else { Vec::new() };

            layers.push(WaveNetLayer {
                channels, dilation: dil, kernel_size, gated, activation,
                conv_w, conv_b, mix_w,
                has_layer1x1, l1x1_w,
                has_head1x1, h1x1_w, head1x1_out,
                mid_ch, condition_size,
            });
        }

        let skip_ch = if has_head1x1 { head1x1_out } else { channels };
        let head_rechannel_w = reader.read_to_vec(head_size * skip_ch);
        let head_rechannel_b = if cfg.head_bias { reader.read_to_vec(head_size) } else { Vec::new() };

        Self {
            receptive_field, channels, rechannel_w, input_size,
            layers, head_rechannel_w, head_rechannel_b, head_size, skip_ch,
        }
    }
}

// ---------------------------------------------------------------------------
// WaveNet model
// ---------------------------------------------------------------------------

/// WaveNet NAM model.
pub struct WaveNet {
    layer_arrays: Vec<WaveNetLayerArray>,
    head_layers: Vec<(Activation, Vec<f32>, Vec<f32>, usize, usize)>, // (act, w, b, out_ch, in_ch)
    head_scale: f32,
    /// Total receptive field in samples.
    pub receptive_field: usize,
    // Per-channel history buffer
    history: Vec<Vec<f32>>,
    // Single large work pool — avoids borrow checker issues with multiple &mut self.buf_*
    // Layout: 6 regions of `region_size` each (input, x, temp, conv_out, head, scratch)
    work: Vec<f32>,
    region_size: usize,
}

impl WaveNet {
    fn from_config(cfg: &WaveNetConfig, reader: &mut WeightReader) -> Self {
        let mut layer_arrays = Vec::new();
        for la_cfg in &cfg.layers {
            layer_arrays.push(WaveNetLayerArray::from_config(la_cfg, reader));
        }

        let mut head_layers = Vec::new();
        if let Some(ref head_cfg) = cfg.head {
            let act = Activation::from_str(&head_cfg.activation);
            let mut in_ch = head_cfg.in_channels;
            for i in 0..head_cfg.num_layers {
                let out_ch = if i == head_cfg.num_layers - 1 { head_cfg.out_channels } else { head_cfg.channels };
                let w = reader.read_to_vec(out_ch * in_ch);
                let b = reader.read_to_vec(out_ch);
                head_layers.push((act, w, b, out_ch, in_ch));
                in_ch = out_ch;
            }
        }

        let head_scale = if reader.data.len() > reader.offset {
            reader.read(1)[0]
        } else {
            cfg.head_scale
        };

        let mut receptive_field = 1usize;
        for la in &layer_arrays {
            receptive_field += la.receptive_field - 1;
        }

        // Compute work pool size: 6 regions, each big enough for worst case
        let max_l = 4096 + receptive_field;
        let max_ch = layer_arrays.iter().map(|la| la.channels).max().unwrap_or(16);
        let max_mid = max_ch * 2; // gated doubles channels
        let max_kernel = layer_arrays.iter()
            .flat_map(|la| la.layers.iter().map(|l| l.kernel_size))
            .max().unwrap_or(3);
        let region_size = (max_mid * max_l).max(max_ch * max_kernel * max_l);

        WaveNet {
            layer_arrays, head_layers, head_scale, receptive_field,
            history: Vec::new(),
            work: vec![0.0; region_size * 6],
            region_size,
        }
    }

    /// Process a mono buffer. Maintains per-channel state (history).
    pub fn process_buffer(&mut self, input: &[f32], output: &mut [f32], channel: usize) {
        let n = input.len();
        if n == 0 { return; }

        // Validate buffer sizes to prevent work pool overflow
        let rf = self.receptive_field;
        let hist_len = rf - 1;
        let full_len = hist_len + n;
        if full_len > self.region_size || output.len() < n {
            // Input too large for work buffer or output too small — passthrough
            let copy_len = n.min(output.len());
            output[..copy_len].copy_from_slice(&input[..copy_len]);
            return;
        }

        // Ensure per-channel history exists
        while self.history.len() <= channel {
            self.history.push(vec![0.0; self.receptive_field - 1]);
        }

        let rs = self.region_size;

        // Work pool regions (non-overlapping slices of self.work):
        // Region 0: input/condition buffer
        // Region 1: x buffer (current layer state)
        // Region 2: x buffer (alternate for ping-pong)
        // Region 3: conv output / temp
        // Region 4: head accumulator
        // Region 5: scratch (im2col)

        // Build full input in region 0: [history | new_samples]
        self.work[..hist_len].copy_from_slice(&self.history[channel]);
        self.work[hist_len..full_len].copy_from_slice(input);

        let mut x_off = 0usize;        // region offset of current x
        let mut x_len = full_len;
        let mut x_ch = 1usize;
        let mut head_acc_len = 0usize;
        let mut head_ch = 0usize;
        let mut x_region = 1usize;      // ping-pong between regions 1 and 2

        for la_idx in 0..self.layer_arrays.len() {
            let la_rf = self.layer_arrays[la_idx].receptive_field;
            let la_channels = self.layer_arrays[la_idx].channels;
            let _la_input_size = self.layer_arrays[la_idx].input_size;
            let out_length = x_len.saturating_sub(la_rf - 1);
            if out_length == 0 { break; }

            // Rechannel: x → region x_region
            let x_src_off = if x_ch == 1 && x_off == 0 { 0 } else { x_region * rs };
            let x_dst_off = x_region * rs;
            {
                let (src, dst) = if x_src_off < x_dst_off {
                    let (a, b) = self.work.split_at_mut(x_dst_off);
                    (&a[x_src_off..x_src_off + x_ch * x_len], &mut b[..la_channels * x_len])
                } else if x_src_off == x_dst_off {
                    // Same region — need temp copy
                    let mut temp = vec![0.0f32; x_ch * x_len];
                    temp.copy_from_slice(&self.work[x_src_off..x_src_off + x_ch * x_len]);
                    conv1x1(&temp, x_ch, x_len, &self.layer_arrays[la_idx].rechannel_w, la_channels, &[],
                            &mut self.work[x_dst_off..x_dst_off + la_channels * x_len]);
                    // Skip the normal conv1x1 below
                    x_ch = la_channels; // update for layer processing
                    // Process layers in this array
                    self._process_layer_array(la_idx, out_length, &mut x_len, &mut x_ch,
                                              x_region, full_len, &mut head_acc_len, &mut head_ch);
                    x_region = if x_region == 1 { 2 } else { 1 };
                    continue;
                } else {
                    let (a, b) = self.work.split_at_mut(x_src_off);
                    (&b[..x_ch * x_len], &mut a[x_dst_off..x_dst_off + la_channels * x_len])
                };
                conv1x1(src, x_ch, x_len, &self.layer_arrays[la_idx].rechannel_w, la_channels, &[], dst);
            }

            x_ch = la_channels;

            self._process_layer_array(la_idx, out_length, &mut x_len, &mut x_ch,
                                      x_region, full_len, &mut head_acc_len, &mut head_ch);

            x_off = x_region * rs;
            x_region = if x_region == 1 { 2 } else { 1 };
        }

        // Apply head_scale
        let head_off = 4 * rs;
        let out_len = head_acc_len.min(n);
        for i in 0..head_ch * out_len {
            self.work[head_off + i] *= self.head_scale;
        }

        // Head layers (post-processing MLP)
        let temp_off = 3 * rs;
        for (act, w, b, out_c, in_c) in &self.head_layers {
            let count = *in_c * out_len;
            match act {
                Activation::Tanh => {
                    let mut temp = vec![0.0f32; count];
                    accel::vec_tanh(&self.work[head_off..head_off + count], &mut temp);
                    self.work[head_off..head_off + count].copy_from_slice(&temp);
                }
                Activation::Sigmoid => {
                    let mut temp = vec![0.0f32; count];
                    accel::vec_sigmoid(&self.work[head_off..head_off + count], &mut temp);
                    self.work[head_off..head_off + count].copy_from_slice(&temp);
                }
                Activation::Relu => {
                    for i in 0..count {
                        self.work[head_off + i] = reluf(self.work[head_off + i]);
                    }
                }
            }
            // conv1x1 from head region → temp region
            let (head_slice, temp_slice) = if head_off < temp_off {
                let (a, b) = self.work.split_at_mut(temp_off);
                (&a[head_off..head_off + *in_c * out_len], &mut b[..*out_c * out_len])
            } else {
                let (a, b) = self.work.split_at_mut(head_off);
                (&b[..*in_c * out_len], &mut a[temp_off..temp_off + *out_c * out_len])
            };
            conv1x1(head_slice, *in_c, out_len, w, *out_c, b, temp_slice);
            // Copy back to head
            self.work.copy_within(temp_off..temp_off + *out_c * out_len, head_off);
        }

        // Copy output (first channel of head, last n samples)
        let copy_len = out_len.min(n);
        output[..copy_len].copy_from_slice(&self.work[head_off + out_len - copy_len..head_off + out_len]);
        for i in copy_len..n {
            output[i] = 0.0;
        }

        // Update history
        let hist = &mut self.history[channel];
        hist.clear();
        hist.extend_from_slice(&self.work[full_len - hist_len..full_len]);
    }

    fn _process_layer_array(
        &mut self,
        la_idx: usize,
        out_length: usize,
        x_len: &mut usize,
        x_ch: &mut usize,
        x_region: usize,
        full_len: usize,
        head_acc_len: &mut usize,
        head_ch: &mut usize,
    ) {
        let rs = self.region_size;
        let x_off = x_region * rs;
        let conv_off = 3 * rs;  // region 3: conv output
        let head_off = 4 * rs;  // region 4: head accumulator
        let scratch_off = 5 * rs; // region 5: im2col scratch

        let num_layers = self.layer_arrays[la_idx].layers.len();

        for l_idx in 0..num_layers {
            let dilation = self.layer_arrays[la_idx].layers[l_idx].dilation;
            let kernel_size = self.layer_arrays[la_idx].layers[l_idx].kernel_size;
            let mid_ch = self.layer_arrays[la_idx].layers[l_idx].mid_ch;
            let channels = self.layer_arrays[la_idx].layers[l_idx].channels;
            let gated = self.layer_arrays[la_idx].layers[l_idx].gated;
            let activation = self.layer_arrays[la_idx].layers[l_idx].activation;
            let condition_size = self.layer_arrays[la_idx].layers[l_idx].condition_size;
            let has_layer1x1 = self.layer_arrays[la_idx].layers[l_idx].has_layer1x1;
            let has_head1x1 = self.layer_arrays[la_idx].layers[l_idx].has_head1x1;
            let head1x1_out = self.layer_arrays[la_idx].layers[l_idx].head1x1_out;

            let curr_x_len = *x_len;
            let l_out = curr_x_len.saturating_sub((kernel_size - 1) * dilation);
            if l_out == 0 { break; }

            // Dilated conv: work[x_off..] → work[conv_off..]
            // We need non-overlapping mutable slices for conv1d
            {
                // Split work into parts we need
                let conv_w = &self.layer_arrays[la_idx].layers[l_idx].conv_w;
                let conv_b = &self.layer_arrays[la_idx].layers[l_idx].conv_b;

                // Copy x data to a temp location if needed to avoid aliasing
                // Since x_off and conv_off and scratch_off are all different regions, we can use raw pointers
                let work_ptr = self.work.as_mut_ptr();
                unsafe {
                    let x_slice = core::slice::from_raw_parts(work_ptr.add(x_off), *x_ch * curr_x_len);
                    let out_slice = core::slice::from_raw_parts_mut(work_ptr.add(conv_off), mid_ch * l_out);
                    let scratch_slice = core::slice::from_raw_parts_mut(work_ptr.add(scratch_off), *x_ch * kernel_size * l_out);
                    conv1d(x_slice, *x_ch, curr_x_len, conv_w, mid_ch, kernel_size, conv_b, dilation, out_slice, scratch_slice);
                }
            }

            // Add condition mix (condition = original input in region 0)
            {
                let mix_w = &self.layer_arrays[la_idx].layers[l_idx].mix_w;
                let cond_len = full_len.min(l_out);
                for i in 0..mid_ch {
                    for j in 0..cond_len {
                        let cond_j = full_len - cond_len + j;
                        let mut mix_val = 0.0f32;
                        for c in 0..condition_size {
                            mix_val += mix_w[i * condition_size + c] * self.work[c * full_len + cond_j];
                        }
                        self.work[conv_off + i * l_out + j] += mix_val;
                    }
                }
            }

            // Activation (in-place in conv region)
            if gated {
                let half = channels * l_out;
                // Use scratch region as temp for tanh/sigmoid results
                let work_ptr = self.work.as_mut_ptr();
                unsafe {
                    let tanh_in = core::slice::from_raw_parts(work_ptr.add(conv_off), half);
                    let sig_in = core::slice::from_raw_parts(work_ptr.add(conv_off + half), half);
                    let tanh_out = core::slice::from_raw_parts_mut(work_ptr.add(scratch_off), half);
                    let sig_out = core::slice::from_raw_parts_mut(work_ptr.add(scratch_off + half), half);
                    // Vectorized tanh and sigmoid
                    accel::vec_tanh(tanh_in, tanh_out);
                    accel::vec_sigmoid(sig_in, sig_out);
                    // Element-wise multiply: result → conv region first half
                    let result = core::slice::from_raw_parts_mut(work_ptr.add(conv_off), half);
                    accel::vec_mul(tanh_out, sig_out, result);
                }
            } else {
                let count = channels * l_out;
                match activation {
                    Activation::Tanh => {
                        let mut temp = vec![0.0f32; count];
                        accel::vec_tanh(&self.work[conv_off..conv_off + count], &mut temp);
                        self.work[conv_off..conv_off + count].copy_from_slice(&temp);
                    }
                    Activation::Sigmoid => {
                        let mut temp = vec![0.0f32; count];
                        accel::vec_sigmoid(&self.work[conv_off..conv_off + count], &mut temp);
                        self.work[conv_off..conv_off + count].copy_from_slice(&temp);
                    }
                    Activation::Relu => {
                        for i in 0..count {
                            self.work[conv_off + i] = reluf(self.work[conv_off + i]);
                        }
                    }
                }
            }

            // Residual: x[:, -l_out:] + layer_out → x[:, :l_out]
            if has_layer1x1 {
                let l1x1_w = &self.layer_arrays[la_idx].layers[l_idx].l1x1_w;
                // l1x1 output goes to scratch region temporarily
                let work_ptr = self.work.as_mut_ptr();
                unsafe {
                    let act_slice = core::slice::from_raw_parts(work_ptr.add(conv_off), channels * l_out);
                    let l1x1_out = core::slice::from_raw_parts_mut(work_ptr.add(scratch_off), channels * l_out);
                    conv1x1(act_slice, channels, l_out, l1x1_w, channels, &[], l1x1_out);
                    // residual = x[:, -l_out:] + l1x1_out → x[:, :l_out]
                    for c in 0..channels {
                        let x_offset = curr_x_len - l_out;
                        for j in 0..l_out {
                            let x_val = *work_ptr.add(x_off + c * curr_x_len + x_offset + j);
                            *work_ptr.add(x_off + c * l_out + j) = x_val + l1x1_out[c * l_out + j];
                        }
                    }
                }
            } else {
                for c in 0..channels {
                    let x_offset = curr_x_len - l_out;
                    for j in 0..l_out {
                        let x_val = self.work[x_off + c * curr_x_len + x_offset + j];
                        let act_val = self.work[conv_off + c * l_out + j];
                        self.work[x_off + c * l_out + j] = x_val + act_val;
                    }
                }
            }

            // Head accumulation
            let h_data_ch;
            let h_data_off;
            if has_head1x1 {
                let h1x1_w = &self.layer_arrays[la_idx].layers[l_idx].h1x1_w;
                h_data_ch = head1x1_out;
                // h1x1 output → end of scratch
                let h1x1_off = scratch_off + channels * l_out;
                let work_ptr = self.work.as_mut_ptr();
                unsafe {
                    let act_slice = core::slice::from_raw_parts(work_ptr.add(conv_off), channels * l_out);
                    let h1x1_out = core::slice::from_raw_parts_mut(work_ptr.add(h1x1_off), head1x1_out * l_out);
                    conv1x1(act_slice, channels, l_out, h1x1_w, head1x1_out, &[], h1x1_out);
                }
                h_data_off = h1x1_off;
            } else {
                h_data_ch = channels;
                h_data_off = conv_off;
            }

            if *head_acc_len == 0 {
                *head_ch = h_data_ch;
                *head_acc_len = out_length;
                for c in 0..h_data_ch {
                    for j in 0..out_length {
                        let src_j = l_out - out_length + j;
                        self.work[head_off + c * out_length + j] = self.work[h_data_off + c * l_out + src_j];
                    }
                }
            } else {
                for c in 0..h_data_ch {
                    for j in 0..out_length {
                        let src_j = l_out - out_length + j;
                        self.work[head_off + c * out_length + j] += self.work[h_data_off + c * l_out + src_j];
                    }
                }
            }

            *x_len = l_out;
            *x_ch = channels;
        }

        // Head rechannel
        if *head_acc_len > 0 {
            let la_head_size = self.layer_arrays[la_idx].head_size;
            let la_skip_ch = self.layer_arrays[la_idx].skip_ch;
            let head_rechannel_w = &self.layer_arrays[la_idx].head_rechannel_w;
            let head_rechannel_b = &self.layer_arrays[la_idx].head_rechannel_b;
            let tmp_size = la_head_size * *head_acc_len;
            let work_ptr = self.work.as_mut_ptr();
            unsafe {
                let head_src = core::slice::from_raw_parts(work_ptr.add(head_off), la_skip_ch * *head_acc_len);
                let tmp = core::slice::from_raw_parts_mut(work_ptr.add(conv_off), tmp_size);
                conv1x1(head_src, la_skip_ch, *head_acc_len, head_rechannel_w, la_head_size, head_rechannel_b, tmp);
                // Copy back to head region
                core::ptr::copy_nonoverlapping(work_ptr.add(conv_off), work_ptr.add(head_off), tmp_size);
            }
            *head_ch = la_head_size;
        }
    }

    /// Reset per-channel state.
    pub fn reset(&mut self) {
        self.history.clear();
    }
}

// ---------------------------------------------------------------------------
// LSTM
// ---------------------------------------------------------------------------

struct LstmCell {
    hidden_size: usize,
    w: Vec<f32>,          // [4H × (in_sz + H)]
    b: Vec<f32>,          // [4H]
    initial_h: Vec<f32>,  // [H]
    initial_c: Vec<f32>,  // [H]
    h: Vec<f32>,          // [H]
    c: Vec<f32>,          // [H]
    input_size: usize,
}

impl LstmCell {
    fn reset(&mut self) {
        self.h.copy_from_slice(&self.initial_h);
        self.c.copy_from_slice(&self.initial_c);
    }

    fn process(&mut self, x: &[f32], ifgo_scratch: &mut [f32]) -> &[f32] {
        let h = self.hidden_size;
        let xh_len = self.input_size + h;

        // ifgo = W @ [x; h] + b
        for i in 0..4 * h {
            let mut sum = self.b[i];
            let w_row = i * xh_len;
            for j in 0..self.input_size {
                sum += self.w[w_row + j] * x[j];
            }
            for j in 0..h {
                sum += self.w[w_row + self.input_size + j] * self.h[j];
            }
            ifgo_scratch[i] = sum;
        }

        for j in 0..h {
            let i_gate = sigmoidf(ifgo_scratch[j]);
            let f_gate = sigmoidf(ifgo_scratch[h + j]);
            let g_gate = tanhf(ifgo_scratch[2 * h + j]);
            let o_gate = sigmoidf(ifgo_scratch[3 * h + j]);
            self.c[j] = f_gate * self.c[j] + i_gate * g_gate;
            self.h[j] = o_gate * tanhf(self.c[j]);
        }

        &self.h
    }
}

/// LSTM NAM model.
pub struct Lstm {
    cells: Vec<LstmCell>,
    head_w: Vec<f32>,  // [out_ch × H]
    head_b: Vec<f32>,  // [out_ch]
    hidden_size: usize,
    // Per-channel state: cloned cells
    channel_cells: Vec<Vec<LstmCell>>,
    // Pre-allocated scratch for gate computation
    ifgo_scratch: Vec<f32>,
}

fn clone_cells(cells: &[LstmCell]) -> Vec<LstmCell> {
    cells.iter().map(|c| LstmCell {
        hidden_size: c.hidden_size,
        w: c.w.clone(), b: c.b.clone(),
        initial_h: c.initial_h.clone(), initial_c: c.initial_c.clone(),
        h: c.initial_h.clone(), c: c.initial_c.clone(),
        input_size: c.input_size,
    }).collect()
}

fn process_lstm_cells(
    cells: &mut [LstmCell], input: &[f32], output: &mut [f32],
    head_w: &[f32], head_b: &[f32], hidden_size: usize,
    ifgo_scratch: &mut [f32],
) {
    let mut x_buf = vec![0.0f32; hidden_size.max(1)];

    for t in 0..input.len() {
        x_buf[0] = input[t];
        let mut x_len = 1;

        for cell in cells.iter_mut() {
            let result = cell.process(&x_buf[..x_len], ifgo_scratch);
            x_buf[..result.len()].copy_from_slice(result);
            x_len = result.len();
        }

        // Linear head: out = head_w @ h + head_b
        let mut val = head_b[0];
        for j in 0..hidden_size {
            val += head_w[j] * x_buf[j];
        }
        output[t] = val;
    }
}

impl Lstm {
    fn from_config(cfg: &LstmConfig, reader: &mut WeightReader) -> Self {
        let h = cfg.hidden_size;
        let mut cells = Vec::new();

        for i in 0..cfg.num_layers {
            let in_sz = if i == 0 { cfg.input_size } else { h };
            let w = reader.read_to_vec(4 * h * (in_sz + h));
            let b = reader.read_to_vec(4 * h);
            let initial_h = reader.read_to_vec(h);
            let initial_c = reader.read_to_vec(h);
            cells.push(LstmCell {
                hidden_size: h, w, b,
                initial_h: initial_h.clone(), initial_c: initial_c.clone(),
                h: initial_h, c: initial_c,
                input_size: in_sz,
            });
        }

        let out_ch = cfg.out_channels;
        let head_w = reader.read_to_vec(out_ch * h);
        let head_b = reader.read_to_vec(out_ch);

        Lstm {
            cells, head_w, head_b, hidden_size: h,
            channel_cells: Vec::new(),
            ifgo_scratch: vec![0.0; 4 * h],
        }
    }

    /// Process a mono buffer. Per-sample loop through stacked LSTM cells.
    pub fn process_buffer(&mut self, input: &[f32], output: &mut [f32], channel: usize) {
        // Ensure per-channel cells exist for channels > 0
        while self.channel_cells.len() < channel {
            self.channel_cells.push(clone_cells(&self.cells));
        }

        let h = self.hidden_size;
        let head_w = &self.head_w;
        let head_b = &self.head_b;
        let ifgo = &mut self.ifgo_scratch;

        if channel == 0 {
            process_lstm_cells(&mut self.cells, input, output, head_w, head_b, h, ifgo);
        } else {
            let cells = &mut self.channel_cells[channel - 1];
            process_lstm_cells(cells, input, output, head_w, head_b, h, ifgo);
        }
    }

    /// Reset all per-channel state.
    pub fn reset(&mut self) {
        for cell in &mut self.cells {
            cell.reset();
        }
        self.channel_cells.clear();
    }
}

// ---------------------------------------------------------------------------
// Config parsing (minimal JSON parser for known schema)
// ---------------------------------------------------------------------------

struct WaveNetLayerArrayConfig {
    input_size: usize,
    condition_size: usize,
    channels: usize,
    head_size: usize,
    kernel_size: usize,
    dilations: Vec<usize>,
    activation: alloc::string::String,
    gated: bool,
    head_bias: bool,
    has_layer1x1: bool,
    has_head1x1: bool,
    head1x1_out: usize,
}

struct WaveNetHeadConfig {
    in_channels: usize,
    channels: usize,
    out_channels: usize,
    num_layers: usize,
    activation: alloc::string::String,
}

struct WaveNetConfig {
    layers: Vec<WaveNetLayerArrayConfig>,
    head: Option<WaveNetHeadConfig>,
    head_scale: f32,
}

struct LstmConfig {
    input_size: usize,
    hidden_size: usize,
    num_layers: usize,
    out_channels: usize,
}

// Simple JSON value parser for the config object
fn parse_json_value(s: &str) -> JsonValue {
    let s = s.trim();
    if s.starts_with('{') {
        parse_json_object(s)
    } else if s.starts_with('[') {
        parse_json_array(s)
    } else if s.starts_with('"') {
        let end = s[1..].find('"').unwrap_or(0) + 1;
        JsonValue::Str(alloc::string::String::from(&s[1..end]))
    } else if s == "true" {
        JsonValue::Bool(true)
    } else if s == "false" {
        JsonValue::Bool(false)
    } else if s == "null" {
        JsonValue::Null
    } else {
        // Number
        if let Ok(i) = s.parse::<i64>() {
            JsonValue::Int(i)
        } else if let Ok(f) = s.parse::<f64>() {
            JsonValue::Float(f)
        } else {
            JsonValue::Null
        }
    }
}

enum JsonValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(alloc::string::String),
    Array(Vec<JsonValue>),
    Object(Vec<(alloc::string::String, JsonValue)>),
}

impl JsonValue {
    fn as_int(&self) -> Option<i64> {
        match self {
            JsonValue::Int(i) => Some(*i),
            JsonValue::Float(f) => Some(*f as i64),
            _ => None,
        }
    }
    fn as_usize(&self) -> usize {
        self.as_int().unwrap_or(0) as usize
    }
    fn as_f32(&self) -> f32 {
        match self {
            JsonValue::Int(i) => *i as f32,
            JsonValue::Float(f) => *f as f32,
            _ => 0.0,
        }
    }
    fn as_bool(&self) -> bool {
        match self {
            JsonValue::Bool(b) => *b,
            _ => false,
        }
    }
    fn as_str(&self) -> &str {
        match self {
            JsonValue::Str(s) => s,
            _ => "",
        }
    }
    fn get(&self, key: &str) -> &JsonValue {
        match self {
            JsonValue::Object(pairs) => {
                for (k, v) in pairs {
                    if k == key { return v; }
                }
                &JSON_NULL
            }
            _ => &JSON_NULL,
        }
    }
    fn as_array(&self) -> &[JsonValue] {
        match self {
            JsonValue::Array(a) => a,
            _ => &[],
        }
    }
}

static JSON_NULL: JsonValue = JsonValue::Null;

fn find_matching_brace(s: &str, open: char, close: char) -> usize {
    let mut depth = 0;
    let mut in_string = false;
    let mut escape = false;
    for (i, ch) in s.char_indices() {
        if escape {
            escape = false;
            continue;
        }
        if ch == '\\' && in_string {
            escape = true;
            continue;
        }
        if ch == '"' {
            in_string = !in_string;
            continue;
        }
        if in_string { continue; }
        if ch == open { depth += 1; }
        if ch == close {
            depth -= 1;
            if depth == 0 { return i; }
        }
    }
    s.len()
}

fn parse_json_object(s: &str) -> JsonValue {
    let s = s.trim();
    if !s.starts_with('{') { return JsonValue::Null; }
    let end = find_matching_brace(s, '{', '}');
    let inner = &s[1..end];
    let mut pairs = Vec::new();
    let mut pos = 0;
    let bytes = inner.as_bytes();

    while pos < bytes.len() {
        // Find key
        while pos < bytes.len() && bytes[pos] != b'"' { pos += 1; }
        if pos >= bytes.len() { break; }
        pos += 1; // skip opening quote
        let key_start = pos;
        while pos < bytes.len() && bytes[pos] != b'"' { pos += 1; }
        let key = alloc::string::String::from(&inner[key_start..pos]);
        pos += 1; // skip closing quote

        // Skip colon
        while pos < bytes.len() && bytes[pos] != b':' { pos += 1; }
        pos += 1;

        // Find value
        while pos < bytes.len() && (bytes[pos] == b' ' || bytes[pos] == b'\n' || bytes[pos] == b'\r' || bytes[pos] == b'\t') { pos += 1; }

        let val_str = &inner[pos..];
        let (value, consumed) = parse_json_value_with_len(val_str);
        pairs.push((key, value));
        pos += consumed;

        // Skip comma
        while pos < bytes.len() && (bytes[pos] == b',' || bytes[pos] == b' ' || bytes[pos] == b'\n' || bytes[pos] == b'\r' || bytes[pos] == b'\t') {
            pos += 1;
        }
    }

    JsonValue::Object(pairs)
}

fn parse_json_array(s: &str) -> JsonValue {
    let s = s.trim();
    if !s.starts_with('[') { return JsonValue::Null; }
    let end = find_matching_brace(s, '[', ']');
    let inner = &s[1..end];
    let mut items = Vec::new();
    let mut pos = 0;

    while pos < inner.len() {
        while pos < inner.len() {
            let b = inner.as_bytes()[pos];
            if b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' || b == b',' {
                pos += 1;
            } else {
                break;
            }
        }
        if pos >= inner.len() { break; }

        let val_str = &inner[pos..];
        let (value, consumed) = parse_json_value_with_len(val_str);
        items.push(value);
        pos += consumed;
    }

    JsonValue::Array(items)
}

fn parse_json_value_with_len(s: &str) -> (JsonValue, usize) {
    let s_trimmed = s.trim_start();
    let skip = s.len() - s_trimmed.len();

    if s_trimmed.starts_with('{') {
        let end = find_matching_brace(s_trimmed, '{', '}') + 1;
        (parse_json_object(&s_trimmed[..end]), skip + end)
    } else if s_trimmed.starts_with('[') {
        let end = find_matching_brace(s_trimmed, '[', ']') + 1;
        (parse_json_array(&s_trimmed[..end]), skip + end)
    } else if s_trimmed.starts_with('"') {
        let end = s_trimmed[1..].find('"').unwrap_or(0) + 2;
        let val = alloc::string::String::from(&s_trimmed[1..end - 1]);
        (JsonValue::Str(val), skip + end)
    } else if s_trimmed.starts_with("true") {
        (JsonValue::Bool(true), skip + 4)
    } else if s_trimmed.starts_with("false") {
        (JsonValue::Bool(false), skip + 5)
    } else if s_trimmed.starts_with("null") {
        (JsonValue::Null, skip + 4)
    } else {
        // Number: find end
        let mut end = 0;
        for (i, b) in s_trimmed.bytes().enumerate() {
            if b == b',' || b == b'}' || b == b']' || b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' {
                break;
            }
            end = i + 1;
        }
        let num_str = &s_trimmed[..end];
        let val = if let Ok(i) = num_str.parse::<i64>() {
            JsonValue::Int(i)
        } else if let Ok(f) = num_str.parse::<f64>() {
            JsonValue::Float(f)
        } else {
            JsonValue::Null
        };
        (val, skip + end)
    }
}

fn parse_wavenet_config(json: &JsonValue) -> WaveNetConfig {
    let mut layers = Vec::new();
    for la_val in json.get("layers").as_array() {
        let l1x1 = la_val.get("layer1x1");
        let h1x1 = la_val.get("head1x1");
        let has_layer1x1 = match l1x1 {
            JsonValue::Object(_) => l1x1.get("active").as_bool() || matches!(l1x1.get("active"), JsonValue::Null),
            _ => true,
        };
        let has_head1x1 = match h1x1 {
            JsonValue::Object(_) => h1x1.get("active").as_bool(),
            _ => false,
        };
        let head1x1_out = match h1x1 {
            JsonValue::Object(_) => {
                let v = h1x1.get("out_channels").as_usize();
                if v == 0 { 1 } else { v }
            }
            _ => 1,
        };

        let dilations: Vec<usize> = la_val.get("dilations").as_array().iter()
            .map(|v| v.as_usize())
            .collect();

        layers.push(WaveNetLayerArrayConfig {
            input_size: la_val.get("input_size").as_usize(),
            condition_size: la_val.get("condition_size").as_usize(),
            channels: la_val.get("channels").as_usize(),
            head_size: la_val.get("head_size").as_usize(),
            kernel_size: { let v = la_val.get("kernel_size").as_usize(); if v == 0 { 3 } else { v } },
            dilations,
            activation: alloc::string::String::from(la_val.get("activation").as_str()),
            gated: la_val.get("gated").as_bool(),
            head_bias: la_val.get("head_bias").as_bool(),
            has_layer1x1, has_head1x1, head1x1_out,
        });
    }

    let head = {
        let h = json.get("head");
        match h {
            JsonValue::Object(_) => Some(WaveNetHeadConfig {
                in_channels: { let v = h.get("in_channels").as_usize(); if v == 0 {
                    layers.last().map(|l| l.head_size).unwrap_or(1)
                } else { v } },
                channels: h.get("channels").as_usize(),
                out_channels: { let v = h.get("out_channels").as_usize(); if v == 0 { 1 } else { v } },
                num_layers: h.get("num_layers").as_usize(),
                activation: {
                    let s = h.get("activation").as_str();
                    alloc::string::String::from(if s.is_empty() { "ReLU" } else { s })
                },
            }),
            _ => None,
        }
    };

    WaveNetConfig {
        layers,
        head,
        head_scale: { let v = json.get("head_scale").as_f32(); if v == 0.0 { 1.0 } else { v } },
    }
}

fn parse_lstm_config(json: &JsonValue) -> LstmConfig {
    LstmConfig {
        input_size: { let v = json.get("input_size").as_usize(); if v == 0 { 1 } else { v } },
        hidden_size: json.get("hidden_size").as_usize(),
        num_layers: { let v = json.get("num_layers").as_usize(); if v == 0 { 1 } else { v } },
        out_channels: { let v = json.get("out_channels").as_usize(); if v == 0 { 1 } else { v } },
    }
}

// ---------------------------------------------------------------------------
// NamModel — public enum dispatching WaveNet / Lstm
// ---------------------------------------------------------------------------

/// A loaded NAM model (WaveNet or LSTM).
pub enum NamModel {
    WaveNet(WaveNet),
    Lstm(Lstm),
}

impl NamModel {
    /// Deserialize from the binary protocol injected by the host.
    ///
    /// Binary format:
    /// ```text
    /// [4 bytes] architecture: u32 (0=WaveNet, 1=LSTM)
    /// [4 bytes] sample_rate: f32
    /// [4 bytes] config_json_len: u32
    /// [N bytes] config JSON string
    /// [4 bytes] weight_count: u32
    /// [M×4 bytes] weights as f32 little-endian
    /// ```
    pub fn from_binary(data: &[u8]) -> Option<Self> {
        if data.len() < 16 { return None; }

        let arch = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
        let _sample_rate = f32::from_le_bytes([data[4], data[5], data[6], data[7]]);
        let config_len = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;

        if data.len() < 12 + config_len + 4 { return None; }

        let config_json = core::str::from_utf8(&data[12..12 + config_len]).ok()?;
        let config = parse_json_value(config_json);

        let weight_offset = 12 + config_len;
        let weight_count = u32::from_le_bytes([
            data[weight_offset], data[weight_offset + 1],
            data[weight_offset + 2], data[weight_offset + 3],
        ]) as usize;

        let weights_start = weight_offset + 4;
        if data.len() < weights_start + weight_count * 4 { return None; }

        let mut weights = vec![0.0f32; weight_count];
        for i in 0..weight_count {
            let off = weights_start + i * 4;
            weights[i] = f32::from_le_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]);
        }

        let mut reader = WeightReader::new(&weights);

        match arch {
            0 => {
                let cfg = parse_wavenet_config(&config);
                Some(NamModel::WaveNet(WaveNet::from_config(&cfg, &mut reader)))
            }
            1 => {
                let cfg = parse_lstm_config(&config);
                Some(NamModel::Lstm(Lstm::from_config(&cfg, &mut reader)))
            }
            _ => None,
        }
    }

    /// Process a mono audio buffer.
    pub fn process_buffer(&mut self, input: &[f32], output: &mut [f32], channel: usize) {
        match self {
            NamModel::WaveNet(w) => w.process_buffer(input, output, channel),
            NamModel::Lstm(l) => l.process_buffer(input, output, channel),
        }
    }

    /// Reset all per-channel state.
    pub fn reset(&mut self) {
        match self {
            NamModel::WaveNet(w) => w.reset(),
            NamModel::Lstm(l) => l.reset(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wavenet_validation_oversized_passthrough() {
        // Test the validation guard directly: full_len > region_size → passthrough
        // Uses a tiny region_size (10) to trigger the guard with a small input.
        let mut wn = WaveNet {
            layer_arrays: Vec::new(),
            head_layers: Vec::new(),
            head_scale: 1.0,
            receptive_field: 1,  // hist_len = 0, full_len = n
            history: Vec::new(),
            work: vec![0.0; 10 * 6],  // region_size = 10
            region_size: 10,
        };

        // Input of 20 samples: full_len = 0 + 20 = 20 > region_size (10) → passthrough
        let input = vec![0.7f32; 20];
        let mut output = vec![0.0f32; 20];
        wn.process_buffer(&input, &mut output, 0);
        assert_eq!(output[0], 0.7, "Oversized input should passthrough");
        assert_eq!(output[19], 0.7, "Oversized input should passthrough to end");
    }

    #[test]
    fn test_wavenet_validation_output_too_small() {
        let mut wn = WaveNet {
            layer_arrays: Vec::new(),
            head_layers: Vec::new(),
            head_scale: 1.0,
            receptive_field: 1,
            history: Vec::new(),
            work: vec![0.0; 1000 * 6],
            region_size: 1000,
        };

        // Output smaller than input → passthrough up to output length
        let input = vec![0.7f32; 64];
        let mut output = vec![0.0f32; 32];
        wn.process_buffer(&input, &mut output, 0);
        assert_eq!(output[0], 0.7, "Should copy input to output up to output length");
        assert_eq!(output[31], 0.7);
    }

    #[test]
    fn test_from_binary_rejects_too_small() {
        let tiny = vec![0u8; 8]; // Less than minimum 16 bytes
        assert!(NamModel::from_binary(&tiny).is_none());
    }

    #[test]
    fn test_from_binary_rejects_invalid_arch() {
        let mut binary = Vec::new();
        binary.extend_from_slice(&99u32.to_le_bytes()); // invalid arch
        binary.extend_from_slice(&48000.0f32.to_bits().to_le_bytes());
        binary.extend_from_slice(&2u32.to_le_bytes()); // config_len
        binary.extend_from_slice(b"{}");
        binary.extend_from_slice(&0u32.to_le_bytes()); // 0 weights
        assert!(NamModel::from_binary(&binary).is_none());
    }
}
