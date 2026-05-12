//! Microbenchmark: per-call overhead of the WASM `process` ABI.
//!
//! Compares the legacy 5-arg shape against the zero-arg shape the
//! modernization plan introduces (see plans/an-ai-had-this-starry-moler.md).
//! Both variants invoke an otherwise-identical no-op `process` function;
//! the only difference is whether scalars travel as register args or
//! through a fixed shared-memory address (`BLOCK_INFO_BUF`).
//!
//! Earlier measurements (wasmtime 42, Apple Silicon, release) showed the
//! two shapes within ±3% noise across block sizes 16..1024. This file
//! commits the harness as a standing regression guard so a future
//! toolchain bump or wasmtime upgrade that materially regresses one
//! shape over the other is caught here.
//!
//! Run:
//!     cargo bench --bench process_call_overhead

use std::time::Instant;
use wasmtime::*;

/// 5-arg shape — scalars carried as wasmtime TypedFunc register args.
const WAT_5ARG: &str = r#"
(module
  (memory (export "memory") 1)
  (func (export "process") (param i32 i32 i32 i32 f32))
)
"#;

/// 0-arg shape — `process()` takes no args; the host writes
/// `BlockInfo { frame_count: u32, channel_count: u32, sample_rate: f32 }`
/// to linear memory at offset 0 before each call. Mirrors the
/// `BLOCK_INFO_BUF` channel described in the plan.
const WAT_0ARG: &str = r#"
(module
  (memory (export "memory") 1)
  (func (export "process"))
)
"#;

fn bench_5arg(block_size: u32, iterations: u32) -> f64 {
    let engine = Engine::default();
    let module = Module::new(&engine, WAT_5ARG).expect("compile 5arg");
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[]).expect("instantiate 5arg");
    let process: TypedFunc<(i32, i32, i32, i32, f32), ()> = instance
        .get_typed_func(&mut store, "process")
        .expect("typed_func 5arg");

    // Warm up.
    for _ in 0..1024 {
        process
            .call(&mut store, (0, 0, 2, block_size as i32, 44_100.0))
            .expect("call 5arg");
    }

    let start = Instant::now();
    for _ in 0..iterations {
        process
            .call(&mut store, (0, 0, 2, block_size as i32, 44_100.0))
            .expect("call 5arg");
    }
    start.elapsed().as_nanos() as f64 / iterations as f64
}

fn bench_0arg(block_size: u32, iterations: u32) -> f64 {
    let engine = Engine::default();
    let module = Module::new(&engine, WAT_0ARG).expect("compile 0arg");
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[]).expect("instantiate 0arg");
    let process: TypedFunc<(), ()> = instance
        .get_typed_func(&mut store, "process")
        .expect("typed_func 0arg");
    let memory = instance
        .get_memory(&mut store, "memory")
        .expect("get_memory 0arg");

    // Warm up.
    for _ in 0..1024 {
        write_block_info(memory, &mut store, block_size);
        process.call(&mut store, ()).expect("call 0arg");
    }

    let start = Instant::now();
    for _ in 0..iterations {
        write_block_info(memory, &mut store, block_size);
        process.call(&mut store, ()).expect("call 0arg");
    }
    start.elapsed().as_nanos() as f64 / iterations as f64
}

#[inline]
fn write_block_info<T>(memory: Memory, store: &mut Store<T>, block_size: u32) {
    let data = memory.data_mut(store);
    // [u32 frame_count][u32 channel_count][f32 sample_rate]
    data[0..4].copy_from_slice(&block_size.to_le_bytes());
    data[4..8].copy_from_slice(&2u32.to_le_bytes());
    data[8..12].copy_from_slice(&44_100.0f32.to_le_bytes());
}

fn main() {
    let iterations = 500_000;
    println!("\nProcess-call overhead — 5-arg ABI vs 0-arg ABI + BLOCK_INFO_BUF write");
    println!("({} iterations per shape per block size)\n", iterations);
    println!("Block | 5-arg (ns/call) | 0-arg (ns/call) |  delta");
    println!("------+-----------------+-----------------+--------");

    for &block in &[16u32, 32, 64, 256, 512, 1024] {
        let ns5 = bench_5arg(block, iterations);
        let ns0 = bench_0arg(block, iterations);
        let delta_pct = (ns0 - ns5) / ns5 * 100.0;
        println!(
            "{:>5} | {:>15.2} | {:>15.2} | {:>+5.2}%",
            block, ns5, ns0, delta_pct
        );
    }

    println!(
        "\nExpected: |delta| within ~±5% jitter at all block sizes\n\
         (earlier verification — wasmtime 42, Apple Silicon, release).\n\
         A persistent regression beyond this band is a signal to investigate."
    );
}
