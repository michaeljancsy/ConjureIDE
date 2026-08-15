//! Colour: the [`Rgb`] type, the built-in graph palettes, and DAW-colour import.

/// An 8-bit-per-channel opaque colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    pub const BLACK: Rgb = Rgb::new(0, 0, 0);
    pub const WHITE: Rgb = Rgb::new(255, 255, 255);

    pub const fn new(r: u8, g: u8, b: u8) -> Rgb {
        Rgb { r, g, b }
    }

    /// Unpacks `0xRRGGBB`.
    pub const fn from_hex(hex: u32) -> Rgb {
        Rgb::new(
            ((hex >> 16) & 0xff) as u8,
            ((hex >> 8) & 0xff) as u8,
            (hex & 0xff) as u8,
        )
    }

    /// Unpacks a VST3 `ColorSpec`, which is `0xAARRGGBB`. The alpha byte is dropped: the graph
    /// composites with its own opacity and a host that reports a fully transparent colour
    /// (some do, when a track has no explicit colour set) should still give us a usable hue.
    pub const fn from_vst3_color_spec(spec: u32) -> Rgb {
        Rgb::from_hex(spec & 0x00ff_ffff)
    }

    /// Blends towards `other` by `t` in 0..=1.
    pub fn lerp(self, other: Rgb, t: f32) -> Rgb {
        let t = t.clamp(0.0, 1.0);
        let f = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round().clamp(0.0, 255.0) as u8;
        Rgb::new(f(self.r, other.r), f(self.g, other.g), f(self.b, other.b))
    }

    /// Scales all channels by `k`, saturating.
    pub fn scale(self, k: f32) -> Rgb {
        let f = |a: u8| (a as f32 * k).round().clamp(0.0, 255.0) as u8;
        Rgb::new(f(self.r), f(self.g), f(self.b))
    }

    /// Relative luminance (Rec. 709 coefficients), 0..=1.
    pub fn luminance(self) -> f32 {
        (0.2126 * self.r as f32 + 0.7152 * self.g as f32 + 0.0722 * self.b as f32) / 255.0
    }

    /// Packs to `0xRRGGBB`.
    pub const fn to_hex(self) -> u32 {
        ((self.r as u32) << 16) | ((self.g as u32) << 8) | self.b as u32
    }
}

/// Converts HSL to RGB. `h` is in degrees, `s` and `l` in 0..=1.
pub fn hsl(h: f32, s: f32, l: f32) -> Rgb {
    let h = h.rem_euclid(360.0);
    let s = s.clamp(0.0, 1.0);
    let l = l.clamp(0.0, 1.0);

    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
    let m = l - c / 2.0;

    let (r, g, b) = match h as u32 / 60 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };

    let f = |v: f32| (((v + m) * 255.0).round()).clamp(0.0, 255.0) as u8;
    Rgb::new(f(r), f(g), f(b))
}

/// The graph colour schemes offered in Vision's settings.
///
/// Every scheme except [`Palette::DawColors`] generates a colour purely from the track's
/// position in the list, so the graph stays readable no matter what the host reports. `DawColors`
/// uses the colour the host gave us via the channel-context API and falls back to
/// [`Palette::DEFAULT`] for any track whose host didn't supply one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Palette {
    /// Cyan → magenta sweep. Cool and calm, at the cost of some separation.
    Aurora,
    /// Warm red → yellow sweep.
    Ember,
    /// Desaturated blues, for when track colour shouldn't compete with the shapes.
    Ice,
    /// Full hue wheel, maximum separation between neighbouring tracks. The default.
    Spectrum,
    /// Greyscale ramp.
    Mono,
    /// Whatever the DAW says the track colour is.
    DawColors,
}

impl Palette {
    /// Dropdown order in the host. `Spectrum` leads because it is the default: telling one
    /// track from another is the whole job, and the full hue wheel separates a busy session
    /// better than any of the narrower schemes.
    pub const ALL: [Palette; 6] = [
        Palette::Spectrum,
        Palette::Aurora,
        Palette::Ember,
        Palette::Ice,
        Palette::Mono,
        Palette::DawColors,
    ];

    /// The scheme used when nothing has been chosen, and the fallback for a track whose host
    /// reported no colour under [`Palette::DawColors`].
    pub const DEFAULT: Palette = Palette::Spectrum;

    pub fn name(self) -> &'static str {
        match self {
            Palette::Aurora => "Aurora",
            Palette::Ember => "Ember",
            Palette::Ice => "Ice",
            Palette::Spectrum => "Spectrum",
            Palette::Mono => "Mono",
            Palette::DawColors => "DAW Colors",
        }
    }

    pub fn from_index(i: usize) -> Palette {
        Palette::ALL[i.min(Palette::ALL.len() - 1)]
    }

    pub fn index(self) -> usize {
        Palette::ALL.iter().position(|&p| p == self).unwrap_or(0)
    }

    /// Colour for track `i` of `count`, given the colour the DAW reported (if any).
    ///
    /// Hues are spread with a golden-ratio walk rather than an even split, so adjacent tracks
    /// stay distinguishable whether there are three tracks or thirty, and a track keeps its
    /// colour when another is added below it.
    pub fn color_for(self, i: usize, daw_color: Option<Rgb>) -> Rgb {
        if self == Palette::DawColors {
            if let Some(c) = daw_color {
                // Hosts report unset track colours as pure black or pure white; neither reads
                // as a track identity on the graph, so fall through to a generated colour.
                if c != Rgb::BLACK && c != Rgb::WHITE {
                    return c;
                }
            }
            return Palette::DEFAULT.color_for(i, None);
        }

        // Low-discrepancy position in 0..1 from the golden ratio, then mapped across the
        // palette's hue span. Walking by the golden *angle* and taking it modulo a narrower
        // span would not do: 137.508° mod 140° leaves consecutive tracks only 2.5° apart every
        // time the walk wraps, which is two shades of the same colour on the graph.
        let t = ((i as f32) * 0.618_034) % 1.0;

        match self {
            Palette::Aurora => hsl(170.0 + t * 170.0, 0.68, 0.60),
            Palette::Ember => hsl(-10.0 + t * 70.0, 0.78, 0.56),
            Palette::Ice => hsl(190.0 + t * 80.0, 0.38, 0.62),
            Palette::Spectrum => hsl(t * 360.0, 0.70, 0.58),
            Palette::Mono => {
                let v = (0.45 + 0.5 * t).clamp(0.35, 0.95);
                let g = (v * 255.0) as u8;
                Rgb::new(g, g, g)
            }
            Palette::DawColors => unreachable!("handled above"),
        }
    }
}

/// Vision's dark chrome. Kept here so the renderer and the platform backends agree.
pub mod theme {
    use super::Rgb;

    pub const BACKGROUND: Rgb = Rgb::from_hex(0x0e_10_14);
    pub const PANEL: Rgb = Rgb::from_hex(0x16_19_1f);
    pub const GRID: Rgb = Rgb::from_hex(0x24_28_31);
    pub const GRID_STRONG: Rgb = Rgb::from_hex(0x33_38_44);
    pub const TEXT: Rgb = Rgb::from_hex(0x8b_93_a3);
    pub const TEXT_BRIGHT: Rgb = Rgb::from_hex(0xd6_dc_e8);
    pub const WARNING: Rgb = Rgb::from_hex(0xd8_6b_4a);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips() {
        let c = Rgb::from_hex(0x1234_56);
        assert_eq!(c, Rgb::new(0x12, 0x34, 0x56));
        assert_eq!(c.to_hex(), 0x1234_56);
    }

    #[test]
    fn vst3_color_spec_drops_alpha() {
        // VST3 packs channel colour as 0xAARRGGBB.
        assert_eq!(
            Rgb::from_vst3_color_spec(0xff_20_40_60),
            Rgb::new(0x20, 0x40, 0x60)
        );
        assert_eq!(
            Rgb::from_vst3_color_spec(0x00_20_40_60),
            Rgb::new(0x20, 0x40, 0x60)
        );
    }

    #[test]
    fn hsl_hits_the_primaries() {
        assert_eq!(hsl(0.0, 1.0, 0.5), Rgb::new(255, 0, 0));
        assert_eq!(hsl(120.0, 1.0, 0.5), Rgb::new(0, 255, 0));
        assert_eq!(hsl(240.0, 1.0, 0.5), Rgb::new(0, 0, 255));
        assert_eq!(hsl(0.0, 0.0, 1.0), Rgb::WHITE);
        assert_eq!(hsl(0.0, 0.0, 0.0), Rgb::BLACK);
    }

    #[test]
    fn hsl_wraps_hue() {
        assert_eq!(hsl(360.0, 1.0, 0.5), hsl(0.0, 1.0, 0.5));
        assert_eq!(hsl(-120.0, 1.0, 0.5), hsl(240.0, 1.0, 0.5));
    }

    #[test]
    fn generated_palettes_separate_neighbouring_tracks() {
        for p in Palette::ALL {
            if p == Palette::DawColors {
                continue;
            }
            for i in 0..32 {
                let a = p.color_for(i, None);
                let b = p.color_for(i + 1, None);
                let dist = (a.r as i32 - b.r as i32).abs()
                    + (a.g as i32 - b.g as i32).abs()
                    + (a.b as i32 - b.b as i32).abs();
                assert!(
                    dist > 20,
                    "{:?} tracks {i} and {} are too close: {a:?} vs {b:?}",
                    p,
                    i + 1
                );
            }
        }
    }

    #[test]
    fn generated_colors_stay_visible_on_the_dark_background() {
        for p in Palette::ALL {
            for i in 0..32 {
                let c = p.color_for(i, None);
                assert!(
                    c.luminance() > 0.15,
                    "{:?} track {i} is too dark to see: {c:?}",
                    p
                );
            }
        }
    }

    #[test]
    fn a_track_keeps_its_color_when_others_are_added() {
        // Colour depends only on the track's own index, never on the total count, so inserting
        // a track doesn't recolour the whole graph.
        let before: Vec<_> = (0..5).map(|i| Palette::Aurora.color_for(i, None)).collect();
        let after: Vec<_> = (0..20).map(|i| Palette::Aurora.color_for(i, None)).collect();
        assert_eq!(before, after[..5]);
    }

    #[test]
    fn daw_palette_uses_the_host_color() {
        let host = Rgb::new(0x40, 0x90, 0xd0);
        assert_eq!(Palette::DawColors.color_for(3, Some(host)), host);
    }

    #[test]
    fn daw_palette_falls_back_when_the_host_says_nothing_useful() {
        let generated = Palette::DEFAULT.color_for(3, None);
        assert_eq!(Palette::DawColors.color_for(3, None), generated);
        // Pure black/white mean "no colour set" in practice, not a real track colour.
        assert_eq!(Palette::DawColors.color_for(3, Some(Rgb::BLACK)), generated);
        assert_eq!(Palette::DawColors.color_for(3, Some(Rgb::WHITE)), generated);
    }

    #[test]
    fn palette_index_round_trips() {
        for p in Palette::ALL {
            assert_eq!(Palette::from_index(p.index()), p);
        }
        // Out-of-range indices clamp rather than panic; the parameter is host-controlled.
        assert_eq!(Palette::from_index(999), *Palette::ALL.last().unwrap());
    }

    #[test]
    fn lerp_hits_both_ends() {
        let a = Rgb::new(0, 0, 0);
        let b = Rgb::new(100, 200, 250);
        assert_eq!(a.lerp(b, 0.0), a);
        assert_eq!(a.lerp(b, 1.0), b);
        assert_eq!(a.lerp(b, 0.5), Rgb::new(50, 100, 125));
    }
}
