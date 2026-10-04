//! On-device dictation engine — the Zig port of zeron `crates/voice`.
pub const fft = @import("fft.zig");
pub const resample = @import("resample.zig");
pub const features = @import("features.zig");
pub const ort = @import("ort.zig");
pub const model = @import("model.zig");
pub const recognizer = @import("recognizer.zig");
pub const capture = @import("capture.zig");
pub const session = @import("session.zig");

test {
    _ = fft;
    _ = resample;
    _ = features;
    _ = model;
    _ = recognizer;
    _ = capture;
    _ = session;
    _ = @import("parity_test.zig");
}
