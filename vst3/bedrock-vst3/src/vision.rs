//! **Bedrock Vision** — the single instance that collects every Track and draws the graph.
//!
//! Vision owns the hub for its realm. Audio passes through untouched; the plugin exists on a
//! track only so the host gives it a processing slot and an editor.

use std::sync::{Arc, Mutex};

use vst3::{uid, Class, ComWrapper, Steinberg::Vst::*, Steinberg::*};

use bedrock_core::hub::Hub;
use bedrock_core::palette::Palette;

use crate::boilerplate::PluginCommon;
use crate::common::{block, passthrough, Param, ParamValues};
use crate::impl_plugin;
use crate::view::PlugView;

pub const P_REALM: usize = 0;
pub const P_PALETTE: usize = 1;
pub const P_FILL: usize = 2;
pub const P_LEGEND: usize = 3;
pub const P_GRID: usize = 4;

static PALETTE_NAMES: &[&str] = &[
    "Spectrum",
    "Aurora",
    "Ember",
    "Ice",
    "Mono",
    "DAW Colors",
];

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
        title: "Palette",
        units: "",
        min: 0.0,
        max: 5.0,
        default_plain: 0.0,
        step_count: 5,
        value_strings: Some(PALETTE_NAMES),
        is_toggle: false,
    },
    Param {
        id: 2,
        title: "Fill",
        units: "",
        min: 0.0,
        max: 1.0,
        default_plain: 0.14,
        step_count: 0,
        value_strings: None,
        is_toggle: false,
    },
    Param {
        id: 3,
        title: "Legend",
        units: "",
        min: 0.0,
        max: 1.0,
        default_plain: 1.0,
        step_count: 1,
        value_strings: None,
        is_toggle: true,
    },
    Param {
        id: 4,
        title: "Grid",
        units: "",
        min: 0.0,
        max: 1.0,
        default_plain: 1.0,
        step_count: 1,
        value_strings: None,
        is_toggle: true,
    },
];

/// The hub and its status, shared with the view.
pub struct VisionShared {
    pub params: Arc<ParamValues>,
    hub: Mutex<Option<Hub>>,
    /// Set when the realm couldn't be bound; the view shows this instead of a graph.
    error: Mutex<Option<String>>,
}

impl VisionShared {
    /// Binds `realm`, replacing any hub already running.
    ///
    /// The old hub is dropped *before* the new one is created: on the same realm they would
    /// contend for the same port, and the new bind would fail against our own listener.
    pub fn bind(&self, realm: u16) {
        let mut hub = self.hub.lock().unwrap_or_else(|e| e.into_inner());
        let mut error = self.error.lock().unwrap_or_else(|e| e.into_inner());

        if hub.as_ref().is_some_and(|h| h.realm() == realm) {
            return;
        }
        *hub = None;

        match Hub::start(realm) {
            Ok(h) => {
                *hub = Some(h);
                *error = None;
            }
            Err(e) => {
                *error = Some(e.to_string());
            }
        }
    }

    pub fn unbind(&self) {
        *self.hub.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.error.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    pub fn error(&self) -> Option<String> {
        self.error.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Runs `f` against the live hub, if there is one.
    pub fn with_hub<R>(&self, f: impl FnOnce(&Hub) -> R) -> Option<R> {
        let hub = self.hub.lock().unwrap_or_else(|e| e.into_inner());
        hub.as_ref().map(f)
    }

    pub fn realm(&self) -> u16 {
        self.params.get_int(P_REALM) as u16
    }

    pub fn palette(&self) -> Palette {
        Palette::from_index(self.params.get_int(P_PALETTE) as usize)
    }

    pub fn fill_opacity(&self) -> f32 {
        self.params.get_plain(P_FILL) as f32
    }

    pub fn show_legend(&self) -> bool {
        self.params.get_bool(P_LEGEND)
    }

    pub fn show_grid(&self) -> bool {
        self.params.get_bool(P_GRID)
    }
}

pub struct Vision {
    pub common: PluginCommon,
    shared: Arc<VisionShared>,
}

impl Class for Vision {
    type Interfaces = (
        IComponent,
        IAudioProcessor,
        IEditController,
        IProcessContextRequirements,
    );
}

impl Vision {
    pub const CID: TUID = uid(0xB3D40C4B, 0x71A4402E, 0x8F1C6D22, 0x54A10002);

    pub fn new() -> Vision {
        let common = PluginCommon::new(ParamValues::new(PARAMS));
        let shared = Arc::new(VisionShared {
            params: Arc::clone(&common.params),
            hub: Mutex::new(None),
            error: Mutex::new(None),
        });
        Vision { common, shared }
    }

    fn on_setup(&self) {}

    /// The hub is bound on activation rather than at construction so that a host scanning the
    /// plugin — which instantiates it without activating — doesn't briefly seize realm 0 out
    /// from under a Vision that is actually running.
    fn on_active(&self, active: bool) {
        if active {
            self.shared.bind(self.shared.realm());
        } else {
            self.shared.unbind();
        }
    }

    fn on_param_changed(&self, index: usize) {
        if index == P_REALM {
            // Only re-bind if we already hold a hub; otherwise wait for activation.
            let running = self.shared.with_hub(|_| ()).is_some();
            if running || self.shared.error().is_some() {
                self.shared.bind(self.shared.realm());
            }
        }
    }

    fn process_block(&self, data: &mut ProcessData) {
        unsafe {
            self.common.params.apply_changes(data.inputParameterChanges);
            if let Some(b) = block(data) {
                passthrough(&b);
            }
        }
        // Tracks whose host stopped calling them keep their socket open but stop sending;
        // sweeping here costs nothing and keeps them from lingering on the graph.
        self.shared.with_hub(|h| h.evict_stale());
    }

    fn create_view(&self) -> *mut IPlugView {
        // Opening the editor is a clear signal the user wants to see tracks, so make sure the
        // realm is bound even if the host hasn't activated us.
        if self.shared.with_hub(|_| ()).is_none() && self.shared.error().is_none() {
            self.shared.bind(self.shared.realm());
        }
        match ComWrapper::new(PlugView::new(Arc::clone(&self.shared)))
            .to_com_ptr::<IPlugView>()
        {
            Some(ptr) => ptr.into_raw(),
            None => std::ptr::null_mut(),
        }
    }
}

impl_plugin!(Vision, "Bedrock Vision");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_names_match_the_core_palette_order() {
        // The host shows these strings in a dropdown; if they drift out of order with
        // Palette::ALL the user picks one scheme and gets another.
        assert_eq!(PALETTE_NAMES.len(), Palette::ALL.len());
        for (i, name) in PALETTE_NAMES.iter().enumerate() {
            assert_eq!(*name, Palette::ALL[i].name(), "palette {i} is out of order");
        }
    }

    #[test]
    fn palette_parameter_reaches_every_scheme() {
        let p = PARAMS[P_PALETTE];
        for (i, expected) in Palette::ALL.iter().enumerate() {
            let normalized = p.to_normalized(i as f64);
            let chosen = Palette::from_index(p.to_plain(normalized) as usize);
            assert_eq!(chosen, *expected);
        }
    }

    #[test]
    fn defaults_are_the_ones_the_renderer_expects() {
        let v = ParamValues::new(PARAMS);
        assert_eq!(Palette::from_index(v.get_int(P_PALETTE) as usize), Palette::DEFAULT);
        assert!((v.get_plain(P_FILL) - 0.14).abs() < 0.01);
        assert!(v.get_bool(P_LEGEND));
        assert!(v.get_bool(P_GRID));
    }

    #[test]
    fn rebinding_to_the_same_realm_keeps_the_existing_hub() {
        let params = Arc::new(ParamValues::new(PARAMS));
        let shared = VisionShared {
            params,
            hub: Mutex::new(None),
            error: Mutex::new(None),
        };
        // Realm chosen to avoid the ranges used by bedrock_core's own hub tests.
        shared.bind(90);
        assert!(shared.error().is_none(), "first bind should succeed");
        shared.bind(90);
        assert!(
            shared.error().is_none(),
            "re-binding the same realm must not fight itself for the port"
        );
        assert_eq!(shared.with_hub(|h| h.realm()), Some(90));
    }

    #[test]
    fn changing_realm_moves_the_hub() {
        let params = Arc::new(ParamValues::new(PARAMS));
        let shared = VisionShared {
            params,
            hub: Mutex::new(None),
            error: Mutex::new(None),
        };
        shared.bind(91);
        assert_eq!(shared.with_hub(|h| h.realm()), Some(91));
        shared.bind(92);
        assert_eq!(shared.with_hub(|h| h.realm()), Some(92));
        assert!(shared.error().is_none());
    }

    #[test]
    fn a_realm_already_taken_surfaces_an_error() {
        let occupier = Hub::start(93).expect("occupy the realm");
        let params = Arc::new(ParamValues::new(PARAMS));
        let shared = VisionShared {
            params,
            hub: Mutex::new(None),
            error: Mutex::new(None),
        };
        shared.bind(93);
        assert!(
            shared.error().is_some(),
            "a second Vision on a taken realm should report why it has no graph"
        );
        drop(occupier);
    }
}
