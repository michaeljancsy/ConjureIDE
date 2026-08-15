//! Getting a pixel buffer onto the screen inside the host's window.
//!
//! Each platform hands a plugin a different kind of parent handle — an X11 window id, an
//! `NSView*`, an `HWND` — and wants the pixels delivered a different way. The renderer doesn't
//! care about any of that, so everything platform-specific lives behind [`Backend`]: make a
//! child surface inside the parent, and blit a [`Canvas`] into it.

use std::ffi::c_void;

use bedrock_core::render::Canvas;

#[cfg(target_os = "linux")]
mod x11;

#[cfg(any(target_os = "macos", feature = "typecheck-all"))]
mod macos;

#[cfg(any(target_os = "windows", feature = "typecheck-all"))]
mod win32;

/// A child surface inside the host's window.
pub trait Backend {
    /// Called when the host resizes the view.
    fn resize(&mut self, width: i32, height: i32);

    /// Copies `canvas` to the screen.
    fn present(&mut self, canvas: &Canvas);
}

/// The VST3 platform-type string this build can attach to.
pub const PLATFORM_TYPE: &str = if cfg!(target_os = "linux") {
    "X11EmbedWindowID"
} else if cfg!(target_os = "macos") {
    "NSView"
} else if cfg!(target_os = "windows") {
    "HWND"
} else {
    ""
};

/// Creates a child surface inside `parent`.
///
/// Returns `None` if the surface can't be created, in which case the view refuses to attach and
/// the host falls back to its own generic parameter editor — a graceful degradation rather than
/// a blank window.
#[allow(unused_variables)]
pub fn create(parent: *mut c_void, width: i32, height: i32) -> Option<Box<dyn Backend>> {
    #[cfg(target_os = "linux")]
    {
        return x11::X11Backend::new(parent, width, height)
            .map(|b| Box::new(b) as Box<dyn Backend>);
    }
    #[cfg(target_os = "macos")]
    {
        return macos::MacBackend::new(parent, width, height)
            .map(|b| Box::new(b) as Box<dyn Backend>);
    }
    #[cfg(target_os = "windows")]
    {
        return win32::Win32Backend::new(parent, width, height)
            .map(|b| Box::new(b) as Box<dyn Backend>);
    }
    #[allow(unreachable_code)]
    None
}

/// A repeating callback on the UI thread. Dropping it stops the timer.
pub trait Ticker {}

/// Starts a UI-thread timer, where the platform provides one we may use directly.
///
/// Linux returns `None` on purpose: the VST3 Linux specification requires plugins to use the
/// host's `IRunLoop` rather than starting any timer or event loop of their own, so the view
/// registers an `ITimerHandler` there instead.
#[allow(unused_variables)]
pub fn start_ticker(interval_ms: u32, callback: Box<dyn Fn()>) -> Option<Box<dyn Ticker>> {
    #[cfg(target_os = "macos")]
    {
        return macos::start_ticker(interval_ms, callback);
    }
    #[cfg(target_os = "windows")]
    {
        return win32::start_ticker(interval_ms, callback);
    }
    #[allow(unreachable_code)]
    None
}
