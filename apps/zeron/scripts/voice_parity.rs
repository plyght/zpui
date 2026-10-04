//! Dumps zeron-voice reference values as Zig source for
//! apps/zeron/src/voice/parity_data.zig (compared by voice/parity_test.zig).
//!
//! The resampler is `zeron_voice::resample::for_model` (rubato 0.16.2
//! `FftFixedInOut`) and the features are parakeet-rs 0.3.8
//! `audio::extract_features_with_cache`; both modules are private, so their
//! bodies are reproduced verbatim below on top of the same crates. The
//! transcripts come from `zeron_voice::Recognizer` itself (ONNX Runtime 1.28,
//! Parakeet v3 int8), so they need the downloaded model directory.
//!
//! Build against the zeron workspace's prebuilt rlibs (no Cargo project needed):
//!   D=$ZERON/target/debug/deps
//!   ORT=$(dirname $(ls ~/.cache/ort.pyke.io/dfbin/*/*/libonnxruntime.a))
//!   rustc --edition 2024 -O voice_parity.rs -o /tmp/voice_parity -L $D -L $ORT \
//!     --extern zeron_voice=$(ls $D/libzeron_voice-*.rlib) \
//!     --extern rubato=$(ls $D/librubato-*.rlib) --extern realfft=$(ls $D/librealfft-*.rlib) \
//!     -l static=onnxruntime -l stdc++
//!   /tmp/voice_parity <model dir> apps/zeron/fixtures/voice/speech.wav > apps/zeron/src/voice/parity_data.zig
use realfft::RealFftPlanner;
use rubato::{FftFixedInOut, Resampler};

/// Deterministic test signal: LCG noise plus a triangle wave, pure integer
/// and float arithmetic so Zig regenerates it bit-for-bit.
fn signal(n: usize, seed: u32) -> Vec<f32> {
    let mut state = seed;
    (0..n)
        .map(|i| {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let noise = (state >> 8) as f32 / 16777216.0 * 2.0 - 1.0;
            let phase = (i % 200) as f32 / 200.0;
            let tri = if phase < 0.5 { phase * 4.0 - 1.0 } else { 3.0 - phase * 4.0 };
            0.3 * noise + 0.5 * tri
        })
        .collect()
}

/// `zeron_voice::resample::for_model`, generalised over the output rate.
fn resample(samples: Vec<f32>, rate: u32, to: u32) -> Vec<f32> {
    if rate == to || samples.is_empty() {
        return samples;
    }
    let length = (samples.len() as u64 * to as u64 / rate as u64) as usize;
    let mut resampler = FftFixedInOut::<f32>::new(rate as usize, to as usize, 1024, 1).unwrap();
    let delay = resampler.output_delay();
    let chunk = resampler.input_frames_next();
    let mut input = vec![vec![0.0; chunk]];
    let mut output = resampler.output_buffer_allocate(true);
    let mut converted = Vec::with_capacity(length + delay + resampler.output_frames_max());
    let mut offset = 0;
    while converted.len() < length + delay {
        input[0].fill(0.0);
        let end = (offset + chunk).min(samples.len());
        if offset < end {
            input[0][..end - offset].copy_from_slice(&samples[offset..end]);
        }
        let (_, written) = resampler.process_into_buffer(&input, &mut output, None).unwrap();
        converted.extend_from_slice(&output[0][..written]);
        offset = end;
    }
    converted.drain(..delay);
    converted.truncate(length);
    converted
}

// ---- parakeet-rs 0.3.8 src/audio.rs (TDT config: 128 mels, n_fft 512, hop 160, win 400) ----
const F_SP: f64 = 200.0 / 3.0;
const MIN_LOG_HZ: f64 = 1000.0;
const MIN_LOG_MEL: f64 = MIN_LOG_HZ / F_SP;
const LOG_STEP: f64 = 0.06875177742094912;
fn hz_to_mel(hz: f64) -> f64 {
    if hz < MIN_LOG_HZ { hz / F_SP } else { MIN_LOG_MEL + (hz / MIN_LOG_HZ).ln() / LOG_STEP }
}
fn mel_to_hz(mel: f64) -> f64 {
    if mel < MIN_LOG_MEL { mel * F_SP } else { MIN_LOG_HZ * ((mel - MIN_LOG_MEL) * LOG_STEP).exp() }
}
fn filterbank(n_fft: usize, n_mels: usize, sr: usize) -> Vec<Vec<f32>> {
    let bins = n_fft / 2 + 1;
    let mut fb = vec![vec![0.0f32; bins]; n_mels];
    let (lo, hi) = (hz_to_mel(0.0), hz_to_mel(sr as f64 / 2.0));
    let pts: Vec<f64> = (0..=n_mels + 1).map(|i| mel_to_hz(lo + (hi - lo) * i as f64 / (n_mels + 1) as f64)).collect();
    let freqs: Vec<f64> = (0..bins).map(|i| i as f64 * sr as f64 / n_fft as f64).collect();
    let fdiff: Vec<f64> = pts.windows(2).map(|w| w[1] - w[0]).collect();
    for i in 0..n_mels {
        for (k, &f) in freqs.iter().enumerate() {
            let lower = (f - pts[i]) / fdiff[i];
            let upper = (pts[i + 2] - f) / fdiff[i + 1];
            fb[i][k] = 0.0f64.max(lower.min(upper)) as f32;
        }
    }
    for i in 0..n_mels {
        let enorm = 2.0 / (pts[i + 2] - pts[i]);
        for k in 0..bins {
            fb[i][k] *= enorm as f32;
        }
    }
    fb
}
/// Returns frames × 128, row-major.
fn features(audio: &[f32]) -> (usize, Vec<f32>) {
    let (n_fft, hop, win, n_mels) = (512usize, 160usize, 400usize, 128usize);
    let mut pre = Vec::with_capacity(audio.len());
    if !audio.is_empty() {
        pre.push(audio[0]);
        for i in 1..audio.len() {
            pre.push(audio[i] - 0.97 * audio[i - 1]);
        }
    }
    let pad = n_fft / 2;
    let mut padded = vec![0.0f32; pad];
    padded.extend_from_slice(&pre);
    padded.resize(padded.len() + pad, 0.0);
    let window: Vec<f32> = (0..win)
        .map(|i| 0.5 - 0.5 * ((2.0 * std::f32::consts::PI * i as f32) / (win as f32 - 1.0)).cos())
        .collect();
    let frames = pre.len() / hop;
    let bins = n_fft / 2 + 1;
    let plan = RealFftPlanner::<f32>::new().plan_fft_forward(n_fft);
    let mut spec = vec![vec![0.0f32; frames]; bins];
    let off = (n_fft - win) / 2;
    let mut input = vec![0.0f32; n_fft];
    let mut output = plan.make_output_vec();
    for f in 0..frames {
        let start = f * hop;
        input.fill(0.0);
        for i in 0..win {
            input[off + i] = padded[start + off + i] * window[i];
        }
        plan.process(&mut input, &mut output).unwrap();
        for k in 0..bins {
            spec[k][f] = output[k].norm_sqr();
        }
    }
    let fb = filterbank(n_fft, n_mels, 16000);
    let guard = 2.0f32.powi(-24);
    // ndarray's `dot` is a plain f32 GEMM; summation order may differ by an ulp.
    let mut mel = vec![0.0f32; frames * n_mels];
    for f in 0..frames {
        for m in 0..n_mels {
            let mut acc = 0.0f32;
            for k in 0..bins {
                acc += fb[m][k] * spec[k][f];
            }
            mel[f * n_mels + m] = (acc + guard).ln();
        }
    }
    if frames > 1 {
        for m in 0..n_mels {
            let mean: f32 = (0..frames).map(|f| mel[f * n_mels + m]).sum::<f32>() / frames as f32;
            let var: f32 = (0..frames).map(|f| (mel[f * n_mels + m] - mean).powi(2)).sum::<f32>() / (frames as f32 - 1.0);
            let std = var.sqrt() + 1e-5;
            for f in 0..frames {
                mel[f * n_mels + m] = (mel[f * n_mels + m] - mean) / std;
            }
        }
    }
    (frames, mel)
}

fn read_wav(path: &str) -> Vec<f32> {
    // 16-bit PCM mono, canonical 44-byte header (the checked-in fixture).
    let bytes = std::fs::read(path).unwrap();
    let mut i = 12;
    while &bytes[i..i + 4] != b"data" {
        let n = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
        i += 8 + n;
    }
    let n = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
    bytes[i + 8..i + 8 + n].chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0).collect()
}

fn floats(name: &str, v: &[f32]) {
    print!("pub const {name} = [_]f32{{");
    for (i, x) in v.iter().enumerate() {
        if i % 8 == 0 {
            print!("\n   ");
        }
        print!(" {:e},", x);
    }
    println!("\n}};");
}

const STRIDE: usize = 13;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (model, wav) = (std::path::Path::new(&args[1]), &args[2]);
    println!("//! Generated by apps/zeron/scripts/voice_parity.rs — do not edit.");
    println!("pub const stride = {STRIDE};");
    println!("pub const ResampleCase = struct {{ rate: u32, n: usize, seed: u32, len: usize, sum: f64, sum_sq: f64, sampled: []const f32 }};");
    println!("pub const resample_cases = [_]ResampleCase{{");
    for (rate, n, seed) in [(8000u32, 4000usize, 1u32), (22050, 11025, 2), (44100, 11025, 3), (48000, 12000, 4), (96000, 24000, 5), (44100, 147, 6), (16000, 1000, 7)] {
        let out = resample(signal(n, seed), rate, 16000);
        let sum: f64 = out.iter().map(|&x| x as f64).sum();
        let sum_sq: f64 = out.iter().map(|&x| (x as f64) * (x as f64)).sum();
        print!("    .{{ .rate = {rate}, .n = {n}, .seed = {seed}, .len = {}, .sum = {:e}, .sum_sq = {:e}, .sampled = &.{{", out.len(), sum, sum_sq);
        for x in out.iter().step_by(STRIDE) {
            print!("{:e},", x);
        }
        println!("}} }},");
    }
    println!("}};");

    let audio = read_wav(wav);
    let (frames, mel) = features(&audio);
    println!("pub const feature_frames = {frames};");
    let sampled: Vec<f32> = mel.iter().step_by(STRIDE * 7).copied().collect();
    floats("feature_sampled", &sampled);

    let mut recognizer = zeron_voice::Recognizer::load(model).expect("model");
    let direct = recognizer.transcribe(audio.clone(), 16000).unwrap();
    println!("pub const transcript_16k = {:?};", direct);
    let up = resample(audio.clone(), 16000, 48000);
    let resampled = recognizer.transcribe(up, 48000).unwrap();
    println!("pub const transcript_48k = {:?};", resampled);
}
