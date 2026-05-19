// Bit Mangler — extreme digital destruction.
//
// Treats audio as raw binary data and corrupts it through bit
// manipulation: XOR, sample-rate reduction, and random bit flips.

use conjuredsp::*;
setup!();

params! {
    CORRUPT = param(0.0, 1.0).default(0.5),
    XOR_MASK = param(0.0, 255.0).default(42.0),
    SAMPLE_RATE = param(1.0, 32.0).unit("x").default(4.0),
    MIX = mix().default(0.7),
}

static mut HELD: [f64; MAX_CH] = [0.0; MAX_CH];
static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);

    unsafe {
        let corrupt = ctx.param(CORRUPT) as f64;
        let xor_val = ctx.param(XOR_MASK) as i32;
        let downsample = (ctx.param(SAMPLE_RATE) as usize).max(1);
        let wet_mix = ctx.param(MIX) as f64;

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Convert to 16-bit integer representation
                let clamped = if x * 32768.0 > 32767.0 { 32767 }
                    else if x * 32768.0 < -32768.0 { -32768 }
                    else { (x * 32768.0) as i32 };
                let mut x_int = clamped;

                // XOR corruption
                if corrupt > 0.3 {
                    x_int = x_int ^ xor_val;
                }

                // Random bit flips
                if corrupt > 0.6 && rng() < corrupt * 0.1 {
                    let bit = 1i32 << (rng() * 16.0) as u32;
                    x_int = x_int ^ bit;
                }

                // Convert back to float
                let mut y = x_int as f64 / 32768.0;

                // Sample rate reduction
                if i % downsample == 0 {
                    HELD[ch] = y;
                }
                y = HELD[ch];

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
