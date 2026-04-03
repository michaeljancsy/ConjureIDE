use std::time::Instant;

fn main() {
    let binary = std::fs::read(
        format!("{}/Library/Containers/com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension/Data/conjuredsp-nam-binary.bin",
            std::env::var("HOME").unwrap())
    ).unwrap();
    
    let mut model = conjuredsp::NamModel::from_binary(&binary).expect("parse failed");
    
    let n = 471;
    let input: Vec<f32> = (0..n)
        .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 44100.0).sin())
        .collect();
    let mut output = vec![0.0f32; n];
    
    // Warm up
    for _ in 0..3 {
        model.process_buffer(&input, &mut output, 0);
        model.process_buffer(&input, &mut output, 1);
    }
    
    // Benchmark
    let iterations = 10;
    let t0 = Instant::now();
    for _ in 0..iterations {
        model.process_buffer(&input, &mut output, 0);
        model.process_buffer(&input, &mut output, 1);
    }
    let avg = t0.elapsed().as_secs_f64() * 1000.0 / iterations as f64;
    
    println!("471 frames × 2 channels: {:.2}ms (avg of {} iterations)", avg, iterations);
    println!("Budget: 10.7ms");
    println!("{}", if avg < 10.7 { "WITHIN BUDGET ✓" } else { "OVER BUDGET ✗" });
}
