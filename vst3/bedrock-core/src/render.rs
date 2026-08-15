//! Software rasteriser for Vision's graph.
//!
//! Rendering is done into a plain `u32` pixel buffer in `0x00RRGGBB`, which is what X11
//! TrueColor and a Win32 DIB both want, and is one shuffle away from what Cocoa wants. Doing
//! it ourselves keeps the plugin free of a GPU context and of any drawing library, and a
//! 128-point curve per track is nowhere near enough work to need one.
//!
//! The layout is resolution-independent: every spacing, line width and font size is derived
//! from a [`Layout::scale`] computed from the window size, so the graph reads the same whether
//! it's a 480×270 strip or filling a 5K display.

use crate::analyzer::{DB_FLOOR, FREQ_MAX, FREQ_MIN, NUM_BINS};
use crate::font;
use crate::palette::{theme, Palette, Rgb};
use crate::protocol::Frame;

/// Top of the dB axis.
pub const DB_TOP: f32 = 6.0;

/// Bottom of the dB axis. Below the analyzer's floor, so the floor itself is never on screen.
pub const DB_BOTTOM: f32 = -96.0;

/// Frequencies that get a labelled gridline.
const FREQ_TICKS: [(f32, &str); 10] = [
    (31.5, "31"),
    (63.0, "63"),
    (125.0, "125"),
    (250.0, "250"),
    (500.0, "500"),
    (1_000.0, "1k"),
    (2_000.0, "2k"),
    (4_000.0, "4k"),
    (8_000.0, "8k"),
    (16_000.0, "16k"),
];

/// A drawable track: what Vision knows, flattened for the renderer.
pub struct TrackView<'a> {
    pub name: &'a str,
    pub frame: &'a Frame,
    pub daw_color: Option<Rgb>,
    /// True once the track has delivered at least one frame.
    pub has_frame: bool,
}

/// Everything the renderer needs for one repaint.
pub struct Scene<'a> {
    pub tracks: &'a [TrackView<'a>],
    pub palette: Palette,
    /// 0..=1. How solidly the area under each curve is filled.
    pub fill_opacity: f32,
    pub show_legend: bool,
    pub show_grid: bool,
    pub realm: u16,
    /// Shown instead of the graph when the hub couldn't bind.
    pub error: Option<&'a str>,
}

impl<'a> Default for Scene<'a> {
    fn default() -> Scene<'a> {
        Scene {
            tracks: &[],
            palette: Palette::DEFAULT,
            fill_opacity: 0.14,
            show_legend: true,
            show_grid: true,
            realm: 0,
            error: None,
        }
    }
}

/// A `0x00RRGGBB` pixel buffer.
pub struct Canvas {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u32>,
}

impl Canvas {
    pub fn new(width: usize, height: usize) -> Canvas {
        Canvas {
            width,
            height,
            pixels: vec![0; width * height],
        }
    }

    pub fn resize(&mut self, width: usize, height: usize) {
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            self.pixels.clear();
            self.pixels.resize(width * height, 0);
        }
    }

    pub fn fill(&mut self, color: Rgb) {
        self.pixels.fill(color.to_hex());
    }

    #[inline]
    pub fn get(&self, x: usize, y: usize) -> Rgb {
        Rgb::from_hex(self.pixels[y * self.width + x])
    }

    /// Alpha-blends `color` over the pixel at `(x, y)`. Out-of-bounds writes are dropped, which
    /// lets callers rasterise without clipping every span by hand.
    #[inline]
    pub fn blend(&mut self, x: i32, y: i32, color: Rgb, alpha: f32) {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            return;
        }
        let alpha = alpha.clamp(0.0, 1.0);
        if alpha <= 0.0 {
            return;
        }
        let i = y as usize * self.width + x as usize;
        if alpha >= 1.0 {
            self.pixels[i] = color.to_hex();
            return;
        }
        let dst = Rgb::from_hex(self.pixels[i]);
        self.pixels[i] = dst.lerp(color, alpha).to_hex();
    }

    pub fn fill_rect(&mut self, x: i32, y: i32, w: i32, h: i32, color: Rgb, alpha: f32) {
        for yy in y..y + h {
            for xx in x..x + w {
                self.blend(xx, yy, color, alpha);
            }
        }
    }

    /// Vertical run, inclusive of both endpoints.
    fn v_span(&mut self, x: i32, y0: i32, y1: i32, color: Rgb, alpha: f32) {
        let (a, b) = if y0 <= y1 { (y0, y1) } else { (y1, y0) };
        for y in a..=b {
            self.blend(x, y, color, alpha);
        }
    }

    pub fn h_line(&mut self, x0: i32, x1: i32, y: i32, color: Rgb, alpha: f32) {
        for x in x0..=x1 {
            self.blend(x, y, color, alpha);
        }
    }

    pub fn v_line(&mut self, x: i32, y0: i32, y1: i32, color: Rgb, alpha: f32) {
        self.v_span(x, y0, y1, color, alpha);
    }

    /// Draws `text` with its top-left at `(x, y)`.
    pub fn text(&mut self, x: i32, y: i32, text: &str, scale: usize, color: Rgb, alpha: f32) {
        let scale = scale.max(1) as i32;
        let mut pen = x;
        for ch in text.chars() {
            let g = font::glyph(ch);
            for (col, bits) in g.iter().enumerate() {
                for row in 0..font::GLYPH_H {
                    if bits & (1 << row) != 0 {
                        let px = pen + col as i32 * scale;
                        let py = y + row as i32 * scale;
                        for dy in 0..scale {
                            for dx in 0..scale {
                                self.blend(px + dx, py + dy, color, alpha);
                            }
                        }
                    }
                }
            }
            pen += font::ADVANCE as i32 * scale;
        }
    }
}

/// Where everything goes, for a given canvas size.
#[derive(Clone, Copy, Debug)]
pub struct Layout {
    /// Integer UI scale. Drives font size, line width and every margin.
    pub scale: usize,
    pub graph_x: i32,
    pub graph_y: i32,
    pub graph_w: i32,
    pub graph_h: i32,
    pub legend_x: i32,
    pub legend_w: i32,
    pub legend_visible: bool,
}

impl Layout {
    /// Derives a layout from the window size.
    ///
    /// The legend is dropped entirely below a threshold rather than squeezed: a 60 px column of
    /// clipped track names is worse than none, and the graph is what the user came for.
    pub fn compute(width: usize, height: usize, want_legend: bool) -> Layout {
        let w = width as i32;
        let h = height as i32;

        // One step up in scale per doubling of the smaller dimension past the base size.
        let scale = ((width / 480).min(height / 270)).clamp(1, 4);
        let s = scale as i32;

        let db_gutter = 26 * s;
        let freq_gutter = 12 * s;
        let pad = 6 * s;

        // The legend only earns its place if the graph still gets a usable width afterwards.
        let ideal_legend = 108 * s;
        let min_graph_w = 320 * s;
        let legend_visible = want_legend && w >= db_gutter + ideal_legend + pad + min_graph_w;
        let legend_w = if legend_visible { ideal_legend } else { 0 };

        let graph_x = db_gutter;
        let graph_y = pad;
        let graph_w = (w - db_gutter - legend_w - pad).max(1);
        let graph_h = (h - freq_gutter - pad * 2).max(1);

        Layout {
            scale,
            graph_x,
            graph_y,
            graph_w,
            graph_h,
            legend_x: graph_x + graph_w + pad,
            legend_w,
            legend_visible,
        }
    }

    /// Line thickness for a spectrum curve.
    pub fn curve_width(&self) -> i32 {
        self.scale as i32
    }
}

/// Maps a frequency to a fractional x within the graph, using the same log scale as the bins.
pub fn freq_to_x(freq: f32, layout: &Layout) -> f32 {
    let t = (freq / FREQ_MIN).max(1e-6).ln() / (FREQ_MAX / FREQ_MIN).ln();
    layout.graph_x as f32 + t * layout.graph_w as f32
}

/// Maps a dBFS value to a fractional y within the graph.
pub fn db_to_y(db: f32, layout: &Layout) -> f32 {
    let t = (DB_TOP - db) / (DB_TOP - DB_BOTTOM);
    layout.graph_y as f32 + t.clamp(0.0, 1.0) * layout.graph_h as f32
}

/// Maps an x within the graph back to a fractional display-bin index.
fn x_to_bin(x: f32, layout: &Layout) -> f32 {
    let t = ((x - layout.graph_x as f32) / layout.graph_w as f32).clamp(0.0, 1.0);
    // Bin centres sit at (i + 0.5) / NUM_BINS along the log axis.
    t * NUM_BINS as f32 - 0.5
}

/// Reads a track's curve at a fractional bin index, interpolating between bins.
fn curve_db(frame: &Frame, pos: f32) -> f32 {
    let clamped = pos.clamp(0.0, (NUM_BINS - 1) as f32);
    let i = clamped.floor() as usize;
    let j = (i + 1).min(NUM_BINS - 1);
    let f = clamped - i as f32;
    let a = frame.bin_db(i);
    let b = frame.bin_db(j);
    a + (b - a) * f
}

/// Renders one repaint of the whole graph.
pub fn render(canvas: &mut Canvas, scene: &Scene) {
    canvas.fill(theme::BACKGROUND);
    if canvas.width == 0 || canvas.height == 0 {
        return;
    }

    let layout = Layout::compute(canvas.width, canvas.height, scene.show_legend);

    if let Some(err) = scene.error {
        draw_centered_message(canvas, &layout, err, theme::WARNING);
        return;
    }

    canvas.fill_rect(
        layout.graph_x,
        layout.graph_y,
        layout.graph_w,
        layout.graph_h,
        theme::PANEL,
        1.0,
    );

    if scene.show_grid {
        draw_grid(canvas, &layout);
    }

    let drawable: Vec<(usize, &TrackView)> = scene
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, t)| t.has_frame)
        .collect();

    for (i, track) in &drawable {
        let color = scene.palette.color_for(*i, track.daw_color);
        draw_track(canvas, &layout, track.frame, color, scene.fill_opacity);
    }

    draw_axes(canvas, &layout);

    if layout.legend_visible {
        draw_legend(canvas, &layout, scene);
    }

    if scene.tracks.is_empty() {
        draw_centered_message(
            canvas,
            &layout,
            "No tracks. Add Bedrock Track to a channel.",
            theme::TEXT,
        );
    }
}

fn draw_grid(canvas: &mut Canvas, layout: &Layout) {
    // Horizontal dB lines every 12 dB, with 0 dBFS picked out.
    let mut db = DB_TOP;
    while db >= DB_BOTTOM {
        let y = db_to_y(db, layout).round() as i32;
        let strong = db == 0.0;
        canvas.h_line(
            layout.graph_x,
            layout.graph_x + layout.graph_w - 1,
            y,
            if strong { theme::GRID_STRONG } else { theme::GRID },
            if strong { 0.9 } else { 0.55 },
        );
        db -= 12.0;
    }

    for (freq, _) in FREQ_TICKS {
        let x = freq_to_x(freq, layout).round() as i32;
        if x <= layout.graph_x || x >= layout.graph_x + layout.graph_w {
            continue;
        }
        canvas.v_line(
            x,
            layout.graph_y,
            layout.graph_y + layout.graph_h - 1,
            theme::GRID,
            0.55,
        );
    }
}

/// Draws one track's curve, plus the translucent area beneath it.
///
/// The curve is evaluated once per pixel column rather than per bin and joined to the previous
/// column, so it stays continuous at any width — sampling per bin would leave gaps on a wide
/// window and alias badly on a narrow one.
fn draw_track(canvas: &mut Canvas, layout: &Layout, frame: &Frame, color: Rgb, fill: f32) {
    let x0 = layout.graph_x;
    let x1 = layout.graph_x + layout.graph_w;
    let bottom = layout.graph_y + layout.graph_h - 1;
    let thickness = layout.curve_width();

    let mut prev_y: Option<i32> = None;
    for x in x0..x1 {
        let db = curve_db(frame, x_to_bin(x as f32 + 0.5, layout));
        // A bin sitting on the analyzer floor means silence in that band; drawing it would
        // paint a hard line along the bottom of the graph for every quiet track.
        if db <= DB_FLOOR + 0.5 {
            prev_y = None;
            continue;
        }
        let y = db_to_y(db, layout).round() as i32;

        if fill > 0.0 && y < bottom {
            canvas.v_span(x, y, bottom, color, fill);
        }

        match prev_y {
            Some(py) => canvas.v_span(x, py, y, color, 1.0),
            None => canvas.blend(x, y, color, 1.0),
        }
        for t in 1..thickness {
            canvas.blend(x, y + t, color, 1.0);
        }
        prev_y = Some(y);
    }
}

fn draw_axes(canvas: &mut Canvas, layout: &Layout) {
    let s = layout.scale;
    let fh = font::text_height(s) as i32;

    let mut db = DB_TOP - 6.0;
    while db >= DB_BOTTOM {
        let y = db_to_y(db, layout).round() as i32 - fh / 2;
        let label = format!("{}", db as i32);
        let w = font::text_width(&label, s) as i32;
        canvas.text(
            layout.graph_x - w - 4 * s as i32,
            y,
            &label,
            s,
            theme::TEXT,
            0.85,
        );
        db -= 24.0;
    }

    let ty = layout.graph_y + layout.graph_h + 3 * s as i32;
    for (freq, label) in FREQ_TICKS {
        let cx = freq_to_x(freq, layout);
        let w = font::text_width(label, s) as i32;
        let x = (cx - w as f32 / 2.0).round() as i32;
        if x < layout.graph_x || x + w > layout.graph_x + layout.graph_w {
            continue;
        }
        canvas.text(x, ty, label, s, theme::TEXT, 0.85);
    }
}

fn draw_legend(canvas: &mut Canvas, layout: &Layout, scene: &Scene) {
    let s = layout.scale;
    let si = s as i32;
    let fh = font::text_height(s) as i32;
    let row_h = fh + 5 * si;
    let swatch = fh;

    let mut y = layout.graph_y;
    let header = format!("REALM {}", scene.realm);
    canvas.text(layout.legend_x, y, &header, s, theme::TEXT, 0.7);
    y += row_h;

    let max_rows = ((layout.graph_h - (y - layout.graph_y)) / row_h).max(0) as usize;
    let shown = scene.tracks.len().min(max_rows.saturating_sub(1));

    for (i, track) in scene.tracks.iter().enumerate().take(shown) {
        let color = scene.palette.color_for(i, track.daw_color);
        canvas.fill_rect(layout.legend_x, y, swatch, swatch, color, 1.0);

        let text_x = layout.legend_x + swatch + 4 * si;
        let budget = (layout.legend_w - swatch - 4 * si).max(0) as usize;
        let name = if track.name.is_empty() {
            "(unnamed)"
        } else {
            track.name.as_ref()
        };
        canvas.text(
            text_x,
            y,
            &font::elide(name, budget, s),
            s,
            if track.has_frame {
                theme::TEXT_BRIGHT
            } else {
                theme::TEXT
            },
            1.0,
        );
        y += row_h;
    }

    if shown < scene.tracks.len() {
        let more = format!("+{} more", scene.tracks.len() - shown);
        canvas.text(layout.legend_x, y, &more, s, theme::TEXT, 0.7);
    }
}

fn draw_centered_message(canvas: &mut Canvas, layout: &Layout, text: &str, color: Rgb) {
    let s = layout.scale;
    let w = font::text_width(text, s) as i32;
    let h = font::text_height(s) as i32;
    let x = layout.graph_x + (layout.graph_w - w) / 2;
    let y = layout.graph_y + (layout.graph_h - h) / 2;
    canvas.text(x, y, text, s, color, 0.9);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::quantize_db;

    fn frame_flat(db: f32) -> Frame {
        Frame {
            bins: [quantize_db(db); NUM_BINS],
            peak_db: db,
            rms_db: db,
        }
    }

    /// A frame with a single loud band centred on `freq`.
    fn frame_tone(freq: f32, db: f32) -> Frame {
        let mut bins = [quantize_db(DB_FLOOR); NUM_BINS];
        let target = (0..NUM_BINS)
            .min_by(|&a, &b| {
                (crate::analyzer::bin_frequency(a) - freq)
                    .abs()
                    .partial_cmp(&(crate::analyzer::bin_frequency(b) - freq).abs())
                    .unwrap()
            })
            .unwrap();
        bins[target] = quantize_db(db);
        Frame {
            bins,
            peak_db: db,
            rms_db: db,
        }
    }

    fn count_non_background(canvas: &Canvas) -> usize {
        canvas
            .pixels
            .iter()
            .filter(|&&p| p != theme::BACKGROUND.to_hex())
            .count()
    }

    fn count_color(canvas: &Canvas, color: Rgb) -> usize {
        canvas.pixels.iter().filter(|&&p| p == color.to_hex()).count()
    }

    #[test]
    fn empty_scene_still_paints_the_chrome() {
        let mut c = Canvas::new(800, 450);
        render(&mut c, &Scene::default());
        assert!(count_non_background(&c) > 0, "expected grid and axis labels");
    }

    #[test]
    fn a_track_draws_in_its_palette_color() {
        let f = frame_flat(-30.0);
        let tracks = [TrackView {
            name: "Kick",
            frame: &f,
            daw_color: None,
            has_frame: true,
        }];
        let scene = Scene {
            tracks: &tracks,
            show_legend: false,
            ..Default::default()
        };
        let mut c = Canvas::new(800, 450);
        render(&mut c, &scene);

        let expected = Palette::DEFAULT.color_for(0, None);
        assert!(
            count_color(&c, expected) > 100,
            "expected a solid curve in the track's colour"
        );
    }

    #[test]
    fn a_track_with_no_frame_yet_is_not_drawn() {
        let f = frame_flat(-30.0);
        let tracks = [TrackView {
            name: "Pending",
            frame: &f,
            daw_color: None,
            has_frame: false,
        }];
        // Legend off: it lists every connected track, frame or not, and its colour swatch
        // would be counted as curve pixels here.
        let mut c = Canvas::new(800, 450);
        render(
            &mut c,
            &Scene {
                tracks: &tracks,
                show_legend: false,
                ..Default::default()
            },
        );
        assert_eq!(
            count_color(&c, Palette::DEFAULT.color_for(0, None)),
            0,
            "a track that has never reported must not draw a curve"
        );
    }

    #[test]
    fn silent_bands_do_not_paint_a_line_along_the_floor() {
        // Every bin at the analyzer floor means silence, not "a curve at the bottom".
        let f = frame_flat(DB_FLOOR);
        let tracks = [TrackView {
            name: "Silent",
            frame: &f,
            daw_color: None,
            has_frame: true,
        }];
        let mut c = Canvas::new(800, 450);
        render(
            &mut c,
            &Scene {
                tracks: &tracks,
                fill_opacity: 0.0,
                show_legend: false,
                ..Default::default()
            },
        );
        assert_eq!(count_color(&c, Palette::DEFAULT.color_for(0, None)), 0);
    }

    #[test]
    fn louder_tracks_draw_higher_up() {
        let quiet = frame_flat(-60.0);
        let loud = frame_flat(-12.0);
        let layout = Layout::compute(800, 450, true);
        assert!(
            db_to_y(-12.0, &layout) < db_to_y(-60.0, &layout),
            "louder must map to a smaller y"
        );

        let mut top_of = |f: &Frame, color: Rgb| {
            let tracks = [TrackView {
                name: "T",
                frame: f,
                daw_color: Some(color),
                has_frame: true,
            }];
            let mut c = Canvas::new(800, 450);
            render(
                &mut c,
                &Scene {
                    tracks: &tracks,
                    palette: Palette::DawColors,
                    fill_opacity: 0.0,
                    show_legend: false,
                    ..Default::default()
                },
            );
            (0..c.height)
                .find(|&y| (0..c.width).any(|x| c.get(x, y) == color))
                .expect("curve should be visible")
        };

        let loud_y = top_of(&loud, Rgb::new(255, 0, 0));
        let quiet_y = top_of(&quiet, Rgb::new(0, 255, 0));
        assert!(loud_y < quiet_y, "loud {loud_y} should sit above quiet {quiet_y}");
    }

    #[test]
    fn a_tone_draws_at_the_right_place_on_the_log_axis() {
        let layout = Layout::compute(1000, 500, false);
        // The axis is logarithmic, so the *geometric* mean of the range sits mid-graph —
        // sqrt(20 * 20000) ≈ 632 Hz, not 1 kHz.
        let mid = layout.graph_x as f32 + layout.graph_w as f32 / 2.0;
        let geometric_mid = (FREQ_MIN * FREQ_MAX).sqrt();
        assert!(
            (freq_to_x(geometric_mid, &layout) - mid).abs() < 2.0,
            "{geometric_mid} Hz should sit mid-graph"
        );
        // Ends anchor to the edges.
        assert!((freq_to_x(FREQ_MIN, &layout) - layout.graph_x as f32).abs() < 1.0);
        assert!(
            (freq_to_x(FREQ_MAX, &layout) - (layout.graph_x + layout.graph_w) as f32).abs() < 1.0
        );

        let x = freq_to_x(1000.0, &layout);

        let f = frame_tone(1000.0, -10.0);
        let color = Rgb::new(255, 0, 0);
        let tracks = [TrackView {
            name: "Tone",
            frame: &f,
            daw_color: Some(color),
            has_frame: true,
        }];
        let mut c = Canvas::new(1000, 500);
        render(
            &mut c,
            &Scene {
                tracks: &tracks,
                palette: Palette::DawColors,
                fill_opacity: 0.0,
                show_legend: false,
                ..Default::default()
            },
        );

        // The highest-drawn pixel of the curve should be near the 1 kHz column.
        let top = (0..c.height)
            .find(|&y| (0..c.width).any(|x| c.get(x, y) == color))
            .unwrap();
        let peak_x = (0..c.width).find(|&x| c.get(x, top) == color).unwrap() as f32;
        assert!(
            (peak_x - x).abs() < layout.graph_w as f32 * 0.05,
            "tone peak drew at x={peak_x}, expected near {x}"
        );
    }

    #[test]
    fn layout_scales_with_the_window() {
        let small = Layout::compute(480, 270, true);
        let large = Layout::compute(1920, 1080, true);
        assert!(large.scale > small.scale, "a bigger window should scale up");
        assert!(large.graph_w > small.graph_w);
    }

    #[test]
    fn the_legend_is_dropped_rather_than_squeezed_on_a_narrow_window() {
        let wide = Layout::compute(1200, 500, true);
        assert!(wide.legend_visible);
        let narrow = Layout::compute(360, 500, true);
        assert!(
            !narrow.legend_visible,
            "a narrow window should give the space to the graph"
        );
        assert_eq!(narrow.legend_w, 0);
    }

    #[test]
    fn asking_for_no_legend_removes_it() {
        let l = Layout::compute(1200, 500, false);
        assert!(!l.legend_visible);
    }

    #[test]
    fn the_graph_never_escapes_the_canvas() {
        for (w, h) in [(200usize, 120usize), (480, 270), (900, 400), (2560, 1440)] {
            let l = Layout::compute(w, h, true);
            assert!(l.graph_x >= 0 && l.graph_y >= 0);
            assert!(
                l.graph_x + l.graph_w <= w as i32,
                "graph overflows width at {w}x{h}"
            );
            assert!(
                l.graph_y + l.graph_h <= h as i32,
                "graph overflows height at {w}x{h}"
            );
            if l.legend_visible {
                assert!(l.legend_x + l.legend_w <= w as i32);
            }
        }
    }

    #[test]
    fn rendering_at_absurd_sizes_does_not_panic() {
        for (w, h) in [(1usize, 1usize), (1, 500), (500, 1), (3, 3), (4000, 40)] {
            let f = frame_flat(-20.0);
            let tracks = [TrackView {
                name: "T",
                frame: &f,
                daw_color: None,
                has_frame: true,
            }];
            let mut c = Canvas::new(w, h);
            render(
                &mut c,
                &Scene {
                    tracks: &tracks,
                    ..Default::default()
                },
            );
        }
    }

    #[test]
    fn many_tracks_all_get_drawn() {
        let f = frame_flat(-30.0);
        let views: Vec<TrackView> = (0..24)
            .map(|_| TrackView {
                name: "T",
                frame: &f,
                daw_color: None,
                has_frame: true,
            })
            .collect();
        let mut c = Canvas::new(1280, 720);
        render(
            &mut c,
            &Scene {
                tracks: &views,
                fill_opacity: 0.0,
                ..Default::default()
            },
        );
        // Each track has a distinct palette colour; every one should reach the canvas.
        for i in 0..24 {
            let color = Palette::DEFAULT.color_for(i, None);
            assert!(
                count_color(&c, color) > 0,
                "track {i} ({color:?}) never drew"
            );
        }
    }

    #[test]
    fn an_error_replaces_the_graph() {
        let mut c = Canvas::new(800, 450);
        render(
            &mut c,
            &Scene {
                error: Some("realm 0 is already in use"),
                ..Default::default()
            },
        );
        assert!(count_color(&c, theme::PANEL) == 0, "graph panel should not be drawn");
        assert!(count_non_background(&c) > 0, "the message should be visible");
    }

    #[test]
    fn resize_reuses_the_buffer_and_reports_the_new_size() {
        let mut c = Canvas::new(100, 100);
        c.resize(200, 50);
        assert_eq!(c.width, 200);
        assert_eq!(c.height, 50);
        assert_eq!(c.pixels.len(), 200 * 50);
    }

    #[test]
    fn blending_is_clamped_and_out_of_bounds_is_ignored() {
        let mut c = Canvas::new(4, 4);
        c.fill(Rgb::BLACK);
        c.blend(-1, 0, Rgb::WHITE, 1.0);
        c.blend(0, -1, Rgb::WHITE, 1.0);
        c.blend(4, 0, Rgb::WHITE, 1.0);
        c.blend(0, 4, Rgb::WHITE, 1.0);
        assert_eq!(count_color(&c, Rgb::WHITE), 0);

        c.blend(1, 1, Rgb::WHITE, 1.0);
        assert_eq!(c.get(1, 1), Rgb::WHITE);
        c.blend(2, 2, Rgb::WHITE, 0.5);
        assert_eq!(c.get(2, 2), Rgb::new(128, 128, 128));
    }
}
