use crate::params::PARAM_GAIN;

/// Real-time audio DSP kernel.
///
/// All methods are safe for the audio render thread:
/// no allocations, no locks, no syscalls.
pub struct DSPKernel {
    sample_rate: f64,
    gain: f64,
    bypassed: bool,
    max_frames_to_render: u32,
}

impl DSPKernel {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            gain: 1.0,
            bypassed: false,
            max_frames_to_render: 1024,
        }
    }

    pub fn initialize(&mut self, _input_channels: i32, _output_channels: i32, sample_rate: f64) {
        self.sample_rate = sample_rate;
    }

    pub fn deinitialize(&mut self) {}

    pub fn set_bypassed(&mut self, bypass: bool) {
        self.bypassed = bypass;
    }

    pub fn is_bypassed(&self) -> bool {
        self.bypassed
    }

    pub fn set_parameter(&mut self, address: u64, value: f32) {
        match address {
            PARAM_GAIN => self.gain = value as f64,
            _ => {}
        }
    }

    pub fn get_parameter(&self, address: u64) -> f32 {
        match address {
            PARAM_GAIN => self.gain as f32,
            _ => 0.0,
        }
    }

    pub fn maximum_frames_to_render(&self) -> u32 {
        self.max_frames_to_render
    }

    pub fn set_maximum_frames_to_render(&mut self, max_frames: u32) {
        self.max_frames_to_render = max_frames;
    }

    /// Process audio buffers. Called from the real-time audio thread.
    ///
    /// # Safety
    /// - `input_buffers` must point to `channel_count` valid `*const f32` pointers.
    /// - `output_buffers` must point to `channel_count` valid `*mut f32` pointers.
    /// - Each channel buffer must contain at least `frame_count` samples.
    pub unsafe fn process(
        &self,
        input_buffers: *const *const f32,
        output_buffers: *const *mut f32,
        channel_count: u32,
        frame_count: u32,
    ) {
        let channel_count = channel_count as usize;
        let frame_count = frame_count as usize;
        let inputs = std::slice::from_raw_parts(input_buffers, channel_count);
        let outputs = std::slice::from_raw_parts(output_buffers, channel_count);

        if self.bypassed {
            for ch in 0..channel_count {
                let src = std::slice::from_raw_parts(inputs[ch], frame_count);
                let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                dst.copy_from_slice(src);
            }
            return;
        }

        let gain = self.gain as f32;
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            for i in 0..frame_count {
                dst[i] = src[i] * gain;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_gain() {
        let kernel = DSPKernel::new();
        assert_eq!(kernel.get_parameter(PARAM_GAIN), 1.0);
    }

    #[test]
    fn test_set_get_parameter() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);
        assert!((kernel.get_parameter(PARAM_GAIN) - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_process_applies_gain() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    #[test]
    fn test_bypass_passes_through() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);
        kernel.set_bypassed(true);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    #[test]
    fn test_unknown_parameter_returns_zero() {
        let kernel = DSPKernel::new();
        assert_eq!(kernel.get_parameter(999), 0.0);
    }
}
