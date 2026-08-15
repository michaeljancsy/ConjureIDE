//! Windows backend.
//!
//! The host hands us an `HWND` to live inside. We create a child window and blit the canvas
//! with `SetDIBitsToDevice`. The canvas is kept in the window's own state so `WM_PAINT` can
//! repaint from it without waiting for the next frame.
//!
//! The Win32 surface used here is small enough to declare directly rather than depend on a
//! bindings crate.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;

use bedrock_core::render::Canvas;

use super::{Backend, Ticker};

type Hwnd = *mut c_void;
type Hdc = *mut c_void;
type HInstance = *mut c_void;
type Wparam = usize;
type Lparam = isize;
type Lresult = isize;
type WndProc = unsafe extern "system" fn(Hwnd, u32, Wparam, Lparam) -> Lresult;
type TimerProc = unsafe extern "system" fn(Hwnd, u32, usize, u32);

const WS_CHILD: u32 = 0x4000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WM_PAINT: u32 = 0x000F;
const WM_DESTROY: u32 = 0x0002;
const GWLP_USERDATA: i32 = -21;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;
const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const CS_OWNDC: u32 = 0x0020;

#[repr(C)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

#[repr(C)]
struct PaintStruct {
    hdc: Hdc,
    erase: i32,
    paint: Rect,
    restore: i32,
    inc_update: i32,
    reserved: [u8; 32],
}

#[repr(C)]
struct WndClassExW {
    size: u32,
    style: u32,
    wnd_proc: Option<WndProc>,
    cls_extra: i32,
    wnd_extra: i32,
    instance: HInstance,
    icon: *mut c_void,
    cursor: *mut c_void,
    background: *mut c_void,
    menu_name: *const u16,
    class_name: *const u16,
    icon_sm: *mut c_void,
}

#[repr(C)]
struct BitmapInfoHeader {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    size_image: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    clr_used: u32,
    clr_important: u32,
}

#[repr(C)]
struct BitmapInfo {
    header: BitmapInfoHeader,
    colors: [u32; 3],
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassExW(class: *const WndClassExW) -> u16;
    #[allow(clippy::too_many_arguments)]
    fn CreateWindowExW(
        ex_style: u32,
        class_name: *const u16,
        window_name: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: Hwnd,
        menu: *mut c_void,
        instance: HInstance,
        param: *mut c_void,
    ) -> Hwnd;
    fn DefWindowProcW(hwnd: Hwnd, msg: u32, w: Wparam, l: Lparam) -> Lresult;
    fn DestroyWindow(hwnd: Hwnd) -> i32;
    fn SetWindowLongPtrW(hwnd: Hwnd, index: i32, value: isize) -> isize;
    fn GetWindowLongPtrW(hwnd: Hwnd, index: i32) -> isize;
    fn MoveWindow(hwnd: Hwnd, x: i32, y: i32, w: i32, h: i32, repaint: i32) -> i32;
    fn InvalidateRect(hwnd: Hwnd, rect: *const Rect, erase: i32) -> i32;
    fn BeginPaint(hwnd: Hwnd, ps: *mut PaintStruct) -> Hdc;
    fn EndPaint(hwnd: Hwnd, ps: *const PaintStruct) -> i32;
    fn GetDC(hwnd: Hwnd) -> Hdc;
    fn ReleaseDC(hwnd: Hwnd, hdc: Hdc) -> i32;
    fn SetTimer(hwnd: Hwnd, id: usize, elapse: u32, proc_: Option<TimerProc>) -> usize;
    fn KillTimer(hwnd: Hwnd, id: usize) -> i32;
}

#[link(name = "gdi32")]
extern "system" {
    #[allow(clippy::too_many_arguments)]
    fn SetDIBitsToDevice(
        hdc: Hdc,
        x_dest: i32,
        y_dest: i32,
        w: u32,
        h: u32,
        x_src: i32,
        y_src: i32,
        start_scan: u32,
        scan_lines: u32,
        bits: *const c_void,
        info: *const BitmapInfo,
        coloruse: u32,
    ) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> HInstance;
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Pixels and geometry the window procedure needs in order to repaint on demand.
struct WindowState {
    pixels: Vec<u32>,
    width: i32,
    height: i32,
}

impl WindowState {
    /// Blits the stored pixels. The bitmap height is negated because our canvas is top-down
    /// while a DIB is bottom-up by default.
    unsafe fn blit(&self, hdc: Hdc) {
        if self.pixels.is_empty() || self.width <= 0 || self.height <= 0 {
            return;
        }
        let info = BitmapInfo {
            header: BitmapInfoHeader {
                size: std::mem::size_of::<BitmapInfoHeader>() as u32,
                width: self.width,
                height: -self.height,
                planes: 1,
                bit_count: 32,
                compression: BI_RGB,
                size_image: 0,
                x_pels_per_meter: 0,
                y_pels_per_meter: 0,
                clr_used: 0,
                clr_important: 0,
            },
            colors: [0; 3],
        };
        SetDIBitsToDevice(
            hdc,
            0,
            0,
            self.width as u32,
            self.height as u32,
            0,
            0,
            0,
            self.height as u32,
            self.pixels.as_ptr() as *const c_void,
            &info,
            DIB_RGB_COLORS,
        );
    }
}

unsafe extern "system" fn wnd_proc(hwnd: Hwnd, msg: u32, w: Wparam, l: Lparam) -> Lresult {
    match msg {
        WM_PAINT => {
            let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const WindowState;
            let mut ps: PaintStruct = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);
            if !state.is_null() && !hdc.is_null() {
                (*state).blit(hdc);
            }
            EndPaint(hwnd, &ps);
            0
        }
        WM_DESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, w, l),
    }
}

const CLASS_NAME: &str = "BedrockVisionView";

/// Registers the window class once per process. Re-registering returns an error we can ignore,
/// but doing it once keeps the failure path clean.
fn ensure_class(instance: HInstance) {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let name = wide(CLASS_NAME);
        let class = WndClassExW {
            size: std::mem::size_of::<WndClassExW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW | CS_OWNDC,
            wnd_proc: Some(wnd_proc),
            cls_extra: 0,
            wnd_extra: 0,
            instance,
            icon: std::ptr::null_mut(),
            cursor: std::ptr::null_mut(),
            background: std::ptr::null_mut(),
            menu_name: std::ptr::null(),
            class_name: name.as_ptr(),
            icon_sm: std::ptr::null_mut(),
        };
        // Safety: every pointer in `class` is valid for the duration of the call.
        unsafe {
            RegisterClassExW(&class);
        }
    });
}

pub struct Win32Backend {
    hwnd: Hwnd,
    /// Boxed so the pointer stashed in GWLP_USERDATA stays valid if the backend moves.
    state: Box<WindowState>,
}

impl Win32Backend {
    pub fn new(parent: *mut c_void, width: i32, height: i32) -> Option<Win32Backend> {
        if parent.is_null() {
            return None;
        }
        // Safety: `parent` is the HWND the host promised via kPlatformTypeHWND.
        unsafe {
            let instance = GetModuleHandleW(std::ptr::null());
            ensure_class(instance);

            let class_name = wide(CLASS_NAME);
            let window_name = wide("");
            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                window_name.as_ptr(),
                WS_CHILD | WS_VISIBLE,
                0,
                0,
                width.max(1),
                height.max(1),
                parent as Hwnd,
                std::ptr::null_mut(),
                instance,
                std::ptr::null_mut(),
            );
            if hwnd.is_null() {
                return None;
            }

            let state = Box::new(WindowState {
                pixels: Vec::new(),
                width: width.max(1),
                height: height.max(1),
            });
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, state.as_ref() as *const _ as isize);

            Some(Win32Backend { hwnd, state })
        }
    }
}

impl Backend for Win32Backend {
    fn resize(&mut self, width: i32, height: i32) {
        self.state.width = width.max(1);
        self.state.height = height.max(1);
        // Safety: the window is alive until Drop.
        unsafe {
            MoveWindow(self.hwnd, 0, 0, self.state.width, self.state.height, 1);
        }
    }

    fn present(&mut self, canvas: &Canvas) {
        if canvas.width == 0 || canvas.height == 0 {
            return;
        }
        self.state.pixels.clear();
        self.state.pixels.extend_from_slice(&canvas.pixels);
        self.state.width = canvas.width as i32;
        self.state.height = canvas.height as i32;

        // Draw straight away rather than waiting for WM_PAINT; the stored pixels still serve
        // any WM_PAINT the system sends us later.
        unsafe {
            let hdc = GetDC(self.hwnd);
            if !hdc.is_null() {
                self.state.blit(hdc);
                ReleaseDC(self.hwnd, hdc);
            } else {
                InvalidateRect(self.hwnd, std::ptr::null(), 0);
            }
        }
    }
}

impl Drop for Win32Backend {
    fn drop(&mut self) {
        // Clear the back-pointer before the state is freed, so a late WM_PAINT can't follow it.
        unsafe {
            if !self.hwnd.is_null() {
                SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
                DestroyWindow(self.hwnd);
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Timer
// ---------------------------------------------------------------------------------------------

// The timer fires on the thread that created it, so the callbacks need no synchronisation and
// need not be Send — which matters, because the view they close over holds a window handle.
thread_local! {
    static TICKERS: RefCell<HashMap<usize, Box<dyn Fn()>>> = RefCell::new(HashMap::new());
}

struct Win32Ticker {
    id: usize,
}

impl Ticker for Win32Ticker {}

unsafe extern "system" fn timer_proc(_hwnd: Hwnd, _msg: u32, id: usize, _time: u32) {
    TICKERS.with(|t| {
        if let Ok(map) = t.try_borrow() {
            if let Some(cb) = map.get(&id) {
                cb();
            }
        }
    });
}

pub fn start_ticker(interval_ms: u32, callback: Box<dyn Fn()>) -> Option<Box<dyn Ticker>> {
    // Safety: a null HWND makes the timer thread-scoped and dispatched through TimerProc.
    let id = unsafe { SetTimer(std::ptr::null_mut(), 0, interval_ms, Some(timer_proc)) };
    if id == 0 {
        return None;
    }
    TICKERS.with(|t| t.borrow_mut().insert(id, callback));
    Some(Box::new(Win32Ticker { id }))
}

impl Drop for Win32Ticker {
    fn drop(&mut self) {
        unsafe {
            KillTimer(std::ptr::null_mut(), self.id);
        }
        TICKERS.with(|t| t.borrow_mut().remove(&self.id));
    }
}
