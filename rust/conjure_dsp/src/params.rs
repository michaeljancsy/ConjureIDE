// Parameter addresses — must match the Swift AUParameterTree in ConjureDSPExtensionAudioUnit.swift.
// Addresses are 0-based (0–15) matching AUParameterAddress.

/// Maximum number of parameters exposed to the DAW.
pub const PARAM_COUNT: usize = 16;

/// Rich metadata for a single parameter, declared by scripts via `PARAMS` dict.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct ParamMetadata {
    /// Display name (title-cased) for the DAW/UI parameter label.
    pub name: String,
    /// Original key from the PARAMS dict (e.g., "threshold", "bit_depth").
    /// Used as the dict key when passing params to Python scripts.
    #[serde(default)]
    pub key: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub unit: String,
    /// Mapping curve: "linear" (default), "log" (exponential/logarithmic).
    /// Log curve: min * (max/min)^normalized — ideal for frequency and time params.
    #[serde(default = "default_curve")]
    pub curve: String,
}

fn default_curve() -> String {
    "linear".to_string()
}

impl ParamMetadata {
    /// Map a normalized 0–1 value to the actual parameter range.
    pub fn denormalize(&self, normalized: f32) -> f32 {
        let n = normalized.clamp(0.0, 1.0);
        if self.curve == "log" && self.min > 0.0 && self.max > 0.0 {
            // Log curve: min * (max/min)^n
            self.min * (self.max / self.min).powf(n)
        } else {
            // Linear
            self.min + n * (self.max - self.min)
        }
    }

    /// Map an actual parameter value to the normalized 0–1 range.
    pub fn normalize(&self, actual: f32) -> f32 {
        if self.curve == "log" && self.min > 0.0 && self.max > 0.0 {
            // Inverse of log curve: log(actual/min) / log(max/min)
            let ratio = (actual / self.min).max(f32::EPSILON);
            let range = (self.max / self.min).ln();
            if range.abs() < f32::EPSILON {
                return 0.0;
            }
            (ratio.ln() / range).clamp(0.0, 1.0)
        } else {
            // Linear
            let range = self.max - self.min;
            if range.abs() < f32::EPSILON {
                return 0.0;
            }
            ((actual - self.min) / range).clamp(0.0, 1.0)
        }
    }
}
