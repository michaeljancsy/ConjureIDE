//! Renders the Vision graph to PNG files so the layout can be eyeballed without a DAW.
//!
//! `cargo run -p bedrock-core --example preview -- out/`
//!
//! The PNG writer here is deliberately dependency-free and uses stored (uncompressed) deflate
//! blocks — this is a development preview, not something that ships. Output is therefore large;
//! run it through any PNG optimiser before committing an image.

use std::env;
use std::fs;
use std::path::Path;

use bedrock_core::analyzer::{bin_frequency, DB_FLOOR, NUM_BINS};
use bedrock_core::palette::Palette;
use bedrock_core::protocol::{quantize_db, Frame};
use bedrock_core::render::{render, Canvas, Scene, TrackView};

// -- minimal PNG encoder ------------------------------------------------------------------

fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, e) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
        }
        *e = c;
    }
    let mut c = 0xFFFF_FFFFu32;
    for &b in data {
        c = table[((c ^ b as u32) & 0xff) as usize] ^ (c >> 8);
    }
    c ^ 0xFFFF_FFFF
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in data {
        a = (a + byte as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], payload: &[u8]) {
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    let mut body = kind.to_vec();
    body.extend_from_slice(payload);
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc32(&body).to_be_bytes());
}

fn encode_png(canvas: &Canvas) -> Vec<u8> {
    let mut raw = Vec::with_capacity(canvas.height * (1 + canvas.width * 3));
    for y in 0..canvas.height {
        raw.push(0); // filter: none
        for x in 0..canvas.width {
            let p = canvas.pixels[y * canvas.width + x];
            raw.push((p >> 16) as u8);
            raw.push((p >> 8) as u8);
            raw.push(p as u8);
        }
    }

    let mut z = vec![0x78, 0x01];
    for (i, block) in raw.chunks(65_535).enumerate() {
        let last = (i + 1) * 65_535 >= raw.len();
        z.push(if last { 1 } else { 0 });
        z.extend_from_slice(&(block.len() as u16).to_le_bytes());
        z.extend_from_slice(&(!(block.len() as u16)).to_le_bytes());
        z.extend_from_slice(block);
    }
    z.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&(canvas.width as u32).to_be_bytes());
    ihdr.extend_from_slice(&(canvas.height as u32).to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut png, b"IHDR", &ihdr);
    chunk(&mut png, b"IDAT", &z);
    chunk(&mut png, b"IEND", &[]);
    png
}

// -- synthetic mix ------------------------------------------------------------------------

/// One resonance: a Gaussian bump in log-frequency.
struct Band {
    center: f32,
    /// Width in octaves.
    octaves: f32,
    db: f32,
}

fn spectrum(bands: &[Band], tilt_db_per_octave: f32, floor: f32) -> Frame {
    let mut bins = [0u8; NUM_BINS];
    for (i, slot) in bins.iter_mut().enumerate() {
        let f = bin_frequency(i);
        let mut level = floor;
        for b in bands {
            let d = (f / b.center).log2() / b.octaves;
            let contribution = b.db - 12.0 * d * d;
            level = level.max(contribution);
        }
        level += tilt_db_per_octave * (f / 1000.0).log2();
        *slot = quantize_db(level.max(DB_FLOOR));
    }
    Frame {
        bins,
        peak_db: -6.0,
        rms_db: -18.0,
    }
}

fn main() {
    let out_dir = env::args().nth(1).unwrap_or_else(|| "out".to_string());
    fs::create_dir_all(&out_dir).expect("create output directory");

    let kick = spectrum(
        &[
            Band { center: 55.0, octaves: 0.7, db: -8.0 },
            Band { center: 3000.0, octaves: 1.0, db: -34.0 },
        ],
        0.0,
        -95.0,
    );
    let bass = spectrum(
        &[
            Band { center: 90.0, octaves: 1.1, db: -10.0 },
            Band { center: 700.0, octaves: 1.4, db: -26.0 },
        ],
        0.0,
        -95.0,
    );
    let guitar = spectrum(
        &[
            Band { center: 220.0, octaves: 1.3, db: -18.0 },
            Band { center: 1600.0, octaves: 1.6, db: -20.0 },
        ],
        -1.5,
        -95.0,
    );
    let vocal = spectrum(
        &[
            Band { center: 280.0, octaves: 0.9, db: -16.0 },
            Band { center: 900.0, octaves: 0.8, db: -19.0 },
            Band { center: 2800.0, octaves: 1.1, db: -22.0 },
        ],
        -1.0,
        -95.0,
    );
    let hats = spectrum(
        &[
            Band { center: 9000.0, octaves: 1.5, db: -24.0 },
            Band { center: 400.0, octaves: 1.0, db: -52.0 },
        ],
        0.0,
        -95.0,
    );
    let pad = spectrum(
        &[
            Band { center: 400.0, octaves: 2.4, db: -26.0 },
            Band { center: 4000.0, octaves: 2.0, db: -32.0 },
        ],
        0.0,
        -95.0,
    );

    let named: [(&str, &Frame); 6] = [
        ("Kick", &kick),
        ("Bass", &bass),
        ("Gtr L/R", &guitar),
        ("Lead Vox", &vocal),
        ("Hats", &hats),
        ("Pad", &pad),
    ];
    let tracks: Vec<TrackView> = named
        .iter()
        .map(|(name, frame)| TrackView {
            name,
            frame,
            daw_color: None,
            has_frame: true,
        })
        .collect();

    let variants: [(&str, usize, usize, Scene); 5] = [
        (
            "wide",
            1280,
            600,
            Scene { tracks: &tracks, realm: 0, ..Default::default() },
        ),
        (
            "tall",
            520,
            760,
            Scene { tracks: &tracks, realm: 3, ..Default::default() },
        ),
        (
            "small",
            480,
            270,
            Scene { tracks: &tracks, ..Default::default() },
        ),
        (
            "spectrum-palette",
            1280,
            600,
            Scene {
                tracks: &tracks,
                palette: Palette::Spectrum,
                fill_opacity: 0.10,
                ..Default::default()
            },
        ),
        (
            "empty",
            900,
            420,
            Scene { tracks: &[], ..Default::default() },
        ),
    ];

    for (name, w, h, scene) in variants {
        let mut canvas = Canvas::new(w, h);
        render(&mut canvas, &scene);
        let path = Path::new(&out_dir).join(format!("{name}.png"));
        fs::write(&path, encode_png(&canvas)).expect("write png");
        println!("wrote {} ({w}x{h})", path.display());
    }
}
