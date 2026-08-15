//! X11 backend.
//!
//! The host gives us a window id to embed into. We create a child window inside it and push
//! pixels with `XPutImage`. There is deliberately no event loop here: VST3 on Linux forbids
//! plugins from running one, so repainting is driven entirely by the host's run-loop timer
//! (see `view.rs`), which also covers `Expose` — redrawing 30 times a second makes damage
//! tracking unnecessary.

use std::ffi::c_void;
use std::ptr;

use bedrock_core::render::Canvas;
use x11_dl::xlib;

use super::Backend;

/// Calls the image's own destructor, which frees both the `XImage` and the pixel buffer we
/// handed to `XCreateImage`. Xlib exposes this only through a function pointer on the struct,
/// and that pointer is optional in the bindings.
///
/// # Safety
/// `image` must be a live image created by `XCreateImage`.
unsafe fn destroy_image(image: *mut xlib::XImage) {
    if let Some(destroy) = (*image).funcs.destroy_image {
        destroy(image);
    }
}

pub struct X11Backend {
    lib: xlib::Xlib,
    display: *mut xlib::Display,
    window: xlib::Window,
    gc: xlib::GC,
    image: *mut xlib::XImage,
    /// Malloc'd because `XDestroyImage` frees it; Rust must not own this allocation.
    data: *mut u32,
    width: i32,
    height: i32,
    /// True when the server's visual is BGR rather than RGB, so channels need swapping.
    swap_rb: bool,
}

impl X11Backend {
    pub fn new(parent: *mut c_void, width: i32, height: i32) -> Option<X11Backend> {
        let lib = xlib::Xlib::open().ok()?;
        // Safety: every call below is a plain Xlib call with checked arguments.
        unsafe {
            let display = (lib.XOpenDisplay)(ptr::null());
            if display.is_null() {
                return None;
            }

            let parent_window = parent as xlib::Window;
            let mut attrs: xlib::XWindowAttributes = std::mem::zeroed();
            if (lib.XGetWindowAttributes)(display, parent_window, &mut attrs) == 0 {
                (lib.XCloseDisplay)(display);
                return None;
            }

            // Match the parent's visual and depth, or the server refuses to reparent us.
            let window = (lib.XCreateSimpleWindow)(
                display,
                parent_window,
                0,
                0,
                width.max(1) as u32,
                height.max(1) as u32,
                0,
                0,
                0,
            );
            if window == 0 {
                (lib.XCloseDisplay)(display);
                return None;
            }

            (lib.XSelectInput)(display, window, xlib::ExposureMask);
            (lib.XMapWindow)(display, window);
            (lib.XFlush)(display);

            let gc = (lib.XCreateGC)(display, window, 0, ptr::null_mut());

            let visual = attrs.visual;
            let swap_rb = !visual.is_null() && (*visual).red_mask == 0x0000_00ff;

            let mut backend = X11Backend {
                lib,
                display,
                window,
                gc,
                image: ptr::null_mut(),
                data: ptr::null_mut(),
                width: 0,
                height: 0,
                swap_rb,
            };
            backend.alloc_image(width.max(1), height.max(1), attrs.depth, visual);
            if backend.image.is_null() {
                return None;
            }
            Some(backend)
        }
    }

    /// (Re)creates the shared image. The old one is destroyed first, which also frees its data.
    unsafe fn alloc_image(
        &mut self,
        width: i32,
        height: i32,
        depth: i32,
        visual: *mut xlib::Visual,
    ) {
        if !self.image.is_null() {
            // XDestroyImage frees the data pointer we handed it.
            destroy_image(self.image);
            self.image = ptr::null_mut();
            self.data = ptr::null_mut();
        }

        let count = (width as usize) * (height as usize);
        let bytes = count * 4;
        let data = libc::malloc(bytes) as *mut u32;
        if data.is_null() {
            return;
        }
        libc::memset(data as *mut c_void, 0, bytes);

        let image = (self.lib.XCreateImage)(
            self.display,
            visual,
            depth.clamp(24, 32) as u32,
            xlib::ZPixmap,
            0,
            data as *mut i8,
            width as u32,
            height as u32,
            32,
            0,
        );
        if image.is_null() {
            libc::free(data as *mut c_void);
            return;
        }

        self.image = image;
        self.data = data;
        self.width = width;
        self.height = height;
    }
}

impl Backend for X11Backend {
    fn resize(&mut self, width: i32, height: i32) {
        let width = width.max(1);
        let height = height.max(1);
        if width == self.width && height == self.height {
            return;
        }
        unsafe {
            (self.lib.XResizeWindow)(self.display, self.window, width as u32, height as u32);

            let mut attrs: xlib::XWindowAttributes = std::mem::zeroed();
            (self.lib.XGetWindowAttributes)(self.display, self.window, &mut attrs);
            self.alloc_image(width, height, attrs.depth, attrs.visual);
        }
    }

    fn present(&mut self, canvas: &Canvas) {
        if self.image.is_null() || self.data.is_null() {
            return;
        }
        let w = self.width.min(canvas.width as i32).max(0) as usize;
        let h = self.height.min(canvas.height as i32).max(0) as usize;
        if w == 0 || h == 0 {
            return;
        }

        // Safety: `data` holds width*height u32s, and w/h are clamped to both buffers.
        unsafe {
            let dst = std::slice::from_raw_parts_mut(
                self.data,
                (self.width as usize) * (self.height as usize),
            );
            for y in 0..h {
                let src_row = &canvas.pixels[y * canvas.width..y * canvas.width + w];
                let dst_row = &mut dst[y * self.width as usize..y * self.width as usize + w];
                if self.swap_rb {
                    for (d, &s) in dst_row.iter_mut().zip(src_row) {
                        *d = (s & 0x0000_ff00) | ((s & 0x00ff_0000) >> 16) | ((s & 0xff) << 16);
                    }
                } else {
                    dst_row.copy_from_slice(src_row);
                }
            }

            (self.lib.XPutImage)(
                self.display,
                self.window,
                self.gc,
                self.image,
                0,
                0,
                0,
                0,
                w as u32,
                h as u32,
            );
            (self.lib.XFlush)(self.display);
        }
    }
}

impl Drop for X11Backend {
    fn drop(&mut self) {
        unsafe {
            if !self.image.is_null() {
                destroy_image(self.image);
            }
            if !self.gc.is_null() {
                (self.lib.XFreeGC)(self.display, self.gc);
            }
            if self.window != 0 {
                (self.lib.XDestroyWindow)(self.display, self.window);
            }
            if !self.display.is_null() {
                (self.lib.XCloseDisplay)(self.display);
            }
        }
    }
}
