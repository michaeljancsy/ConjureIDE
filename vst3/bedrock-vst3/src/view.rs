//! Vision's editor window.
//!
//! Repaints are driven by a UI-thread timer. On Linux that must be the host's `IRunLoop` — the
//! VST3 Linux specification forbids a plugin from running its own event loop or timer — so the
//! view registers an `ITimerHandler` with the run loop it gets from `IPlugFrame`. Other
//! platforms hand us a timer directly (see [`crate::platform::start_ticker`]).

use std::ffi::{c_void, CStr};
use std::sync::{Arc, Mutex};

use vst3::{Class, ComPtr, ComRef, ComWrapper, Steinberg::Linux::*, Steinberg::*};

use bedrock_core::registry::TrackState;
use bedrock_core::render::{render, Canvas, Scene, TrackView};

use crate::platform::{self, Backend, Ticker, PLATFORM_TYPE};
use crate::vision::VisionShared;

/// Editor size when the host has no saved size for us.
const DEFAULT_W: i32 = 1000;
const DEFAULT_H: i32 = 560;

/// Below this the axis labels stop fitting.
const MIN_W: i32 = 340;
const MIN_H: i32 = 200;

/// ~30 fps. The analyser only produces a frame every 21 ms, so drawing faster would repaint
/// identical pixels.
const FRAME_INTERVAL_MS: u32 = 33;

struct ViewInner {
    width: i32,
    height: i32,
    canvas: Canvas,
    backend: Option<Box<dyn Backend>>,
    ticker: Option<Box<dyn Ticker>>,
}

/// The part of the view the timer needs to reach. Shared so the timer target can hold it
/// without owning the COM object.
pub struct ViewState {
    shared: Arc<VisionShared>,
    inner: Mutex<ViewInner>,
}

impl ViewState {
    /// Rebuilds the scene from the live track table and blits it.
    fn redraw(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let ViewInner {
            width,
            height,
            canvas,
            backend,
            ..
        } = &mut *inner;

        let Some(backend) = backend.as_mut() else {
            return;
        };
        canvas.resize((*width).max(1) as usize, (*height).max(1) as usize);

        // Copy the track list out under the registry lock and release it before rendering:
        // the hub's reader threads are writing to it continuously, and rasterising a whole
        // frame while holding it would stall every connected Track.
        let snapshot: Vec<TrackState> = self
            .shared
            .with_hub(|hub| {
                hub.registry()
                    .lock()
                    .map(|r| r.ordered().into_iter().cloned().collect())
                    .unwrap_or_default()
            })
            .unwrap_or_default();

        let error = self.shared.error();
        let views: Vec<TrackView> = snapshot
            .iter()
            .map(|t| TrackView {
                name: &t.name,
                frame: &t.frame,
                daw_color: t.daw_color,
                has_frame: t.has_frame,
            })
            .collect();

        let scene = Scene {
            tracks: &views,
            palette: self.shared.palette(),
            fill_opacity: self.shared.fill_opacity(),
            show_legend: self.shared.show_legend(),
            show_grid: self.shared.show_grid(),
            realm: self.shared.realm(),
            error: error.as_deref(),
        };
        render(canvas, &scene);
        backend.present(canvas);
    }
}

/// COM object registered with the host run loop; forwards ticks to the view.
struct TimerTarget {
    state: Arc<ViewState>,
}

impl Class for TimerTarget {
    type Interfaces = (ITimerHandler,);
}

impl ITimerHandlerTrait for TimerTarget {
    unsafe fn onTimer(&self) {
        self.state.redraw();
    }
}

pub struct PlugView {
    state: Arc<ViewState>,
    /// Held so the run loop's timer registration stays alive, and so we can unregister.
    run_loop: Mutex<Option<(ComPtr<IRunLoop>, ComPtr<ITimerHandler>)>>,
    frame: Mutex<Option<ComPtr<IPlugFrame>>>,
}

impl Class for PlugView {
    type Interfaces = (IPlugView,);
}

impl PlugView {
    pub fn new(shared: Arc<VisionShared>) -> PlugView {
        PlugView {
            state: Arc::new(ViewState {
                shared,
                inner: Mutex::new(ViewInner {
                    width: DEFAULT_W,
                    height: DEFAULT_H,
                    canvas: Canvas::new(DEFAULT_W as usize, DEFAULT_H as usize),
                    backend: None,
                    ticker: None,
                }),
            }),
            run_loop: Mutex::new(None),
            frame: Mutex::new(None),
        }
    }

    fn start_timer(&self) {
        // Linux: the host owns the event loop, so the timer must be registered with it.
        let mut slot = self.run_loop.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_some() {
            return;
        }

        let run_loop = {
            let frame = self.frame.lock().unwrap_or_else(|e| e.into_inner());
            frame.as_ref().and_then(|f| f.cast::<IRunLoop>())
        };

        if let Some(run_loop) = run_loop {
            let target = ComWrapper::new(TimerTarget {
                state: Arc::clone(&self.state),
            });
            if let Some(handler) = target.to_com_ptr::<ITimerHandler>() {
                let res = unsafe {
                    run_loop.registerTimer(handler.as_ptr(), FRAME_INTERVAL_MS as u64)
                };
                if res == kResultOk {
                    *slot = Some((run_loop, handler));
                    return;
                }
            }
        }

        // Everywhere else, use the platform's own UI-thread timer.
        let state = Arc::clone(&self.state);
        if let Some(ticker) = platform::start_ticker(
            FRAME_INTERVAL_MS,
            Box::new(move || state.redraw()),
        ) {
            self.state
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .ticker = Some(ticker);
        }
    }

    fn stop_timer(&self) {
        if let Some((run_loop, handler)) = self
            .run_loop
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            unsafe {
                run_loop.unregisterTimer(handler.as_ptr());
            }
        }
        self.state
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ticker = None;
    }
}

impl IPlugViewTrait for PlugView {
    unsafe fn isPlatformTypeSupported(&self, r#type: FIDString) -> tresult {
        if r#type.is_null() || PLATFORM_TYPE.is_empty() {
            return kResultFalse;
        }
        match CStr::from_ptr(r#type).to_str() {
            Ok(t) if t == PLATFORM_TYPE => kResultTrue,
            _ => kResultFalse,
        }
    }

    unsafe fn attached(&self, parent: *mut c_void, r#type: FIDString) -> tresult {
        if self.isPlatformTypeSupported(r#type) != kResultTrue || parent.is_null() {
            return kResultFalse;
        }

        let (w, h) = {
            let inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
            (inner.width, inner.height)
        };

        let Some(backend) = platform::create(parent, w, h) else {
            // Refusing to attach makes the host fall back to its generic parameter editor,
            // which is a far better outcome than an empty window.
            return kResultFalse;
        };

        self.state
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .backend = Some(backend);

        self.start_timer();
        self.state.redraw();
        kResultOk
    }

    unsafe fn removed(&self) -> tresult {
        self.stop_timer();
        self.state
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .backend = None;
        kResultOk
    }

    unsafe fn onWheel(&self, _distance: f32) -> tresult {
        kResultFalse
    }

    unsafe fn onKeyDown(&self, _key: char16, _code: int16, _modifiers: int16) -> tresult {
        kResultFalse
    }

    unsafe fn onKeyUp(&self, _key: char16, _code: int16, _modifiers: int16) -> tresult {
        kResultFalse
    }

    unsafe fn getSize(&self, size: *mut ViewRect) -> tresult {
        if size.is_null() {
            return kInvalidArgument;
        }
        let inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
        let size = &mut *size;
        size.left = 0;
        size.top = 0;
        size.right = inner.width;
        size.bottom = inner.height;
        kResultOk
    }

    unsafe fn onSize(&self, new_size: *mut ViewRect) -> tresult {
        if new_size.is_null() {
            return kInvalidArgument;
        }
        let r = &*new_size;
        let w = (r.right - r.left).max(MIN_W);
        let h = (r.bottom - r.top).max(MIN_H);
        {
            let mut inner = self.state.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.width = w;
            inner.height = h;
            if let Some(b) = inner.backend.as_mut() {
                b.resize(w, h);
            }
        }
        self.state.redraw();
        kResultOk
    }

    unsafe fn onFocus(&self, _state: TBool) -> tresult {
        kResultOk
    }

    unsafe fn setFrame(&self, frame: *mut IPlugFrame) -> tresult {
        *self.frame.lock().unwrap_or_else(|e| e.into_inner()) =
            ComRef::from_raw(frame).map(|f| f.to_com_ptr());
        kResultOk
    }

    unsafe fn canResize(&self) -> tresult {
        // The whole point of the graph is fitting the shape you give it.
        kResultTrue
    }

    unsafe fn checkSizeConstraint(&self, rect: *mut ViewRect) -> tresult {
        if rect.is_null() {
            return kInvalidArgument;
        }
        let rect = &mut *rect;
        if rect.right - rect.left < MIN_W {
            rect.right = rect.left + MIN_W;
        }
        if rect.bottom - rect.top < MIN_H {
            rect.bottom = rect.top + MIN_H;
        }
        kResultTrue
    }
}
