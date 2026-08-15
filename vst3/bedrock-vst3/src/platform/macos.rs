//! macOS backend.
//!
//! The host hands us an `NSView*` to live inside. We add a layer-backed child view and, each
//! frame, wrap the canvas in a `CGImage` and hand it to the layer as its contents. That avoids
//! subclassing `NSView` to override `drawRect:` — no runtime class needs to be built, and the
//! compositor does the blit.
//!
//! The Objective-C runtime is called through hand-written FFI rather than a binding crate. It
//! is a handful of `objc_msgSend` calls, and doing it directly keeps this buildable with no
//! dependency beyond the system frameworks.

use std::ffi::{c_char, c_void, CString};

use bedrock_core::render::Canvas;

use super::{Backend, Ticker};

type Id = *mut c_void;
type Sel = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

impl CGRect {
    fn new(x: f64, y: f64, w: f64, h: f64) -> CGRect {
        CGRect {
            origin: CGPoint { x, y },
            size: CGSize {
                width: w,
                height: h,
            },
        }
    }
}

#[cfg_attr(target_os = "macos", link(name = "objc", kind = "dylib"))]
extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    fn objc_msgSend();
}

#[cfg_attr(target_os = "macos", link(name = "AppKit", kind = "framework"))]
extern "C" {}

#[cfg_attr(target_os = "macos", link(name = "QuartzCore", kind = "framework"))]
extern "C" {}

#[cfg_attr(target_os = "macos", link(name = "CoreGraphics", kind = "framework"))]
extern "C" {
    fn CGColorSpaceCreateDeviceRGB() -> *mut c_void;
    fn CGColorSpaceRelease(space: *mut c_void);
    fn CGDataProviderCreateWithData(
        info: *mut c_void,
        data: *const c_void,
        size: usize,
        release: Option<extern "C" fn(*mut c_void, *const c_void, usize)>,
    ) -> *mut c_void;
    fn CGDataProviderRelease(provider: *mut c_void);
    #[allow(clippy::too_many_arguments)]
    fn CGImageCreate(
        width: usize,
        height: usize,
        bits_per_component: usize,
        bits_per_pixel: usize,
        bytes_per_row: usize,
        space: *mut c_void,
        bitmap_info: u32,
        provider: *mut c_void,
        decode: *const f64,
        should_interpolate: bool,
        intent: i32,
    ) -> *mut c_void;
    fn CGImageRelease(image: *mut c_void);
}

#[cfg_attr(target_os = "macos", link(name = "CoreFoundation", kind = "framework"))]
extern "C" {
    fn CFRunLoopGetMain() -> *mut c_void;
    fn CFRunLoopAddTimer(rl: *mut c_void, timer: *mut c_void, mode: *const c_void);
    fn CFRunLoopTimerCreate(
        allocator: *const c_void,
        fire_date: f64,
        interval: f64,
        flags: u32,
        order: isize,
        callout: extern "C" fn(*mut c_void, *mut c_void),
        context: *mut CFRunLoopTimerContext,
    ) -> *mut c_void;
    fn CFRunLoopTimerInvalidate(timer: *mut c_void);
    fn CFAbsoluteTimeGetCurrent() -> f64;
    fn CFRelease(cf: *const c_void);
    static kCFRunLoopCommonModes: *const c_void;
}

#[repr(C)]
struct CFRunLoopTimerContext {
    version: isize,
    info: *mut c_void,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
}

/// `kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little`, which is exactly how a
/// little-endian `u32` of `0x00RRGGBB` sits in memory.
const BITMAP_INFO: u32 = 6 | (2 << 12);

fn sel(name: &str) -> Sel {
    let c = CString::new(name).expect("selector name");
    // Safety: the runtime copies the string; it need not outlive the call.
    unsafe { sel_registerName(c.as_ptr()) }
}

fn class(name: &str) -> Id {
    let c = CString::new(name).expect("class name");
    unsafe { objc_getClass(c.as_ptr()) }
}

// `objc_msgSend` must be called through a pointer cast to the exact signature of the method
// being sent; the ABI depends on the argument types, so there is no single correct prototype.
unsafe fn send0(obj: Id, s: Sel) -> Id {
    let f: extern "C" fn(Id, Sel) -> Id = std::mem::transmute(objc_msgSend as *const ());
    f(obj, s)
}

unsafe fn send1<A>(obj: Id, s: Sel, a: A) -> Id {
    let f: extern "C" fn(Id, Sel, A) -> Id = std::mem::transmute(objc_msgSend as *const ());
    f(obj, s, a)
}

unsafe fn send1_void<A>(obj: Id, s: Sel, a: A) {
    let f: extern "C" fn(Id, Sel, A) = std::mem::transmute(objc_msgSend as *const ());
    f(obj, s, a)
}

unsafe fn send0_void(obj: Id, s: Sel) {
    let f: extern "C" fn(Id, Sel) = std::mem::transmute(objc_msgSend as *const ());
    f(obj, s)
}

pub struct MacBackend {
    view: Id,
    layer: Id,
    /// The pixels handed to the current `CGImage`. Held so the data provider stays valid until
    /// the next frame replaces it.
    buffer: Vec<u32>,
    width: i32,
    height: i32,
}

impl MacBackend {
    pub fn new(parent: *mut c_void, width: i32, height: i32) -> Option<MacBackend> {
        if parent.is_null() {
            return None;
        }
        // Safety: `parent` is the NSView the host promised via kPlatformTypeNSView.
        unsafe {
            let ns_view = class("NSView");
            if ns_view.is_null() {
                return None;
            }

            let rect = CGRect::new(0.0, 0.0, width.max(1) as f64, height.max(1) as f64);
            let view = send0(ns_view, sel("alloc"));
            if view.is_null() {
                return None;
            }
            let view = send1(view, sel("initWithFrame:"), rect);
            if view.is_null() {
                return None;
            }

            send1_void(view, sel("setWantsLayer:"), true as i8);
            send1_void(parent as Id, sel("addSubview:"), view);

            let layer = send0(view, sel("layer"));
            if layer.is_null() {
                return None;
            }
            // Stretch the image over the layer rather than tiling it when sizes disagree
            // mid-resize.
            let gravity = ns_string("resize");
            if !gravity.is_null() {
                send1_void(layer, sel("setContentsGravity:"), gravity);
            }

            Some(MacBackend {
                view,
                layer,
                buffer: Vec::new(),
                width: width.max(1),
                height: height.max(1),
            })
        }
    }
}

/// Builds an autoreleased `NSString`.
fn ns_string(s: &str) -> Id {
    let c = match CString::new(s) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };
    unsafe {
        let cls = class("NSString");
        if cls.is_null() {
            return std::ptr::null_mut();
        }
        send1(cls, sel("stringWithUTF8String:"), c.as_ptr())
    }
}

impl Backend for MacBackend {
    fn resize(&mut self, width: i32, height: i32) {
        self.width = width.max(1);
        self.height = height.max(1);
        // Safety: `view` is retained by its superview for as long as we hold it.
        unsafe {
            send1_void(
                self.view,
                sel("setFrame:"),
                CGRect::new(0.0, 0.0, self.width as f64, self.height as f64),
            );
        }
    }

    fn present(&mut self, canvas: &Canvas) {
        if canvas.width == 0 || canvas.height == 0 {
            return;
        }
        self.buffer.clear();
        self.buffer.extend_from_slice(&canvas.pixels);

        let bytes = self.buffer.len() * 4;
        // Safety: every Core Graphics object created here is released on this path, and the
        // pixel data outlives the CGImage because `self.buffer` is only replaced next frame.
        unsafe {
            let space = CGColorSpaceCreateDeviceRGB();
            if space.is_null() {
                return;
            }
            let provider = CGDataProviderCreateWithData(
                std::ptr::null_mut(),
                self.buffer.as_ptr() as *const c_void,
                bytes,
                None,
            );
            if provider.is_null() {
                CGColorSpaceRelease(space);
                return;
            }

            let image = CGImageCreate(
                canvas.width,
                canvas.height,
                8,
                32,
                canvas.width * 4,
                space,
                BITMAP_INFO,
                provider,
                std::ptr::null(),
                false,
                0,
            );

            if !image.is_null() {
                // Without this the layer animates every contents change, which turns a 30 fps
                // graph into a cross-fading smear.
                let transaction = class("CATransaction");
                if !transaction.is_null() {
                    send0_void(transaction, sel("begin"));
                    send1_void(transaction, sel("setDisableActions:"), true as i8);
                }
                send1_void(self.layer, sel("setContents:"), image);
                if !transaction.is_null() {
                    send0_void(transaction, sel("commit"));
                }
                CGImageRelease(image);
            }

            CGDataProviderRelease(provider);
            CGColorSpaceRelease(space);
        }
    }
}

impl Drop for MacBackend {
    fn drop(&mut self) {
        // Safety: removing the view from its superview releases it.
        unsafe {
            if !self.view.is_null() {
                send0_void(self.view, sel("removeFromSuperview"));
                send0_void(self.view, sel("release"));
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------------------------

struct MacTicker {
    timer: *mut c_void,
    /// Owns the boxed callback the run loop calls back into.
    callback: *mut Box<dyn Fn()>,
}

impl Ticker for MacTicker {}

extern "C" fn on_timer(_timer: *mut c_void, info: *mut c_void) {
    if info.is_null() {
        return;
    }
    // Safety: `info` is the boxed callback installed in start_ticker, alive until the ticker
    // is dropped, and the timer is invalidated before that happens.
    unsafe {
        let cb = &*(info as *const Box<dyn Fn()>);
        cb();
    }
}

pub fn start_ticker(interval_ms: u32, callback: Box<dyn Fn()>) -> Option<Box<dyn Ticker>> {
    let boxed: *mut Box<dyn Fn()> = Box::into_raw(Box::new(callback));
    let interval = interval_ms as f64 / 1000.0;

    // Safety: the context lives on the stack only for the duration of the create call, which
    // copies it.
    unsafe {
        let mut context = CFRunLoopTimerContext {
            version: 0,
            info: boxed as *mut c_void,
            retain: std::ptr::null(),
            release: std::ptr::null(),
            copy_description: std::ptr::null(),
        };
        let timer = CFRunLoopTimerCreate(
            std::ptr::null(),
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0,
            on_timer,
            &mut context,
        );
        if timer.is_null() {
            drop(Box::from_raw(boxed));
            return None;
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        Some(Box::new(MacTicker {
            timer,
            callback: boxed,
        }))
    }
}

impl Drop for MacTicker {
    fn drop(&mut self) {
        // Invalidate before freeing the callback, or a pending fire would read freed memory.
        unsafe {
            if !self.timer.is_null() {
                CFRunLoopTimerInvalidate(self.timer);
                CFRelease(self.timer);
            }
            if !self.callback.is_null() {
                drop(Box::from_raw(self.callback));
            }
        }
    }
}
