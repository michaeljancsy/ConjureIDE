//! The VST3 surface Track and Vision have in common.
//!
//! Both are single-component effects: one object implements `IComponent`, `IAudioProcessor`
//! and `IEditController` together, rather than the split processor/controller pair. That is a
//! deliberate choice here — the analyser, the network link, the host-reported channel name and
//! the view all need to see the same state, and keeping them in one object removes an entire
//! layer of inter-object message passing that would otherwise exist only to reunite them.
//!
//! Both are also pure analysis inserts: stereo in, stereo out, audio copied through untouched,
//! zero latency, no tail. Everything in this file is that shared shape; [`impl_plugin`] stamps
//! it out and leaves each plugin to write only `process_block`, `on_active` and `create_view`.

use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};
use std::sync::Arc;

use crate::common::ParamValues;

/// State every plugin keeps regardless of what it does with the audio.
pub struct PluginCommon {
    /// Shared with the view, which reads palette and layout settings straight from it.
    pub params: Arc<ParamValues>,
    /// `f32` bits.
    sample_rate: AtomicU32,
    max_frames: AtomicI32,
    input_channels: AtomicI32,
    output_channels: AtomicI32,
}

impl PluginCommon {
    pub fn new(params: ParamValues) -> PluginCommon {
        PluginCommon {
            params: Arc::new(params),
            sample_rate: AtomicU32::new(48_000f32.to_bits()),
            max_frames: AtomicI32::new(1024),
            input_channels: AtomicI32::new(2),
            output_channels: AtomicI32::new(2),
        }
    }

    pub fn sample_rate(&self) -> f32 {
        f32::from_bits(self.sample_rate.load(Ordering::Relaxed))
    }

    pub fn set_sample_rate(&self, sr: f32) {
        self.sample_rate.store(sr.to_bits(), Ordering::Relaxed);
    }

    pub fn max_frames(&self) -> i32 {
        self.max_frames.load(Ordering::Relaxed)
    }

    pub fn set_max_frames(&self, n: i32) {
        self.max_frames.store(n, Ordering::Relaxed);
    }

    pub fn input_channels(&self) -> i32 {
        self.input_channels.load(Ordering::Relaxed)
    }

    pub fn output_channels(&self) -> i32 {
        self.output_channels.load(Ordering::Relaxed)
    }

    pub fn set_channels(&self, inputs: i32, outputs: i32) {
        self.input_channels.store(inputs, Ordering::Relaxed);
        self.output_channels.store(outputs, Ordering::Relaxed);
    }
}

/// Speaker arrangements we accept. Anything else is refused so the host picks one of these.
pub fn arrangement_channels(arr: u64) -> Option<i32> {
    match arr {
        // kMono
        0x1 => Some(1),
        // kStereo
        0x3 => Some(2),
        _ => None,
    }
}

pub fn channels_to_arrangement(channels: i32) -> u64 {
    match channels {
        1 => 0x1,
        _ => 0x3,
    }
}

/// Generates the `IPluginBase`, `IComponent`, `IAudioProcessor`, `IEditController` and
/// `IProcessContextRequirements` implementations shared by both plugins.
///
/// The type must have a `common: PluginCommon` field and inherent methods:
/// `process_block(&self, &mut ProcessData)`, `on_active(&self, bool)` and
/// `create_view(&self) -> *mut IPlugView`.
#[macro_export]
macro_rules! impl_plugin {
    ($t:ty, $name:expr) => {
        impl IPluginBaseTrait for $t {
            unsafe fn initialize(&self, _context: *mut FUnknown) -> tresult {
                kResultOk
            }
            unsafe fn terminate(&self) -> tresult {
                kResultOk
            }
        }

        impl IComponentTrait for $t {
            unsafe fn getControllerClassId(&self, _class_id: *mut TUID) -> tresult {
                // Single-component effect: the host should query this same object for
                // IEditController rather than instantiating a separate one.
                kNotImplemented
            }

            unsafe fn setIoMode(&self, _mode: IoMode) -> tresult {
                kResultOk
            }

            unsafe fn getBusCount(&self, media_type: MediaType, dir: BusDirection) -> i32 {
                if media_type == MediaTypes_::kAudio as MediaType
                    && (dir == BusDirections_::kInput as BusDirection
                        || dir == BusDirections_::kOutput as BusDirection)
                {
                    1
                } else {
                    0
                }
            }

            unsafe fn getBusInfo(
                &self,
                media_type: MediaType,
                dir: BusDirection,
                index: i32,
                bus: *mut BusInfo,
            ) -> tresult {
                if media_type != MediaTypes_::kAudio as MediaType || index != 0 || bus.is_null() {
                    return kInvalidArgument;
                }
                let is_input = dir == BusDirections_::kInput as BusDirection;
                let bus = &mut *bus;
                bus.mediaType = MediaTypes_::kAudio as MediaType;
                bus.direction = dir;
                bus.channelCount = if is_input {
                    self.common.input_channels()
                } else {
                    self.common.output_channels()
                };
                $crate::common::copy_wstring(
                    if is_input { "Input" } else { "Output" },
                    &mut bus.name,
                );
                bus.busType = BusTypes_::kMain as BusType;
                bus.flags = BusInfo_::BusFlags_::kDefaultActive as u32;
                kResultOk
            }

            unsafe fn getRoutingInfo(
                &self,
                _in_info: *mut RoutingInfo,
                _out_info: *mut RoutingInfo,
            ) -> tresult {
                kNotImplemented
            }

            unsafe fn activateBus(
                &self,
                _media_type: MediaType,
                _dir: BusDirection,
                _index: i32,
                _state: TBool,
            ) -> tresult {
                kResultOk
            }

            unsafe fn setActive(&self, state: TBool) -> tresult {
                self.on_active(state != 0);
                kResultOk
            }

            unsafe fn setState(&self, state: *mut IBStream) -> tresult {
                $crate::common::load_params(&self.common.params, state)
            }

            unsafe fn getState(&self, state: *mut IBStream) -> tresult {
                $crate::common::save_params(&self.common.params, state)
            }
        }

        impl IAudioProcessorTrait for $t {
            unsafe fn setBusArrangements(
                &self,
                inputs: *mut SpeakerArrangement,
                num_ins: int32,
                outputs: *mut SpeakerArrangement,
                num_outs: int32,
            ) -> tresult {
                if num_ins != 1 || num_outs != 1 || inputs.is_null() || outputs.is_null() {
                    return kResultFalse;
                }
                let (Some(in_ch), Some(out_ch)) = (
                    $crate::boilerplate::arrangement_channels(*inputs),
                    $crate::boilerplate::arrangement_channels(*outputs),
                ) else {
                    return kResultFalse;
                };
                // An analysis insert must not change the channel count.
                if in_ch != out_ch {
                    return kResultFalse;
                }
                self.common.set_channels(in_ch, out_ch);
                kResultTrue
            }

            unsafe fn getBusArrangement(
                &self,
                dir: BusDirection,
                index: i32,
                arr: *mut SpeakerArrangement,
            ) -> tresult {
                if index != 0 || arr.is_null() {
                    return kInvalidArgument;
                }
                let channels = if dir == BusDirections_::kInput as BusDirection {
                    self.common.input_channels()
                } else {
                    self.common.output_channels()
                };
                *arr = $crate::boilerplate::channels_to_arrangement(channels);
                kResultOk
            }

            unsafe fn canProcessSampleSize(&self, size: int32) -> tresult {
                if size == SymbolicSampleSizes_::kSample32 as int32 {
                    kResultTrue
                } else {
                    kResultFalse
                }
            }

            unsafe fn getLatencySamples(&self) -> uint32 {
                // Analysis only: the audio is passed straight through.
                0
            }

            unsafe fn setupProcessing(&self, setup: *mut ProcessSetup) -> tresult {
                if setup.is_null() {
                    return kInvalidArgument;
                }
                let setup = &*setup;
                self.common.set_sample_rate(setup.sampleRate as f32);
                self.common.set_max_frames(setup.maxSamplesPerBlock);
                self.on_setup();
                kResultOk
            }

            unsafe fn setProcessing(&self, _state: TBool) -> tresult {
                kResultOk
            }

            unsafe fn process(&self, data: *mut ProcessData) -> tresult {
                if data.is_null() {
                    return kInvalidArgument;
                }
                self.process_block(&mut *data);
                kResultOk
            }

            unsafe fn getTailSamples(&self) -> uint32 {
                0
            }
        }

        impl IProcessContextRequirementsTrait for $t {
            unsafe fn getProcessContextRequirements(&self) -> u32 {
                0
            }
        }

        impl IEditControllerTrait for $t {
            unsafe fn setComponentState(&self, _state: *mut IBStream) -> tresult {
                // Single-component effect: setState already restored everything.
                kResultOk
            }

            unsafe fn setState(&self, _state: *mut IBStream) -> tresult {
                kResultOk
            }

            unsafe fn getState(&self, _state: *mut IBStream) -> tresult {
                kResultOk
            }

            unsafe fn getParameterCount(&self) -> int32 {
                self.common.params.len() as int32
            }

            unsafe fn getParameterInfo(
                &self,
                index: int32,
                info: *mut ParameterInfo,
            ) -> tresult {
                let defs = self.common.params.defs();
                let Some(p) = usize::try_from(index).ok().and_then(|i| defs.get(i)) else {
                    return kInvalidArgument;
                };
                if info.is_null() {
                    return kInvalidArgument;
                }
                p.write_info(info);
                kResultOk
            }

            unsafe fn getParamStringByValue(
                &self,
                id: ParamID,
                value_normalized: ParamValue,
                string: *mut String128,
            ) -> tresult {
                let Some(i) = self.common.params.index_of(id) else {
                    return kInvalidArgument;
                };
                if string.is_null() {
                    return kInvalidArgument;
                }
                let text = self.common.params.defs()[i].format(value_normalized);
                let dst = std::slice::from_raw_parts_mut(
                    string as *mut TChar,
                    std::mem::size_of::<String128>() / std::mem::size_of::<TChar>(),
                );
                $crate::common::copy_wstring(&text, dst);
                kResultOk
            }

            unsafe fn getParamValueByString(
                &self,
                id: ParamID,
                string: *mut TChar,
                value_normalized: *mut ParamValue,
            ) -> tresult {
                let Some(i) = self.common.params.index_of(id) else {
                    return kInvalidArgument;
                };
                if value_normalized.is_null() {
                    return kInvalidArgument;
                }
                let def = &self.common.params.defs()[i];
                let text = $crate::common::read_wstring(string, 128);
                let trimmed = text.trim();

                // Named values are matched by name first so typing "Ember" into a host's text
                // field selects that palette rather than parsing as a number.
                if let Some(names) = def.value_strings {
                    if let Some(idx) = names
                        .iter()
                        .position(|n| n.eq_ignore_ascii_case(trimmed))
                    {
                        *value_normalized = def.to_normalized(def.min + idx as f64);
                        return kResultOk;
                    }
                }
                if def.is_toggle {
                    if trimmed.eq_ignore_ascii_case("on") || trimmed.eq_ignore_ascii_case("true") {
                        *value_normalized = 1.0;
                        return kResultOk;
                    }
                    if trimmed.eq_ignore_ascii_case("off") || trimmed.eq_ignore_ascii_case("false")
                    {
                        *value_normalized = 0.0;
                        return kResultOk;
                    }
                }
                match trimmed.parse::<f64>() {
                    Ok(plain) => {
                        *value_normalized = def.to_normalized(plain);
                        kResultOk
                    }
                    Err(_) => kResultFalse,
                }
            }

            unsafe fn normalizedParamToPlain(
                &self,
                id: ParamID,
                value_normalized: ParamValue,
            ) -> ParamValue {
                match self.common.params.index_of(id) {
                    Some(i) => self.common.params.defs()[i].to_plain(value_normalized),
                    None => 0.0,
                }
            }

            unsafe fn plainParamToNormalized(
                &self,
                id: ParamID,
                plain_value: ParamValue,
            ) -> ParamValue {
                match self.common.params.index_of(id) {
                    Some(i) => self.common.params.defs()[i].to_normalized(plain_value),
                    None => 0.0,
                }
            }

            unsafe fn getParamNormalized(&self, id: ParamID) -> ParamValue {
                match self.common.params.index_of(id) {
                    Some(i) => self.common.params.get_normalized(i),
                    None => 0.0,
                }
            }

            unsafe fn setParamNormalized(&self, id: ParamID, value: ParamValue) -> tresult {
                match self.common.params.index_of(id) {
                    Some(i) => {
                        self.common.params.set_normalized(i, value);
                        self.on_param_changed(i);
                        kResultOk
                    }
                    None => kInvalidArgument,
                }
            }

            unsafe fn setComponentHandler(
                &self,
                _handler: *mut IComponentHandler,
            ) -> tresult {
                kResultOk
            }

            unsafe fn createView(&self, _name: *const std::ffi::c_char) -> *mut IPlugView {
                self.create_view()
            }
        }

        impl $t {
            /// Name reported to the host for this plugin.
            pub const DISPLAY_NAME: &'static str = $name;
        }
    };
}
