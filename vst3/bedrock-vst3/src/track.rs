//! **Bedrock Track** — the analysis insert that goes on every channel you want to see.
//!
//! It passes audio through untouched, sums it to mono, runs the FFT, and publishes a spectrum
//! frame to whichever Vision owns its realm. It also listens for the host's channel-context
//! info, which is where the DAW's own track name and colour come from.

use std::cell::UnsafeCell;
use std::ptr;

use vst3::{uid, Class, ComRef, Steinberg::Vst::ChannelContext::*, Steinberg::Vst::*, Steinberg::*};

use bedrock_core::analyzer::Analyzer;
use bedrock_core::hub::TrackLink;
use bedrock_core::palette::Rgb;
use bedrock_core::protocol::Frame;

use crate::boilerplate::PluginCommon;
use crate::common::{self, block, next_track_id, passthrough, sum_to_mono, Param, ParamValues};
use crate::impl_plugin;

const P_REALM: usize = 0;
const P_SLOT: usize = 1;
const P_ENABLED: usize = 2;

static PARAMS: &[Param] = &[
    Param {
        id: 0,
        title: "Realm",
        units: "",
        min: 0.0,
        max: (bedrock_core::NUM_REALMS - 1) as f64,
        default_plain: 0.0,
        step_count: (bedrock_core::NUM_REALMS - 1) as i32,
        value_strings: None,
        is_toggle: false,
    },
    Param {
        id: 1,
        title: "Slot",
        units: "",
        min: 0.0,
        max: 127.0,
        default_plain: 0.0,
        step_count: 127,
        value_strings: None,
        is_toggle: false,
    },
    Param {
        id: 2,
        title: "Send",
        units: "",
        min: 0.0,
        max: 1.0,
        default_plain: 1.0,
        step_count: 1,
        value_strings: None,
        is_toggle: true,
    },
];

/// Name and colour the host reported for this channel, via the channel-context API.
/// Written only from the UI thread, read whenever we re-announce ourselves.
#[derive(Default)]
struct ChannelInfo {
    name: std::sync::Mutex<String>,
    color: std::sync::Mutex<Option<Rgb>>,
}

impl ChannelInfo {
    fn name(&self) -> String {
        self.name.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn color(&self) -> Option<Rgb> {
        *self.color.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Audio-thread-only scratch. Guarded by the VST3 contract, not by a lock.
///
/// The host guarantees `process` is never concurrent with `setupProcessing` or `setActive`, and
/// never re-entrant. That is what makes an `UnsafeCell` correct here — a mutex would be a lie
/// (the audio thread must not block) and a `RefCell` would only add a branch to say the same.
struct AudioState {
    analyzer: Analyzer,
    mono: Vec<f32>,
}

pub struct Track {
    pub common: PluginCommon,
    audio: UnsafeCell<AudioState>,
    /// Created with the plugin and kept for its whole life, so a Track inserted before Vision
    /// exists keeps dialling and connects the moment Vision appears.
    link: TrackLink,
    channel: ChannelInfo,
}

impl Class for Track {
    type Interfaces = (
        IComponent,
        IAudioProcessor,
        IEditController,
        IProcessContextRequirements,
        IInfoListener,
    );
}

impl Track {
    pub const CID: TUID = uid(0xB3D40C4B, 0x71A4402E, 0x8F1C6D22, 0x54A10001);

    pub fn new() -> Track {
        let params = ParamValues::new(PARAMS);
        let realm = params.get_int(P_REALM) as u16;
        let link = TrackLink::new(next_track_id(), realm);
        // Until the host tells us the channel name, show something better than a blank row.
        link.set_identity("", params.get_int(P_SLOT) as u16, None);

        Track {
            common: PluginCommon::new(params),
            audio: UnsafeCell::new(AudioState {
                analyzer: Analyzer::new(48_000.0),
                mono: Vec::with_capacity(4096),
            }),
            link,
            channel: ChannelInfo::default(),
        }
    }

    fn on_setup(&self) {
        // Safety: the host does not call setupProcessing concurrently with process.
        let audio = unsafe { &mut *self.audio.get() };
        audio.analyzer.set_sample_rate(self.common.sample_rate());
        audio
            .mono
            .reserve(self.common.max_frames().max(0) as usize);
    }

    fn on_active(&self, active: bool) {
        if active {
            // Safety: setActive is never concurrent with process.
            unsafe { &mut *self.audio.get() }.analyzer.reset();
        }
        self.push_identity();
    }

    fn on_param_changed(&self, index: usize) {
        match index {
            P_REALM => self.link.set_realm(self.common.params.get_int(P_REALM) as u16),
            P_SLOT => self.push_identity(),
            _ => {}
        }
    }

    /// Re-sends name, slot and colour. Cheap, and idempotent on Vision's side.
    fn push_identity(&self) {
        self.link.set_identity(
            &self.channel.name(),
            self.common.params.get_int(P_SLOT) as u16,
            self.channel.color(),
        );
    }

    fn process_block(&self, data: &mut ProcessData) {
        unsafe {
            self.common.params.apply_changes(data.inputParameterChanges);

            let Some(b) = block(data) else {
                return;
            };
            passthrough(&b);

            if !self.common.params.get_bool(P_ENABLED) {
                return;
            }

            // Safety: exclusive to the audio thread, per the VST3 threading contract.
            let audio = &mut *self.audio.get();
            sum_to_mono(&b, &mut audio.mono);

            let link = &self.link;
            let mono = std::mem::take(&mut audio.mono);
            audio.analyzer.push(&mono, |spectrum| {
                link.publish(Frame::from_spectrum(spectrum));
            });
            audio.mono = mono;
        }
    }

    fn create_view(&self) -> *mut IPlugView {
        // Track has nothing to show beyond its three parameters; the host's generic editor is
        // a better fit than a window of our own.
        ptr::null_mut()
    }
}

impl_plugin!(Track, "Bedrock Track");

// ---------------------------------------------------------------------------------------------
// Channel context — the DAW's own track name and colour
// ---------------------------------------------------------------------------------------------

impl IInfoListenerTrait for Track {
    unsafe fn setChannelContextInfos(&self, list: *mut IAttributeList) -> tresult {
        let Some(list) = ComRef::from_raw(list) else {
            return kResultFalse;
        };

        let mut buf = [0 as TChar; 128];
        if list.getString(
            kChannelNameKey,
            buf.as_mut_ptr(),
            (buf.len() * std::mem::size_of::<TChar>()) as u32,
        ) == kResultOk
        {
            let name = common::read_wstring(buf.as_ptr(), buf.len());
            *self.channel.name.lock().unwrap_or_else(|e| e.into_inner()) = name;
        }

        let mut color: i64 = 0;
        if list.getInt(kChannelColorKey, &mut color as *mut i64) == kResultOk {
            *self.channel.color.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(Rgb::from_vst3_color_spec(color as u32));
        }

        self.push_identity();
        kResultOk
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realm_parameter_covers_every_realm() {
        let p = PARAMS[P_REALM];
        assert_eq!(p.to_plain(0.0) as u16, 0);
        assert_eq!(p.to_plain(1.0) as u16, bedrock_core::NUM_REALMS - 1);
    }

    #[test]
    fn send_defaults_to_on() {
        let v = ParamValues::new(PARAMS);
        assert!(v.get_bool(P_ENABLED), "a freshly inserted Track should publish");
    }

    #[test]
    fn slot_covers_a_realistic_track_count() {
        let p = PARAMS[P_SLOT];
        assert_eq!(p.to_plain(1.0) as u16, 127);
    }
}
